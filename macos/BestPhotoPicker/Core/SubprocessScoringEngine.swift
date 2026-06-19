import Foundation

/// Errors specific to driving the real core subprocess. (`ScoringError` in
/// CoreBridge.swift is owned by issue 2 and not edited here, so the subprocess
/// engine carries its own failure cases; both flow out of the stream the same way
/// and the app's `runScoring` already catches any `Error`.)
enum SubprocessScoringError: Error, Sendable {
    /// No source folder, or `uv` / the repo could not be resolved — the engine
    /// can't run, so `CoreBridge` should fall back to the fixture.
    case unavailable(String)
    /// The subprocess exited without emitting a result document.
    case failed(status: Int32, stderr: String)
    /// A progress line or the result document failed to decode.
    case decodeFailed(underlying: String)
}

// MARK: - SubprocessScoringEngine
//
// The real `ScoringEngine` (issue 5): drives the Python core as a subprocess and
// turns its stdout into the same `ScoringEvent` stream the app already consumes.
// No scoring logic lives here — the core is the single source of truth (ADR 0005);
// this is a transport that launches `bestphoto score --json`, parses its JSON wire
// (ADR 0008), and surfaces progress / result / errors.
//
// ── Wire contract (must match `core/bestphoto/jsonout.py`) ──────────────────
// The CLI emits **one JSON object per line** on stdout:
//   * progress lines — `{"done", "total", "current_frame_name", "current_burst_label"}`
//   * a final result doc emitted as the **last line** — `{"grouping", "bursts":[…]}`
// They are told apart by a top-level key: a progress object has `"done"`; the
// final doc has `"grouping"` and never `"done"`. We route each line on that key,
// decode progress lines into `ScoreProgress` and the final line into `ScoreResult`
// (via `ScoreContract`'s snake_case decoders), and emit the matching event. All
// logging is written to **stderr** by the core (`jsonout.logs_to_stderr`), so
// stdout is pure JSON — we read it line by line without filtering.
//
// ── Invocation (exact argv) ─────────────────────────────────────────────────
//   uv run --project <repo> bestphoto score --json <source>
//       -m <tmp>/manifest.csv  --cache <tmp>/.bpp-cache.csv
//       [-c ~/Library/Application Support/BestPhotoPicker/config.toml]
// `uv run --project <repo>` resolves the workspace's `bestphoto` script without a
// pre-activated venv. The manifest still lands on disk (ADR 0001) — in a temp dir,
// since the app's contract is the JSON; the human can still open that CSV. The
// `-c` flag is added only when the issue-11 config file exists (shared path).
//
// ── Cancellation ────────────────────────────────────────────────────────────
// The producing `Task` registers `continuation.onTermination`, which terminates
// the child process (SIGTERM) and cancels the read task. The app cancels by
// cancelling the `Task` that iterates the stream (screen change / Cancel button),
// so a cancelled pass tears the subprocess down promptly.

struct SubprocessScoringEngine: ScoringEngine {

    /// Absolute path to the repo root (the uv workspace passed to `uv run --project`).
    /// Resolved once at construction; `nil` means "cannot run" and the engine fails
    /// cleanly so `CoreBridge` keeps the fixture fallback.
    var repoRoot: URL?
    /// Path to the `uv` executable.
    var uvPath: URL?
    /// The issue-11 config file; passed via `-c` only when it exists on disk.
    var configURL: URL

    init(repoRoot: URL? = SubprocessScoringEngine.resolveRepoRoot(),
         uvPath: URL? = SubprocessScoringEngine.resolveUV(),
         configURL: URL = SubprocessScoringEngine.defaultConfigURL) {
        self.repoRoot = repoRoot
        self.uvPath = uvPath
        self.configURL = configURL
    }

    /// True when a real run is possible: a resolvable repo + `uv`. `CoreBridge`
    /// consults this (plus a non-nil source) before choosing this engine.
    var isAvailable: Bool { repoRoot != nil && uvPath != nil }

    // MARK: Stream

    func score(source: URL?, grouping: Grouping) -> AsyncThrowingStream<ScoringEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let source else {
                continuation.finish(throwing: SubprocessScoringError.unavailable("no source folder"))
                return
            }
            guard let repoRoot, let uvPath else {
                continuation.finish(throwing: SubprocessScoringError.unavailable(
                    "uv / repo not resolvable"))
                return
            }

            let process = Process()
            // Detached: the read loop + the blocking `process.waitUntilExit()` must NOT
            // run on the caller's actor. `score()` is invoked from a @MainActor task, so a
            // plain `Task {}` would inherit MainActor and freeze the UI for the whole pass.
            let task = Task.detached {
                let stdout = Pipe()
                let stderr = Pipe()
                var workDir: URL?
                do {
                    let tmp = try Self.makeWorkDir()
                    workDir = tmp
                    process.executableURL = uvPath
                    process.arguments = Self.arguments(
                        repoRoot: repoRoot, source: source, workDir: tmp,
                        configURL: configURL, grouping: grouping)
                    process.standardOutput = stdout
                    process.standardError = stderr
                    // A login-ish env so `uv` finds its toolchain when launched
                    // from the app (which inherits a sparse environment).
                    process.environment = Self.childEnvironment()

                    try process.run()

                    var sawResult = false
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        guard let event = try Self.decodeEvent(trimmed) else { continue }
                        if case .completed = event { sawResult = true }
                        continuation.yield(event)
                    }

                    process.waitUntilExit()
                    try Task.checkCancellation()

                    if !sawResult {
                        // No final doc: the core failed before emitting a result.
                        let errText = Self.readError(stderr)
                        throw SubprocessScoringError.failed(
                            status: process.terminationStatus, stderr: errText)
                    }
                    continuation.finish()
                    Self.cleanUp(workDir)
                } catch is CancellationError {
                    if process.isRunning { process.terminate() }
                    continuation.finish()
                    Self.cleanUp(workDir)
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                    Self.cleanUp(workDir)
                }
            }

            // Cancellation seam: if the consumer cancels its iterating task (Cancel
            // button / screen change), the stream terminates and we cancel the
            // producer task. The producer's own `onTermination` (set once `process`
            // exists) also terminates the child; this guards the window before that.
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
                task.cancel()
            }
        }
    }

    // MARK: Line routing

    /// Decode one stdout line into a `ScoringEvent`, routing on the top-level key:
    /// a progress line has `done`; the final doc has `grouping`. Returns `nil` for
    /// a JSON object that is neither (defensive — skip unknown lines rather than fail).
    static func decodeEvent(_ line: String) throws -> ScoringEvent? {
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not a JSON object (shouldn't happen — stdout is pure JSON) — skip.
            return nil
        }
        if object["done"] != nil {
            do {
                return .progress(try ScoreContract.lineDecoder.decode(ScoreProgress.self, from: data))
            } catch {
                throw SubprocessScoringError.decodeFailed(underlying: "progress line: \(error)")
            }
        }
        if object["grouping"] != nil {
            do {
                return .completed(try ScoreContract.decoder.decode(ScoreResult.self, from: data))
            } catch {
                throw SubprocessScoringError.decodeFailed(underlying: "result: \(error)")
            }
        }
        return nil
    }

    // MARK: Argv

    static func arguments(
        repoRoot: URL, source: URL, workDir: URL, configURL: URL, grouping: Grouping
    ) -> [String] {
        var args = [
            "run", "--project", repoRoot.path,
            "bestphoto", "score", "--json", source.path,
            "-m", workDir.appendingPathComponent("manifest.csv").path,
            "--cache", workDir.appendingPathComponent(".bpp-cache.csv").path,
            // `--group time|similarity` (ADR 0004); the enum raw value is the CLI
            // spelling. The returned `ScoreResult.grouping` matches this request.
            "--group", grouping.rawValue,
        ]
        if FileManager.default.fileExists(atPath: configURL.path) {
            args.append(contentsOf: ["-c", configURL.path])
        }
        return args
    }

    // MARK: Resolution

    /// `~/Library/Application Support/BestPhotoPicker/config.toml` — the path issue
    /// 11 (Settings) writes and this engine reads. Computed independently here so
    /// the two sides share the spelling without a cross-file dependency.
    static var defaultConfigURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("BestPhotoPicker", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Find the uv-workspace repo root (the dir holding `uv.lock` + `core/bestphoto`).
    /// Order: `BPP_REPO` env override, then walk up from this source file's compiled
    /// path, then a couple of common dev locations. `nil` if none look right.
    static func resolveRepoRoot() -> URL? {
        let fm = FileManager.default
        func looksLikeRepo(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("uv.lock").path)
                && fm.fileExists(atPath: url.appendingPathComponent("core/bestphoto").path)
        }
        if let env = ProcessInfo.processInfo.environment["BPP_REPO"] {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if looksLikeRepo(url) { return url }
        }
        // Walk up from this file's location at compile time (#filePath points into
        // .../best-photo-picker/macos/BestPhotoPicker/Core/SubprocessScoringEngine.swift).
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if looksLikeRepo(dir) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Locate the `uv` executable. Checks a few canonical install dirs (the app's
    /// inherited PATH is usually too sparse to rely on); returns the first that exists.
    static func resolveUV() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.pyenv/shims/uv",
            "\(home)/.local/bin/uv",
            "\(home)/.cargo/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// A PATH-augmented environment so `uv` and its managed Python resolve when the
    /// process is launched from the app bundle (which inherits a minimal env).
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "\(home)/.pyenv/shims", "\(home)/.local/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        let existing = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set<String>()
        let merged = (extra + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        // Force unbuffered stdout so progress JSON lines reach us as they're emitted,
        // not block-buffered until the process exits (the core also flushes per line).
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    // MARK: Work dir + stderr

    /// A throwaway temp dir for this run's CSV manifest + cache (kept off the user's
    /// source folder; the app's contract is the JSON, not these files).
    static func makeWorkDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BestPhotoPicker", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cleanUp(_ dir: URL?) {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    static func readError(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.suffix(2000))   // last lines are the actual failure
    }
}

// MARK: - Engine selection (CoreBridge.live)
//
// `CoreBridge.live` calls this. Selection logic, kept here so CoreBridge changes by
// exactly one line:
//
//   * If a real run is possible — `uv` resolves AND the uv-workspace repo is found
//     (so `bestphoto score --json` can actually be spawned) — use the real
//     `SubprocessScoringEngine`. (It still no-ops cleanly at run time if `source`
//     is nil, throwing `.unavailable`; the app's `runScoring` catches that.)
//   * Otherwise — no Python env / no repo (e.g. a stand-alone demo build) — keep
//     the bundled `FixtureScoringEngine`, so the app still demos end-to-end with
//     no toolchain. The fixture is never removed; this only prefers the real
//     engine when the machine can run it.
//
// Note: availability is checked at startup. A subprocess engine that turns out
// unable to produce a result still surfaces the failure through the stream, and
// `AppModel.runScoring` falls back to the Import screen rather than stranding the
// user — so a misdetected environment degrades, it doesn't crash.
enum ScoringEngineSelector {
    static func live() -> any ScoringEngine {
        let subprocess = SubprocessScoringEngine()
        return subprocess.isAvailable ? subprocess : FixtureScoringEngine()
    }
}
