import Foundation

// MARK: - ConfigWriter
//
// Reads and writes the TOML config the Python core consumes (`bestphoto score
// -c <file>`). It owns the **UI ⇄ core domain translation** and the on-disk
// path contract shared with issue 5.
//
// ── Path contract (shared with issue 5) ────────────────────────────────────
//   ~/Library/Application Support/BestPhotoPicker/config.toml
// Issue 5's subprocess engine passes exactly this file to the core via `-c`.
// The directory is created on demand.
//
// ── TOML schema ─────────────────────────────────────────────────────────────
// We mirror the flat field set `core/bestphoto/config.py` reads (it flattens
// the TOML sections in `Config.load`). We write **only the keys this screen
// manages**; every absent key keeps the core's own field default, so the file
// stays minimal and forward-compatible. Keys / sections used (verbatim from
// `config.example.toml`):
//
//   [group]  method, sim_max_distance
//   [burst]  gap_seconds
//   [detect] yunet_score
//   [eyes]   eye_open_min, open_gate
//   [exposure] blown_value, crushed_frac
//   [reject] sharpness_ratio
//
// No TOML library: the document is tiny and the value set is closed (numbers +
// one quoted string), so a hand emitter / scanner is correct and dependency-free.

struct ConfigWriter {
    /// Values read back from an existing config, in the **UI domain** (already
    /// translated from core units). Any field may be `nil` if its key/section
    /// was absent, so the store keeps its default.
    struct Values {
        var timeGap: Double?
        var simThreshold: Double?
        var faceConf: Double?
        var eyeThresh: Double?
        var blownLimit: Double?
        var crushLimit: Double?
        var rejectRatio: Double?
    }

    /// Perceptual hash is 64-bit (`phash_size = 8` ⇒ 8×8 dHash), so the max
    /// possible Hamming distance is 64. Used to translate the similarity
    /// *likeness* slider to/from the core's `sim_max_distance`.
    private static let phashBits = 64.0

    /// Luma scale for the highlights-blown limit ⇄ `blown_value` translation.
    private static let lumaMax = 255.0

    var fileURL: URL = ConfigWriter.defaultFileURL

    /// `~/Library/Application Support/BestPhotoPicker/config.toml`.
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("BestPhotoPicker", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    // MARK: UI ⇄ core translation

    /// Similarity *likeness %* (40…98) → core `sim_max_distance` (Hamming, 0…64,
    /// lower = stricter). Higher likeness tolerates fewer differing bits.
    static func simDistance(fromLikeness likeness: Double) -> Int {
        let frac = max(0, min(1, (100 - likeness) / 100))
        return Int((frac * phashBits).rounded())
    }

    /// Inverse of `simDistance` — recover the likeness % the UI shows.
    static func likeness(fromSimDistance distance: Int) -> Double {
        let frac = max(0, min(1, Double(distance) / phashBits))
        return (1 - frac) * 100
    }

    /// Highlights-blown limit fraction (0.80…1.0) → core `blown_value` (0…255).
    static func blownValue(fromLimit limit: Double) -> Int {
        Int((max(0, min(1, limit)) * lumaMax).rounded())
    }

    /// Inverse of `blownValue` — recover the limit fraction the UI shows.
    static func blownLimit(fromValue value: Int) -> Double {
        Double(value) / lumaMax
    }

    // MARK: Write

    /// Emit the store's current values as minimal TOML and write atomically,
    /// creating the parent directory if missing. Best-effort: failures (e.g.
    /// sandbox denial) are swallowed so a write can never crash the UI.
    @MainActor
    func write(_ store: SettingsStore) {
        let toml = Self.render(store)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try? toml.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    /// Build the TOML text for the given store. Pure (no I/O) so it is trivially
    /// testable and reviewable against `config.example.toml`.
    @MainActor
    static func render(_ s: SettingsStore) -> String {
        let groupMethod = "similarity"   // README default; the Review screen switches it per-run.
        var lines: [String] = []
        lines.append("# Best Photo Picker — written by the macOS app's Settings screen.")
        lines.append("# Consumed by the core via `bestphoto score -c <this file>`.")
        lines.append("")
        lines.append("[group]")
        lines.append("method = \(quoted(groupMethod))")
        lines.append("sim_max_distance = \(int(simDistance(fromLikeness: s.simThreshold)))")
        lines.append("")
        lines.append("[burst]")
        lines.append("gap_seconds = \(num(s.timeGap))")
        lines.append("")
        lines.append("[detect]")
        lines.append("yunet_score = \(num(s.faceConf))")
        lines.append("")
        lines.append("[eyes]")
        lines.append("eye_open_min = \(num(s.eyeThresh))")
        lines.append("open_gate = \(num(s.eyeThresh))")
        lines.append("")
        lines.append("[exposure]")
        lines.append("blown_value = \(int(blownValue(fromLimit: s.blownLimit)))")
        lines.append("crushed_frac = \(num(s.crushLimit))")
        lines.append("")
        lines.append("[reject]")
        lines.append("sharpness_ratio = \(num(s.rejectRatio))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Read

    /// Parse an existing config file back into UI-domain `Values`. Returns `nil`
    /// when the file is absent/unreadable (caller keeps defaults). A tolerant,
    /// section-aware scanner for our own minimal output — not a full TOML parser.
    func read() -> Values? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        var section = ""
        var raw: [String: Double] = [:]          // "section.key" -> value
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var valuePart = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            if let hash = valuePart.firstIndex(of: "#") {   // strip trailing comment
                valuePart = String(valuePart[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if let n = Double(valuePart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
                raw["\(section).\(key)"] = n
            }
        }

        var v = Values()
        if let g = raw["burst.gap_seconds"] { v.timeGap = g }
        if let d = raw["group.sim_max_distance"] {
            v.simThreshold = Self.likeness(fromSimDistance: Int(d.rounded()))
        }
        if let f = raw["detect.yunet_score"] { v.faceConf = f }
        if let e = raw["eyes.eye_open_min"] { v.eyeThresh = e }
        if let b = raw["exposure.blown_value"] {
            v.blownLimit = Self.blownLimit(fromValue: Int(b.rounded()))
        }
        if let c = raw["exposure.crushed_frac"] { v.crushLimit = c }
        if let r = raw["reject.sharpness_ratio"] { v.rejectRatio = r }
        return v
    }

    // MARK: TOML scalar formatting

    /// Format a float without locale surprises and without a trailing `.0`-less
    /// integer ambiguity: always keep at least one fractional digit so TOML
    /// reads it as a float (the core's fields are floats). Trims noise from
    /// binary rounding (e.g. `0.7800000001` → `0.78`).
    private static func num(_ value: Double) -> String {
        var s = String(format: "%.6f", value)
        while s.contains(".") && s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    private static func int(_ value: Int) -> String { String(value) }

    private static func quoted(_ value: String) -> String { "\"\(value)\"" }
}
