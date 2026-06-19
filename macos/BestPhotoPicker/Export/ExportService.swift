import Foundation

// MARK: - ExportService (issue 10)
//
// The real delivery of the human's picks. Given the source root and a set of
// Favourite frames, it COPIES each original photo into the chosen destination as a
// real file and writes an export manifest CSV alongside them.
//
// ── Non-destructive by construction (ADR 0001 / 0002 / 0006) ────────────────
// "Deliver favourites" = COPY, never move or delete (ADR 0002, extended by
// ADR 0006). Originals are only ever *read*: we resolve `source/relPath`,
// `FileManager.copyItem` it to `destination/filename`, and never touch, rename, or
// remove the source. There is no `moveItem`, no `removeItem` on a source path, and
// no write back into the source tree anywhere in this file — that invariant is the
// point of the tool, so keep it.
//
// ── Off the main actor ──────────────────────────────────────────────────────
// `run(...)` is plain `async` (no actor) and only touches the file system + value
// types, so it executes off the main actor. It takes a `progress` callback that the
// caller (AppModel, @MainActor) hops back to the main actor inside. The final
// `ExportReport` is a `Sendable` value returned to the caller.
//
// ── Fixture reality ─────────────────────────────────────────────────────────
// The bundled fixture's `relPath`s are not real files, so with fixture data every
// item is reported as `.skippedMissingSource` and nothing is copied — by design.
// The UI shows that result cleanly (no crash). Once issue 5 feeds real core output
// with a real source folder, the same code path copies real files.

/// Defaults for the export destination.
enum ExportDefaults {
    /// `~/Pictures` — the sensible default delivery folder. Falls back to the home
    /// directory if (improbably) Pictures can't be located.
    static var picturesFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

/// One frame to deliver — a `Sendable` snapshot of the fields the export needs,
/// taken from a `ScoreFrame` on the main actor so the service stays decoupled from
/// the UI contract and the manifest columns are explicit.
struct ExportItem: Sendable, Identifiable {
    let id: String
    /// Display / destination file name, e.g. `IMG_0421.CR3`.
    let filename: String
    /// Path to the original, relative to the imported source root.
    let relPath: String
    /// The AI's read-only recommendation (written into the manifest, ADR 0006).
    let mark: Mark
    /// Sharpness 0–99 (written into the manifest).
    let sharpness: Int
    /// Original file size in bytes (for the manifest + size estimate).
    let sizeBytes: Int64

    init(frame: ScoreFrame) {
        self.id = frame.id
        self.filename = frame.filename
        self.relPath = frame.relPath
        self.mark = frame.mark
        self.sharpness = frame.sharpness
        self.sizeBytes = frame.sizeBytes
    }
}

/// What happened to one item during an export run.
enum ExportOutcome: Sendable, Equatable {
    /// Copied to this on-disk file name (may differ from the original on collision).
    case copied(destName: String)
    /// The source file did not exist or was unreadable — skipped (fixture path).
    case skippedMissingSource
    /// The copy failed with this OS error message — skipped.
    case failed(message: String)
}

/// The result of one item's delivery: which item, and what happened.
struct ExportItemResult: Sendable, Identifiable {
    let item: ExportItem
    let outcome: ExportOutcome
    var id: String { item.id }
}

/// The summary of a whole export run, surfaced to the UI.
struct ExportReport: Sendable {
    /// Per-item results, in the order the items were given.
    let results: [ExportItemResult]
    /// Absolute path to the manifest written into the destination, if it was
    /// written (it is written whenever there is ≥1 item, even if all copies skip,
    /// so the human's verdict is recorded). `nil` if the manifest itself failed.
    let manifestPath: String?

    var copiedCount: Int {
        results.filter { if case .copied = $0.outcome { return true } else { return false } }.count
    }
    var skippedCount: Int {
        results.filter { if case .skippedMissingSource = $0.outcome { return true } else { return false } }.count
    }
    var failedCount: Int {
        results.filter { if case .failed = $0.outcome { return true } else { return false } }.count
    }

    /// A one-line, plain-English summary for the UI footer/banner.
    var summary: String {
        var parts: [String] = []
        if copiedCount > 0 { parts.append("\(copiedCount) copied") }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped (source not found)") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if parts.isEmpty { return "Nothing to export." }
        return parts.joined(separator: " · ")
    }
}

/// Live progress while an export runs (drives a determinate readout in the UI).
struct ExportProgress: Sendable, Equatable {
    let done: Int
    let total: Int
}

/// Copies favourite originals to a destination and writes the export manifest.
/// Stateless and `Sendable`; instantiate freely. All work is file-system I/O on
/// value types, so it runs off the main actor.
struct ExportService: Sendable {
    /// Name of the manifest written INTO the destination folder (ADR 0006).
    static let manifestFileName = "selects-manifest.csv"

    /// The file manager used for all I/O. A computed `.default` (the thread-safe
    /// singleton) rather than a stored property, so the service stays `Sendable`
    /// without holding a non-`Sendable` `FileManager`.
    private var fileManager: FileManager { .default }

    /// Copy every `item`'s original from `source/relPath` to `destination/filename`,
    /// then write the export manifest into `destination`. Reports per-item outcomes
    /// and a manifest path.
    ///
    /// - Collisions: if `destination/filename` already exists, the copy is written
    ///   as `name-1.ext`, `name-2.ext`, … (never overwriting an existing file).
    /// - Missing/unreadable source: skipped as `.skippedMissingSource` (the fixture
    ///   path) — no throw, the run continues.
    /// - Other copy errors: captured as `.failed(message:)` per item — no throw.
    /// - `source == nil` (no folder imported): every item is `.skippedMissingSource`.
    ///
    /// Originals are only read; nothing in the source tree is moved, renamed, or
    /// deleted.
    func run(
        items: [ExportItem],
        source: URL?,
        destination: URL,
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) async -> ExportReport {
        // Ensure the destination exists (it normally does — the user picked it).
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Track names already claimed in this run so two same-named sources from
        // different sub-folders don't collide with each other (not just with files
        // already on disk).
        var claimedNames = Set<String>()
        var results: [ExportItemResult] = []
        results.reserveCapacity(items.count)

        let total = items.count
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            let outcome = copy(item, source: source, destination: destination, claimed: &claimedNames)
            results.append(ExportItemResult(item: item, outcome: outcome))
            progress(ExportProgress(done: index + 1, total: total))
        }

        // Write the manifest into the delivered folder — the durable record of the
        // human's verdict (ADR 0006). Written whenever there is anything to export,
        // even if all copies skipped, so the favourite decision is captured.
        let manifestPath = items.isEmpty
            ? nil
            : writeManifest(results: results, destination: destination)

        return ExportReport(results: results, manifestPath: manifestPath)
    }

    // MARK: Copy one item

    private func copy(
        _ item: ExportItem,
        source: URL?,
        destination: URL,
        claimed: inout Set<String>
    ) -> ExportOutcome {
        guard let source else { return .skippedMissingSource }
        let srcURL = source.appending(path: item.relPath)
        // Missing / unreadable source → skip cleanly (the fixture path).
        guard fileManager.fileExists(atPath: srcURL.path),
              fileManager.isReadableFile(atPath: srcURL.path) else {
            return .skippedMissingSource
        }

        let destName = uniqueName(for: item.filename, in: destination, claimed: &claimed)
        let destURL = destination.appending(path: destName)
        do {
            // COPY (read source, write dest). Never move/delete the original.
            try fileManager.copyItem(at: srcURL, to: destURL)
            return .copied(destName: destName)
        } catch {
            // Release the claim so a later item could reuse the name.
            claimed.remove(destName)
            return .failed(message: error.localizedDescription)
        }
    }

    /// A destination file name that collides with neither an existing on-disk file
    /// nor a name already claimed in this run. Suffixes `-1`, `-2`, … before the
    /// extension. The chosen name is recorded in `claimed`.
    private func uniqueName(for filename: String, in destination: URL, claimed: inout Set<String>) -> String {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        func assemble(_ stem: String) -> String {
            ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        func isFree(_ name: String) -> Bool {
            !claimed.contains(name) && !fileManager.fileExists(atPath: destination.appending(path: name).path)
        }

        var candidate = filename
        if isFree(candidate) {
            claimed.insert(candidate)
            return candidate
        }
        var n = 1
        repeat {
            candidate = assemble("\(base)-\(n)")
            n += 1
        } while !isFree(candidate)
        claimed.insert(candidate)
        return candidate
    }

    // MARK: Manifest (favourite → manifest, ADR 0006)

    /// Write `selects-manifest.csv` into `destination`. One row per export item with
    /// the relative source path, the on-disk delivered name, the AI mark, sharpness,
    /// and `favourite=true` — the GUI recording the human's verdict as a durable
    /// artifact in the delivered folder. Returns the absolute path, or `nil` on
    /// failure (the copy still succeeded; the manifest is best-effort).
    private func writeManifest(results: [ExportItemResult], destination: URL) -> String? {
        var rows = "rel_path,filename,exported_as,mark,sharpness,favourite\n"
        for result in results {
            let item = result.item
            let exportedAs: String
            switch result.outcome {
            case .copied(let name): exportedAs = name
            case .skippedMissingSource, .failed: exportedAs = ""
            }
            let fields = [
                item.relPath,
                item.filename,
                exportedAs,
                item.mark.rawValue,
                "\(item.sharpness)",
                "true",
            ].map(Self.csvEscape)
            rows += fields.joined(separator: ",") + "\n"
        }

        let url = destination.appending(path: Self.manifestFileName)
        do {
            try rows.data(using: .utf8)?.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// Minimal RFC-4180 CSV escaping: wrap in quotes and double inner quotes when the
    /// field contains a comma, quote, or newline.
    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
