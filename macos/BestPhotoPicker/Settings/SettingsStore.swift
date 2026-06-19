import Foundation
import Observation

// MARK: - SettingsStore
//
// The everyday + advanced tuning knobs surfaced by the Settings screen
// (issue 11), held as the *display-domain* values the sliders bind to
// (matching the design prototype's `class Component` state and the README
// ranges), and persisted to the TOML config the Python core reads via `-c`.
//
// Two domains meet here:
//   • UI domain  — what the sliders show (e.g. similarity *likeness* 40–98 %,
//     face confidence as a 0.30–0.95 fraction). These are the fields below and
//     match the prototype's `timeGap`, `simThreshold`, `faceConf`, … exactly.
//   • Core domain — the flat field set `core/bestphoto/config.py` reads from a
//     TOML file. `ConfigWriter` translates UI → core and emits the TOML; the
//     two non-identity mappings (similarity likeness → Hamming distance,
//     highlights limit → luma value) are documented in `ConfigWriter`.
//
// Persistence is via `ConfigWriter` to
// `~/Library/Application Support/BestPhotoPicker/config.toml` — the same path
// issue 5's subprocess passes to the core. On launch the store seeds defaults,
// then `loadFromDisk()` overlays any values found in an existing config file so
// settings survive relaunch.

@Observable
@MainActor
final class SettingsStore {
    // MARK: Grouping (everyday knobs)

    /// Time grouping — gap in seconds. Slider 0.3…8, step 0.1, default 2.0.
    /// Shown as `2.0 s`. Maps directly to core `[burst] gap_seconds`.
    var timeGap: Double = 2.0

    /// Similarity grouping — *visual likeness* threshold as a whole percent.
    /// Slider 40…98, step 1, default 72. Shown as `72%`. Translated by
    /// `ConfigWriter` to core `[group] sim_max_distance` (higher likeness ⇒
    /// lower allowed Hamming distance).
    var simThreshold: Double = 72

    // MARK: Advanced — ML thresholds

    /// Face-detection confidence as a fraction. Slider 0.30…0.95, step 0.01,
    /// default 0.60. Shown as `60%`. Maps to core `[detect] yunet_score`.
    var faceConf: Double = 0.60

    /// Eyes-open threshold as a fraction. Slider 0.10…0.90, step 0.01,
    /// default 0.45. Shown as `45%`. Maps to core `[eyes] eye_open_min` and
    /// `[eyes] open_gate` (both the per-face cutoff and the portrait gate).
    var eyeThresh: Double = 0.45

    /// Highlights-blown limit as a fraction of the luma scale. Slider 0.80…1.0,
    /// step 0.005, default 0.94. Shown as `94.0%`. Translated to core
    /// `[exposure] blown_value` (0…255 luma).
    var blownLimit: Double = 0.94

    /// Shadows-crushed limit — fraction of pixels crushed to black. Slider
    /// 0…0.20, step 0.005, default 0.04. Shown as `4.0%`. Maps to core
    /// `[exposure] crushed_frac`.
    var crushLimit: Double = 0.04

    /// Rejection sharpness ratio. Slider 0.50…0.95, step 0.01, default 0.78.
    /// Shown as `0.78×`. Maps to core `[reject] sharpness_ratio`.
    var rejectRatio: Double = 0.78

    // MARK: Display formatting (mirrors the prototype's `adv` value strings)

    /// `2.0 s` — one decimal.
    var timeGapDisplay: String { String(format: "%.1f s", timeGap) }
    /// `72%` — whole percent.
    var simThresholdDisplay: String { "\(Int(simThreshold.rounded()))%" }
    /// `60%` — `(faceConf*100).toFixed(0)+'%'`.
    var faceConfDisplay: String { "\(Int((faceConf * 100).rounded()))%" }
    /// `45%` — `(eyeThresh*100).toFixed(0)+'%'`.
    var eyeThreshDisplay: String { "\(Int((eyeThresh * 100).rounded()))%" }
    /// `94.0%` — `(blownLimit*100).toFixed(1)+'%'`.
    var blownLimitDisplay: String { String(format: "%.1f%%", blownLimit * 100) }
    /// `4.0%` — `(crushLimit*100).toFixed(1)+'%'`.
    var crushLimitDisplay: String { String(format: "%.1f%%", crushLimit * 100) }
    /// `0.78×` — `rejectRatio.toFixed(2)+'×'`.
    var rejectRatioDisplay: String { String(format: "%.2f×", rejectRatio) }

    // MARK: Persistence

    private let writer: ConfigWriter

    init(writer: ConfigWriter = ConfigWriter()) {
        self.writer = writer
    }

    /// Overlay any values found in an existing config file onto the defaults.
    /// Absent keys keep the seeded default, so a partial / hand-edited file is
    /// safe. Called once on launch (from `AppModel`).
    func loadFromDisk() {
        guard let values = writer.read() else { return }
        if let v = values.timeGap { timeGap = v }
        if let v = values.simThreshold { simThreshold = v }
        if let v = values.faceConf { faceConf = v }
        if let v = values.eyeThresh { eyeThresh = v }
        if let v = values.blownLimit { blownLimit = v }
        if let v = values.crushLimit { crushLimit = v }
        if let v = values.rejectRatio { rejectRatio = v }
    }

    /// Persist the current values to the TOML config. Cheap and synchronous
    /// (one small string written atomically); called debounced from the view
    /// whenever a slider settles, and once after `loadFromDisk()` to guarantee
    /// the file exists for the core on first launch.
    func save() {
        writer.write(self)
    }
}
