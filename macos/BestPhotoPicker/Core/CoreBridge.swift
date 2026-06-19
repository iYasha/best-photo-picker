import Foundation

// MARK: - CoreBridge
//
// The single seam between the SwiftUI app and the scoring backend.
//
// `CoreBridge` exposes one async, cancellable method, `score(source:)`, that
// returns an `AsyncThrowingStream` of `ScoringEvent`s: zero-or-more `.progress`
// events followed by exactly one terminal `.completed(ScoreResult)`. The stream
// finishes after the completion event (or throws / finishes early on cancellation).
//
// Today the bridge runs in **fixture mode** (`FixtureScoringEngine`), replaying a
// bundled progress log + result with small delays so the Scoring screen animates.
//
// ── Issue 5 swap (fixture → real subprocess) ───────────────────────────────
// The backend is abstracted behind the `ScoringEngine` protocol. Issue 5 adds a
// `SubprocessScoringEngine: ScoringEngine` that launches `bestphoto score --json`,
// reads stdout, decodes each JSON-line into a `ScoreProgress`, and decodes the
// final document into a `ScoreResult` — emitting the SAME `ScoringEvent`s. Then it
// flips `CoreBridge.live`'s engine from `.fixture` to `.subprocess`. No call site,
// no `ScoreContract` type, and nothing in `AppModel`/the Scoring view changes:
// they only ever see `ScoringEvent`s off this stream.
//
// Decoding runs off the main actor (inside the stream's producer `Task`); the
// consumer (`AppModel`, `@MainActor`) receives already-decoded value types.

/// An event emitted by a scoring run, in order: any number of `.progress`,
/// then exactly one terminal `.completed`.
enum ScoringEvent: Sendable {
    /// A live progress tick (one per scored frame in fixture mode).
    case progress(ScoreProgress)
    /// The final result. Always the last event of a successful run.
    case completed(ScoreResult)
}

/// Errors surfaced by a scoring run.
enum ScoringError: Error, Sendable {
    /// A bundled fixture resource was missing or unreadable.
    case fixtureMissing(String)
    /// A progress line or the result document failed to decode.
    case decodeFailed(underlying: String)
}

/// The backend that produces scoring events. Fixture today; real subprocess in issue 5.
protocol ScoringEngine: Sendable {
    /// Stream scoring events for `source` under `grouping`. Honour `Task`
    /// cancellation: stop producing and finish the stream promptly when the
    /// consuming task is cancelled. `source` is the imported folder (nil in fixture
    /// mode, which ignores it). `grouping` selects time vs similarity bursts; the
    /// completed `ScoreResult.grouping` matches what was requested (issue 8).
    func score(source: URL?, grouping: Grouping) -> AsyncThrowingStream<ScoringEvent, Error>
}

/// Selects the scoring backend. Issue 5 adds a `.subprocess` engine and points
/// `CoreBridge.live` at it; everything upstream is unchanged.
enum CoreBridge {
    /// The bridge the app uses. Issue 5: swap the engine here.
    static let live: any ScoringEngine = ScoringEngineSelector.live()
}

// MARK: - Fixture engine

/// Replays the bundled fixture (`score_progress.fixture.jsonl` +
/// `score_result.fixture.json`) as a `ScoringEvent` stream with small inter-event
/// delays so the UI animates. Decoding happens on the producer task, off the main actor.
struct FixtureScoringEngine: ScoringEngine {
    /// Resource base names (extension supplied at load).
    static let progressResource = "score_progress.fixture"
    /// Similarity result fixture (the default grouping, computed during scoring).
    static let resultResource = "score_result.fixture"
    /// Time result fixture (issue 8): same 53 frames / ids as the similarity
    /// fixture, but one burst per scene (no "· group N" split) so favourites
    /// persist across a switch. Selected when `.time` is requested.
    static let timeResultResource = "score_result_time.fixture"

    /// The result fixture base name for a requested grouping.
    static func resultResource(for grouping: Grouping) -> String {
        switch grouping {
        case .similarity: return resultResource
        case .time: return timeResultResource
        }
    }

    /// Delay between progress events. Tuned so the whole replay runs a few
    /// seconds — long enough to read the screen, short enough not to bore.
    var perFrameDelay: Duration = .milliseconds(80)
    /// Pause after the last progress event before delivering the result, so the
    /// bar visibly lands on 100% before auto-advancing.
    var settleDelay: Duration = .milliseconds(550)
    /// Bundle to load fixtures from (injectable for tests/previews).
    var bundle: Bundle = .main

    func score(source: URL?, grouping: Grouping) -> AsyncThrowingStream<ScoringEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let progress = try loadProgress()
                    let result = try loadResult(grouping: grouping)
                    for event in progress {
                        try Task.checkCancellation()
                        continuation.yield(.progress(event))
                        try await Task.sleep(for: perFrameDelay)
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(for: settleDelay)
                    try Task.checkCancellation()
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Loading (off the main actor; pure value output)

    private func fixtureData(_ name: String, ext: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ScoringError.fixtureMissing("\(name).\(ext)")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ScoringError.fixtureMissing("\(name).\(ext): \(error.localizedDescription)")
        }
    }

    /// Decode the JSON-lines progress log into `ScoreProgress` events.
    private func loadProgress() throws -> [ScoreProgress] {
        let data = try fixtureData(Self.progressResource, ext: "jsonl")
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScoringError.decodeFailed(underlying: "progress fixture is not UTF-8")
        }
        let decoder = ScoreContract.lineDecoder
        var events: [ScoreProgress] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            do {
                events.append(try decoder.decode(ScoreProgress.self, from: Data(line.utf8)))
            } catch {
                throw ScoringError.decodeFailed(underlying: "progress line: \(error)")
            }
        }
        return events
    }

    /// Decode the final result document for the requested grouping. Both groupings
    /// ship as bundled fixtures (issue 8); the same frame ids appear in each, so a
    /// switch keeps favourites starred.
    private func loadResult(grouping: Grouping) throws -> ScoreResult {
        let data = try fixtureData(Self.resultResource(for: grouping), ext: "json")
        do {
            return try ScoreContract.decoder.decode(ScoreResult.self, from: data)
        } catch {
            throw ScoringError.decodeFailed(underlying: "result: \(error)")
        }
    }
}
