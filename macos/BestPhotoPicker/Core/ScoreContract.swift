import Foundation

// MARK: - Score JSON contract (ADR 0008)
//
// The Python core's `bestphoto score --json` output is the app's contract.
// Two payloads cross the boundary:
//
//   1. A stream of `ScoreProgress` events — one compact JSON object **per line**
//      (JSON-lines / NDJSON) emitted while the pass runs, so the Scoring screen
//      can animate live.
//   2. A single `ScoreResult` document — the final result, emitted once the pass
//      completes.
//
// JSON key convention: the wire format is **snake_case**; the Swift types are
// camelCase. Decoding is done with `JSONDecoder.keyDecodingStrategy =
// .convertFromSnakeCase` (see `ScoreContract.decoder` / `ScoreContract.lineDecoder`),
// so there are **no per-field `CodingKeys`** — add a field here and matching
// snake_case key on the wire and it maps automatically. The one place this
// matters: enum *raw values* are NOT touched by the key strategy, so the
// `String` raw values below must match the wire spelling exactly (all lowercase).
//
// These types are `Decodable` only. Marks are read-only AI suggestions
// (ADR 0006); the app never encodes them back. The human's Favourite/selection
// is app-side state, deliberately absent from this input contract.

// MARK: Progress event

/// What the pass is doing when a progress line is emitted.
///
/// `loading` tags the single line the core emits the instant its scan finishes —
/// before the worker pool has spawned and imported its ML stack — so this line
/// carries the real `total` with `done == 0`. The app uses it to show the count and
/// a "Preparing…" state through the model-warmup window instead of a frozen 0-of-0
/// bar (which read as a hang). `scoring` is every subsequent per-frame tick.
/// Optional on the wire: an older core that doesn't send `phase` decodes to `nil`,
/// which the app treats as `scoring` (ADR-0008: the field is additive).
enum ScorePhase: String, Decodable, Sendable {
    case loading
    case scoring
}

/// One streamed progress event (one JSON line) emitted during scoring.
///
/// Elapsed / remaining time are **derived client-side** by `CoreBridge` from the
/// wall clock and the `done / total` ratio — the core does not carry them, so the
/// estimate stays honest to the machine actually running the pass. Only the raw
/// counts and the currently-processing frame travel on the wire.
struct ScoreProgress: Decodable, Sendable, Equatable {
    /// Number of frames scored so far (monotonic, 0 … `total`).
    let done: Int
    /// Total number of frames in the pass.
    let total: Int
    /// File name of the frame currently being analysed, e.g. `IMG_0421.CR3`.
    let currentFrameName: String
    /// Human-readable label of the burst the current frame belongs to,
    /// e.g. `Heron — takeoff`. Shown as "analysing · {label}".
    let currentBurstLabel: String
    /// What the pass is doing (`loading` model-warmup vs per-frame `scoring`).
    /// `nil` from an older core that predates the field — treated as `scoring`.
    let phase: ScorePhase?

    /// Completion fraction in 0…1, clamped. Convenience for the progress bar.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// True while the core is still warming up models and no frame has finished —
    /// the window the "Preparing…" UI covers.
    var isLoading: Bool {
        phase == .loading
    }
}

// MARK: Final result document

/// The grouping strategy a result was produced under (mirrors `cfg.group_method`).
enum Grouping: String, Decodable, Sendable {
    case time
    case similarity
}

/// AI exposure assessment for a frame. A soft **flag**, never a reject reason.
enum Exposure: String, Decodable, Sendable {
    case ok
    case blown
    case crushed
}

/// The AI's read-only recommendation for a frame (ADR 0006).
/// `keeper` is the *Best* mark (shown with a green badge/ring, never gold).
/// The human's gold Favourite star is separate app state, not part of this contract.
enum Mark: String, Decodable, Sendable {
    case keeper
    case maybe
    case rejected
}

/// The final result of a scoring pass: which grouping it used and the bursts it found.
struct ScoreResult: Decodable, Sendable {
    /// Which grouping strategy produced these bursts (`time` | `similarity`).
    let grouping: Grouping
    /// The bursts, in display order. Within each burst, frames are pre-sorted
    /// best → worst by the core (ADR-aligned; the app does not re-sort).
    let bursts: [ScoreBurst]
}

/// A group of near-duplicate / same-moment frames.
struct ScoreBurst: Decodable, Sendable, Identifiable {
    /// Stable identifier for this burst, unique within the result
    /// (e.g. `t0`, `s3`). Stable across re-renders so SwiftUI diffing is cheap.
    let id: String
    /// Human-readable burst title, e.g. `Heron — takeoff` or `First steps · group 2`.
    let label: String
    /// Capture timecode of the burst as a mono-formatted string, e.g. `07:42:11`.
    let time: String
    /// Whether this burst contains faces (drives the "· faces" header marker and
    /// the eyes-open gate semantics).
    let faces: Bool
    /// `id` of the burst's keeper frame (the AI *Best* pick). Always references a
    /// frame present in `frames`. Carried as the stable frame id rather than an
    /// index so it survives any client-side reordering.
    let keeperId: String
    /// The frames of this burst, best → worst.
    let frames: [ScoreFrame]

    /// The keeper frame resolved from `keeperId`, if present.
    var keeperFrame: ScoreFrame? {
        frames.first { $0.id == keeperId }
    }
}

/// A single scored frame — the read-only AI output for one photo.
struct ScoreFrame: Decodable, Sendable, Identifiable {
    /// Stable identifier for this frame, unique within the result (e.g. `p1_4`).
    /// Used as the SwiftUI identity and as the key for the human's Favourite set,
    /// so selections survive a regroup (ADR-aligned; selection is keyed by frame, not burst).
    let id: String
    /// Display file name, e.g. `IMG_0421.CR3`.
    let filename: String
    /// Sharpness score, 0–99 (Laplacian-variance derived). The ranking axis.
    let sharpness: Int
    /// Eyes-open confidence as a percentage 0–100, or `nil` when the frame has no
    /// face (so the UI shows "—" rather than a bogus 0).
    let eyes: Int?
    /// Number of faces detected in the frame.
    let faces: Int
    /// Exposure flag (`ok` | `blown` | `crushed`).
    let exposure: Exposure
    /// The AI's read-only recommendation (`keeper` | `maybe` | `rejected`).
    let mark: Mark
    /// Plain-English explanation of the mark, e.g. `Peak sharpness · eyes open`.
    let reason: String
    /// Original size of the source file in bytes (drives the mono size column in
    /// Review / Export and the export size estimate).
    let sizeBytes: Int64
    /// Path to the original source file, **relative** to the imported source root.
    /// Issue 4 decodes the real image from here; issue 10 copies the original out.
    /// Kept relative so the contract is portable; the app joins it to `sourceURL`.
    let relPath: String
}

// MARK: - Decoders

/// Shared decoders configured for the wire format. Use these everywhere the
/// contract is parsed so the snake_case ⇄ camelCase convention is applied uniformly.
enum ScoreContract {
    /// Decoder for the final `ScoreResult` document (and any whole-object JSON).
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Decoder for a single progress line. Same config as `decoder`; named
    /// separately so the JSON-lines parse site reads intentionally.
    static var lineDecoder: JSONDecoder {
        decoder
    }
}
