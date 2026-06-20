import Foundation
import AppKit
import Observation

enum Screen {
    case importSession
    case scoring
    case review
    case export
    case settings
}

/// Which AI mark the Review grid is showing. The filter seam issue 6 builds chips
/// against; `.all` shows every frame. `keeper` is the *Best* mark.
enum MarkFilter {
    case all
    case keeper
    case maybe
    case rejected

    /// The `Mark` this filter narrows to, or `nil` for `.all` (show everything).
    var mark: Mark? {
        switch self {
        case .all: return nil
        case .keeper: return .keeper
        case .maybe: return .maybe
        case .rejected: return .rejected
        }
    }
}

/// Thumbnail sizing on the Review grid (README: comfortable 196px / dense 132px).
enum Density {
    case comfortable
    case dense
}

@Observable
@MainActor
final class AppModel {
    var screen: Screen = .importSession

    /// The user's tuning knobs (issue 11), bound by the Settings screen and
    /// persisted to the TOML config the core reads via `-c`. Loaded from disk on
    /// launch so settings survive relaunch; an initial `save()` guarantees the
    /// config file exists for the core on first run.
    let settings = SettingsStore()

    var sourceURL: URL?
    var detectedPhotoCount: Int?
    var detectedSizeBytes: Int64?
    var detectedFileTypeCount: Int?

    var bestCount: Int = 0
    var selectedCount: Int = 0

    // MARK: Scoring state (issue 2)

    /// Scored progress fraction in 0…1; drives the bar and the big percentage.
    var scoringProgress: Double = 0
    /// Frames scored so far.
    var scoringDone: Int = 0
    /// Total frames in the pass (0 until the first progress event arrives).
    var scoringTotal: Int = 0
    /// File name of the frame currently being analysed (now-processing card).
    var scoringCurrentFrame: String = ""
    /// Label of the burst the current frame belongs to.
    var scoringCurrentBurstLabel: String = ""
    /// What the pass is doing right now (`loading` model-warmup vs per-frame
    /// `scoring`). `nil` before the first event; `.loading` through the silent
    /// model-warmup window so the now-processing card shows "Preparing…" with the
    /// real total instead of a frozen 0-of-0 (the "looks stuck" fix).
    var scoringPhase: ScorePhase?
    /// Elapsed wall-clock since scoring started, derived client-side.
    var scoringElapsed: TimeInterval = 0
    /// Estimated remaining time, derived from elapsed × (total/done − 1).
    var scoringRemaining: TimeInterval = 0
    /// The ACTIVE displayed result — the bursts the Review grid, toolbar counts,
    /// preview, and footer all read. Kept assigned in lockstep with
    /// `activeGrouping` + `resultsByGrouping` (see `applyActiveGrouping()`): it is
    /// always `resultsByGrouping[activeGrouping]`. `nil` until the first pass
    /// finishes (or after a reset). Issue 8 switches it on a grouping toggle.
    var scoreResult: ScoreResult?

    /// Results cached per grouping (issue 8). The scoring pass fills one entry
    /// (similarity by default); a one-time regroup fills the other. Once both are
    /// present, toggling grouping is an instant cache swap — no rescore. Frame ids
    /// are shared across groupings, so `favourites` survive a switch.
    var resultsByGrouping: [Grouping: ScoreResult] = [:]

    /// The grouping currently displayed (STORED — issue 8). Defaults to
    /// `.similarity` (the README default) before any result loads. The toolbar's
    /// segmented control reflects this; `selectGrouping(_:)` changes it.
    var activeGrouping: Grouping = .similarity

    // MARK: Regroup job state (issue 8)
    //
    // Set while a one-time regroup pass runs for an uncomputed grouping. Drives the
    // centered RegroupPanel (spinner, mono %, "{done} of N clustered", gold bar,
    // Cancel). Cleared on completion (result cached + switched) or Cancel.

    /// Whether a regroup job is in flight. Top precedence in ReviewView's grid body.
    var regrouping: Bool = false
    /// Frames clustered so far in the regroup pass (the bold mono count).
    var regroupDone: Int = 0
    /// Total frames in the regroup pass (0 until the first progress event).
    var regroupTotal: Int = 0
    /// The grouping the in-flight regroup is computing (for the panel's title copy).
    var regroupTarget: Grouping = .time

    /// Which grouping the toolbar shows as active: the in-flight regroup's target
    /// while regrouping (so the tab moves to it the instant it's clicked), otherwise
    /// the committed `activeGrouping`.
    var displayedGrouping: Grouping { regrouping ? regroupTarget : activeGrouping }

    /// The unstructured task driving the regroup stream; cancelled by `cancelRegroup`.
    private var regroupTask: Task<Void, Never>?

    /// Monotonic clock reading at the moment scoring started (for elapsed/remaining).
    private var scoringStartedAt: ContinuousClock.Instant?

    init() {
        // Persist-across-sessions: overlay any saved config onto the seeded
        // defaults, then write once so the core always has a config file to read.
        settings.loadFromDisk()
        settings.save()
    }

    // MARK: Review state (issue 3) — shared seams for issues 4/6/7/8

    /// The user's selection = the export set, keyed by stable `ScoreFrame.id`.
    /// A *Favourite* (ADR 0006) — the only state the user sets, gold-coloured, and
    /// orthogonal to the AI's read-only `mark`. Keyed by frame id (not burst) so it
    /// survives a regroup (issue 8). Keep `selectedCount` in sync with `count`.
    var favourites: Set<String> = []

    /// Which AI mark the grid is filtered to. Issue 6 adds the chip UI; the grid
    /// already honours this when computing visible frames. `.all` shows everything.
    var markFilter: MarkFilter = .all

    /// Thumbnail sizing on the grid. Issue 3 ships `.comfortable`; a visible toggle
    /// is optional and deferred.
    var density: Density = .comfortable

    // MARK: Export state (issue 10)
    //
    // The Export screen delivers the human's picks: it COPIES every Favourite's
    // ORIGINAL into `exportDestination` as a real file and writes an export manifest
    // there (ADR 0001/0002/0006 — copy, never move/delete). The export SET is every
    // frame across the active result whose id is a Favourite; because frame ids are
    // shared across groupings, this lists every favourite regardless of the active
    // grouping.

    /// Where Export copies the starred originals. Defaults to `~/Pictures`; the
    /// "Choose…" picker (`chooseExportDestination()`) repoints it. Plain state — the
    /// copy itself runs in `ExportService` off the main actor.
    var exportDestination: URL = ExportDefaults.picturesFolder

    /// Whether an export run is in flight (drives the button's disabled/running
    /// state). Cleared when the run finishes.
    var isExporting: Bool = false

    /// Live progress of the in-flight export (`done`/`total`), or `nil` when idle.
    var exportProgress: ExportProgress?

    /// The most recent export result, surfaced as a result banner. `nil` until the
    /// first run completes; cleared when the export set changes or on a new run.
    var exportReport: ExportReport?

    /// The unstructured task driving the export copy; created by ExportView.
    private var exportTask: Task<Void, Never>?

    // MARK: Review states (issue 9)

    /// Transient "Building previews…" state for the Review grid. Set true the
    /// moment a fresh `scoreResult` lands (see `runScoring()` → `.completed`) and
    /// cleared shortly after by the grid's first appearance (`ReviewView`'s
    /// `.task`), so it shows as a real on-entry beat while thumbnails warm up —
    /// not a UI toggle. `resetScoringState()` also clears it on a new pass.
    var isBuildingPreviews: Bool = false

    /// Whether the face & eye-open model failed to load for this pass. When true
    /// the Review grid shows the "Face model unavailable" card (sharpness +
    /// exposure still ran; the Keeper falls back to the sharpest frame). This is a
    /// HOOK: the real trigger is the core signalling a missing landmarker — a
    /// future `ScoreResult` field from issue 5, which `runScoring()` will map onto
    /// this flag on `.completed`. Until that contract field exists this stays
    /// `false` (default); `continueWithoutFaces()` clears it.
    var faceModelUnavailable: Bool = false

    /// Whether the full-screen Preview overlay is open. Issue 7 builds the overlay
    /// UI; issue 3 only flips this state (and the indices below) on a thumbnail tap.
    var isPreviewOpen: Bool = false
    /// Index (into the active result's `bursts`) of the burst being previewed.
    var previewBurstIndex: Int = 0
    /// Index (into that burst's *displayed* frames) of the frame being previewed.
    var previewFrameIndex: Int = 0
    /// Whether the Preview stage is zoomed to 100% (issue 7). Reset whenever the
    /// preview opens, closes, or moves to another frame.
    var previewZoom: Bool = false
    /// One-stop "end of burst" interstitial. Stepping forward (→) off the LAST
    /// displayed frame lands here instead of wrapping straight to the first; a
    /// second → then wraps. So the wrap-around is deliberate, never accidental.
    /// Cleared by any other navigation (←, ↑/↓ burst, filmstrip tap, open, close).
    var previewAtBurstEnd: Bool = false

    /// Toggle a frame's Favourite (the user's pick / export set). The sole user
    /// action on the grid. Keeps `selectedCount` in sync.
    func toggleFavourite(_ id: String) {
        if favourites.contains(id) {
            favourites.remove(id)
        } else {
            favourites.insert(id)
        }
        selectedCount = favourites.count
        // The previous export run's report no longer matches the new selection.
        exportReport = nil
    }

    func isFavourite(_ id: String) -> Bool {
        favourites.contains(id)
    }

    // MARK: Review-state derivation + actions (issue 9)

    /// True when the active `markFilter` leaves zero visible frames across every
    /// burst of the current result — the real "Nothing matches" condition. False
    /// when there is no result yet (nothing has loaded, so the empty *filter* card
    /// would be misleading; loading/normal handle that). Mirrors the grid's own
    /// visibility rule (`ScoreBurst.visibleFrames`).
    var hasNoFilterMatches: Bool {
        guard let result = scoreResult else { return false }
        return result.bursts.allSatisfy { $0.visibleFrames(filter: markFilter).isEmpty }
    }

    /// Clear the active filter so every burst is visible again — the empty card's
    /// "Reset view" action.
    func resetFilter() {
        markFilter = .all
    }

    /// "Continue without faces" / "Retry model" on the no-faces card. Both clear
    /// the flag and drop back to the grid (sharpness+exposure scoring already ran).
    /// Once issue 5's contract lands, "Retry model" would additionally re-request a
    /// score; for now both simply dismiss the card.
    func continueWithoutFaces() {
        faceModelUnavailable = false
    }

    /// Clear the transient "Building previews…" state. Called by the Review grid's
    /// first appearance once it is on screen, so loading reads as a real on-entry
    /// beat rather than a forced toggle.
    func previewsReady() {
        isBuildingPreviews = false
    }

    /// Open intent for the Preview overlay (issue 7 renders it). Records which
    /// burst/frame to show and flips `isPreviewOpen`. Resets zoom so each open
    /// starts fit-to-stage.
    func openPreview(burstIndex: Int, frameIndex: Int) {
        previewBurstIndex = burstIndex
        previewFrameIndex = frameIndex
        previewZoom = false
        previewAtBurstEnd = false
        isPreviewOpen = true
    }

    // MARK: Preview navigation (issue 7)
    //
    // `previewFrameIndex` indexes into the burst's DISPLAYED frames —
    // `burst.visibleFrames(filter: markFilter)` — NOT the raw `burst.frames`, so
    // the preview matches the grid the user clicked from (issue 3). All resolution
    // and navigation go through that same ordering.

    /// The burst currently being previewed, guarded against an out-of-range index
    /// (e.g. after the result changed). `nil` when there is no result / no burst.
    var previewBurst: ScoreBurst? {
        guard let bursts = scoreResult?.bursts,
              previewBurstIndex >= 0, previewBurstIndex < bursts.count
        else { return nil }
        return bursts[previewBurstIndex]
    }

    /// The displayed frames of the current preview burst, in the grid's order
    /// (filter applied, best → worst). Empty when there is no preview burst.
    var previewVisibleFrames: [ScoreFrame] {
        previewBurst?.visibleFrames(filter: markFilter) ?? []
    }

    /// The frame currently being previewed, resolved through the displayed frames
    /// and guarded against an out-of-range index. `nil` when nothing to show.
    var previewFrame: ScoreFrame? {
        let frames = previewVisibleFrames
        guard previewFrameIndex >= 0, previewFrameIndex < frames.count else { return nil }
        return frames[previewFrameIndex]
    }

    /// Close the Preview overlay and reset zoom.
    func closePreview() {
        isPreviewOpen = false
        previewZoom = false
        previewAtBurstEnd = false
    }

    /// Move to the previous displayed frame in the current burst, wrapping. Resets
    /// zoom on move. No-op when the burst has no displayed frames.
    func previewPrev() {
        let count = previewVisibleFrames.count
        guard count > 0 else { return }
        previewZoom = false
        // ← from the end-of-burst screen steps back onto the last frame.
        if previewAtBurstEnd {
            previewAtBurstEnd = false
            return
        }
        previewFrameIndex = (previewFrameIndex - 1 + count) % count
    }

    /// Move to the next displayed frame in the current burst. From the LAST frame,
    /// → first lands on the end-of-burst stop screen; a second → wraps to the
    /// first frame. Resets zoom on move. No-op when the burst has no displayed
    /// frames.
    func previewNext() {
        let count = previewVisibleFrames.count
        guard count > 0 else { return }
        previewZoom = false
        // Second → off the end screen: wrap to the first frame.
        if previewAtBurstEnd {
            previewAtBurstEnd = false
            previewFrameIndex = 0
            return
        }
        // → off the last frame: stop on the end-of-burst screen (don't wrap yet).
        if previewFrameIndex >= count - 1 {
            previewAtBurstEnd = true
            return
        }
        previewFrameIndex += 1
    }

    /// Move to the previous burst (group) that has displayed frames, wrapping, and
    /// land on its first (best) displayed frame. Up arrow in the Preview. Resets
    /// zoom. Skips bursts the active filter hides so it steps only through groups
    /// the user can see (mirrors the grid). No-op with no result.
    func previewPrevBurst() {
        stepBurst(by: -1)
    }

    /// Move to the next burst (group) that has displayed frames, wrapping, landing
    /// on its first (best) displayed frame. Down arrow in the Preview. Resets zoom.
    func previewNextBurst() {
        stepBurst(by: 1)
    }

    /// Walk `bursts` from the current index by `step` (±1), wrapping, until a burst
    /// with displayed frames under the active filter is found; land on its first
    /// frame. At most one full loop, so it terminates even if only one burst is
    /// visible (lands back on the current one). Resets zoom on move.
    private func stepBurst(by step: Int) {
        guard let bursts = scoreResult?.bursts, !bursts.isEmpty else { return }
        let n = bursts.count
        var i = previewBurstIndex
        for _ in 0..<n {
            i = (i + step + n) % n
            if !bursts[i].visibleFrames(filter: markFilter).isEmpty {
                previewBurstIndex = i
                previewFrameIndex = 0
                previewZoom = false
                previewAtBurstEnd = false
                return
            }
        }
    }

    /// Jump to a specific displayed-frame index in the current burst (filmstrip
    /// tap). Clamped to range; resets zoom.
    func previewSelect(frameIndex: Int) {
        let count = previewVisibleFrames.count
        guard count > 0 else { return }
        previewFrameIndex = min(max(0, frameIndex), count - 1)
        previewZoom = false
        previewAtBurstEnd = false
    }

    /// Toggle the current preview frame's Favourite (the user's pick / export set).
    /// Keyed by frame id, like the grid star. No-op when there is no current frame.
    func previewToggleFavourite() {
        guard !previewAtBurstEnd, let frame = previewFrame else { return }
        toggleFavourite(frame.id)
    }

    /// Whether the current preview frame is a Favourite.
    var previewIsFavourite: Bool {
        guard let frame = previewFrame else { return false }
        return isFavourite(frame.id)
    }

    /// Toggle the 100% zoom on the preview stage. No-op on the end-of-burst
    /// screen — there is no photo to zoom there.
    func previewToggleZoom() {
        guard !previewAtBurstEnd else { return }
        previewZoom.toggle()
    }

    // MARK: Grouping switch + regroup (issue 8)

    /// The toolbar segmented control's action. If the requested grouping is already
    /// cached, switch INSTANTLY (cache swap, no job). If not, start a one-time
    /// regroup job: a centered progress panel runs the engine for `grouping`, and
    /// on completion caches + switches to it. A no-op when already active or while a
    /// regroup for the same target is already running. Favourites are untouched
    /// (keyed by frame id, shared across groupings), so the same frames stay
    /// starred and the Export count is stable across the switch.
    func selectGrouping(_ grouping: Grouping) {
        guard grouping != activeGrouping else { return }
        if resultsByGrouping[grouping] != nil {
            // Cached → instant swap.
            activeGrouping = grouping
            applyActiveGrouping()
            return
        }
        // Uncomputed → run the one-time regroup job.
        startRegroup(grouping)
    }

    /// Re-point `scoreResult` (and the derived `bestCount`) at the active grouping's
    /// cached result. Keeps every reader of `scoreResult` working off one stored
    /// value while `activeGrouping` is the single source of truth for *which*.
    /// `favourites` are intentionally NOT touched — they persist across groupings.
    private func applyActiveGrouping() {
        scoreResult = resultsByGrouping[activeGrouping]
        recomputeBestCount()
    }

    /// "Best" = the AI's keeper picks (one per burst) in the ACTIVE grouping —
    /// matches the Review "Best" filter count and the title-bar subtitle. Differs
    /// between groupings because the burst structure (and so the keeper picks) does.
    private func recomputeBestCount() {
        bestCount = scoreResult?.bursts.reduce(0) { acc, burst in
            acc + burst.frames.filter { $0.mark == .keeper }.count
        } ?? 0
    }

    /// Begin a one-time regroup pass for `grouping`: show the panel, stream the
    /// engine's progress into the regroup state, and on completion cache the result,
    /// switch to it, and dismiss the panel. Cancellable via `cancelRegroup()`.
    private func startRegroup(_ grouping: Grouping) {
        regroupTask?.cancel()
        regrouping = true
        regroupTarget = grouping
        regroupDone = 0
        regroupTotal = 0
        regroupTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in CoreBridge.live.score(
                    source: self.sourceURL, grouping: grouping
                ) {
                    switch event {
                    case .progress(let p):
                        self.regroupDone = p.done
                        self.regroupTotal = p.total
                    case .completed(let result):
                        self.finishRegroup(with: result)
                    }
                }
                // Stream ended; if it ended without a completion (shouldn't happen
                // for the fixture), drop the panel rather than stranding the user.
                if self.regrouping { self.cancelRegroup() }
            } catch is CancellationError {
                // Cancelled (Cancel button) — `cancelRegroup` already reset state.
            } catch {
                // Engine failed — abandon the regroup, stay on the current grouping.
                self.regrouping = false
                self.regroupTask = nil
            }
        }
    }

    /// Cache the freshly-regrouped result, switch the display to it, and dismiss the
    /// panel. The active grouping becomes `result.grouping`.
    private func finishRegroup(with result: ScoreResult) {
        resultsByGrouping[result.grouping] = result
        activeGrouping = result.grouping
        applyActiveGrouping()
        regrouping = false
        regroupTask = nil
    }

    /// Cancel an in-flight regroup (panel Cancel button). Aborts the engine task and
    /// stays on the current grouping; nothing is cached and favourites are untouched.
    func cancelRegroup() {
        regroupTask?.cancel()
        regroupTask = nil
        regrouping = false
        regroupDone = 0
        regroupTotal = 0
    }

    /// Whole-percent string for the 46px mono regroup readout, e.g. `42%`.
    var regroupPercentDisplay: String {
        guard regroupTotal > 0 else { return "0%" }
        let pct = Int((Double(regroupDone) / Double(regroupTotal) * 100).rounded())
        return "\(min(100, max(0, pct)))%"
    }

    /// Completion fraction in 0…1 for the regroup gold bar.
    var regroupFraction: Double {
        guard regroupTotal > 0 else { return 0 }
        return min(1, max(0, Double(regroupDone) / Double(regroupTotal)))
    }

    /// `{done} of {total}` grouped counts for the regroup sub-line.
    var regroupCountsDisplay: (done: String, total: String) {
        (Self.grouped(regroupDone), Self.grouped(regroupTotal))
    }

    /// Title copy for the regroup panel, e.g. `REGROUPING BY SIMILARITY — on-device`.
    var regroupTitle: String {
        let by = regroupTarget == .similarity ? "SIMILARITY" : "TIME"
        return "REGROUPING BY \(by) — on-device"
    }

    var titleSubtitle: String {
        switch screen {
        case .importSession:
            return "new session"
        case .scoring:
            return "scoring"
        case .review:
            return "\(bestCount) best · \(selectedCount) selected"
        case .export:
            return "export"
        case .settings:
            return "settings"
        }
    }

    var sourcePathDisplay: String {
        sourceURL?.path ?? "No source chosen"
    }

    var detectedStatsDisplay: String {
        guard sourceURL != nil else {
            return "Choose a folder to scan"
        }
        let count = detectedPhotoCount ?? 0
        let size = detectedSizeBytes ?? 0
        let types = detectedFileTypeCount ?? 0
        let countStr = Self.grouped(count)
        let sizeStr = Self.humanSize(size)
        return "\(countStr) photos · ~\(sizeStr) · \(types) file types"
    }

    var footerStatsDisplay: String {
        // The grouping label reflects the ACTIVE grouping (issue 8 acceptance), so
        // it flips with the toolbar toggle.
        let grouping = activeGrouping == .similarity ? "similarity" : "time"
        guard let count = detectedPhotoCount else {
            return "2,847 photos · \(grouping) grouping"
        }
        return "\(Self.grouped(count)) photos · \(grouping) grouping"
    }

    func newSessionButtonTapped() {
        screen = .importSession
    }

    /// Where Settings was opened from, so its Back button can return there.
    private var screenBeforeSettings: Screen = .importSession

    func settingsButtonTapped() {
        if screen != .settings { screenBeforeSettings = screen }
        screen = .settings
    }

    /// Back button on the Settings screen — return to wherever it was opened from.
    func closeSettingsButtonTapped() {
        screen = screenBeforeSettings
    }

    func chooseSourceButtonTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a source folder of photos to cull"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url)
    }

    /// Whether "Start culling" is allowed: a source folder is chosen AND it scanned
    /// to at least one photo. Drives the button's enabled state on Import — an empty
    /// or unchosen source leaves nothing to score.
    var canStartCulling: Bool {
        sourceURL != nil && (detectedPhotoCount ?? 0) > 0
    }

    func startCullingButtonTapped() {
        guard canStartCulling else { return }
        resetScoringState()
        screen = .scoring
        // The actual run is kicked off as an unstructured Task by ScoringView's
        // `.task` lifecycle, which calls `runScoring()`.
    }

    func backToImportButtonTapped() {
        screen = .importSession
    }

    /// Cancel button on the Scoring screen: stop the stream (the view's Task is
    /// cancelled when the screen changes) and return to Import.
    func cancelScoringButtonTapped() {
        resetScoringState()
        screen = .importSession
    }

    /// Drive the scoring stream to completion, updating state as events arrive.
    /// Created as an unstructured `Task` by the view (`.task`), so cancelling that
    /// task (screen change / Cancel) terminates the underlying bridge stream.
    /// On reaching 100% it auto-advances to Review.
    func runScoring() async {
        scoringStartedAt = ContinuousClock.now
        // Drive the Elapsed clock independently of progress events: the core is silent
        // for tens of seconds while its worker pool spawns and loads models (longer over
        // a network mount), and progress-event-only updates would freeze the clock — the
        // core of the "looks stuck" report. This ticker keeps it moving the whole pass and
        // is torn down when scoring ends.
        let ticker = Task { await tickElapsed() }
        defer { ticker.cancel() }
        // The scoring pass computes the README default grouping (similarity).
        let grouping = Grouping.similarity
        do {
            for try await event in CoreBridge.live.score(source: sourceURL, grouping: grouping) {
                switch event {
                case .progress(let p):
                    apply(p)
                case .completed(let result):
                    // Cache the result under its grouping and display it (issue 8).
                    // `activeGrouping` becomes the result's grouping; `scoreResult`
                    // is re-pointed via `applyActiveGrouping()` (also sets bestCount).
                    resultsByGrouping[result.grouping] = result
                    activeGrouping = result.grouping
                    applyActiveGrouping()
                    scoringProgress = 1
                    // Fresh result → enter Review in the transient loading state
                    // (issue 9). The grid's first appearance clears it via
                    // `previewsReady()` once thumbnails are warming up.
                    isBuildingPreviews = true
                    // HOOK (issue 5): when the score contract carries a
                    // "landmarker missing" signal, map it here, e.g.
                    //   faceModelUnavailable = result.faceModelUnavailable
                    // Until that field exists the flag stays at its default.
                    screen = .review
                }
            }
        } catch is CancellationError {
            // Stream was cancelled (Cancel / screen change) — nothing to do.
        } catch {
            // Fixture is bundled, so this is not expected at runtime. Fall back to
            // Import rather than stranding the user on a stalled bar.
            if screen == .scoring {
                resetScoringState()
                screen = .importSession
            }
        }
    }

    private func apply(_ p: ScoreProgress) {
        scoringDone = p.done
        scoringTotal = p.total
        scoringCurrentFrame = p.currentFrameName
        scoringCurrentBurstLabel = p.currentBurstLabel
        scoringPhase = p.phase
        scoringProgress = p.fraction
        if let started = scoringStartedAt {
            let elapsed = ContinuousClock.now - started
            scoringElapsed = elapsed.seconds
            if p.done > 0, p.fraction < 1 {
                let perFrame = scoringElapsed / Double(p.done)
                scoringRemaining = perFrame * Double(p.total - p.done)
            } else {
                scoringRemaining = 0
            }
        }
    }

    /// Advance `scoringElapsed` off the wall clock ~twice a second, independently of
    /// progress events, so the Elapsed card keeps ticking through the model-warmup
    /// window when the core emits nothing. Runs until cancelled (scoring ends) or the
    /// pass is reset. Reads the same `scoringStartedAt` `apply` does, so the two never
    /// disagree on the elapsed value.
    private func tickElapsed() async {
        while !Task.isCancelled {
            if let started = scoringStartedAt {
                scoringElapsed = (ContinuousClock.now - started).seconds
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func resetScoringState() {
        scoringProgress = 0
        scoringDone = 0
        scoringTotal = 0
        scoringCurrentFrame = ""
        scoringCurrentBurstLabel = ""
        scoringPhase = nil
        scoringElapsed = 0
        scoringRemaining = 0
        scoreResult = nil
        scoringStartedAt = nil
        // Grouping cache + regroup belong to one source/pass (issue 8); clear them
        // and return to the default grouping for the next session.
        cancelRegroup()
        resultsByGrouping = [:]
        activeGrouping = .similarity
        // Review state belongs to one result; clear it when a new pass starts.
        favourites = []
        selectedCount = 0
        bestCount = 0
        markFilter = .all
        isPreviewOpen = false
        previewBurstIndex = 0
        previewFrameIndex = 0
        previewZoom = false
        // Review-state flags (issue 9) belong to one pass; clear them too.
        isBuildingPreviews = false
        faceModelUnavailable = false
        // Export state (issue 10) belongs to one selection; reset the in-flight run
        // and result. The chosen destination is intentionally kept across sessions.
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
        exportProgress = nil
        exportReport = nil
    }

    /// Elapsed time formatted as `M:SS` for the Elapsed stat card.
    var scoringElapsedDisplay: String {
        Self.clockString(scoringElapsed)
    }

    /// Estimated remaining time formatted as `M:SS` for the Remaining stat card.
    var scoringRemainingDisplay: String {
        Self.clockString(scoringRemaining)
    }

    /// Whole-percent string (no `%`) for the 58px mono readout, e.g. `42`.
    var scoringPercentDisplay: String {
        "\(Int((scoringProgress * 100).rounded()))"
    }

    /// `{done} of {total}` counts, grouped, for the sub-line under the percentage.
    var scoringCountsDisplay: (done: String, total: String) {
        (Self.grouped(scoringDone), Self.grouped(scoringTotal))
    }

    /// Title for the now-processing card. During the model-warmup window (the
    /// `.loading` line, before any frame finishes) there is no frame to name, so show
    /// "Preparing…" rather than the "—" placeholder that read as a stall; otherwise the
    /// current frame's file name.
    var scoringActivityTitle: String {
        if scoringPhase == .loading { return "Preparing…" }
        return scoringCurrentFrame.isEmpty ? "—" : scoringCurrentFrame
    }

    /// Sub-line for the now-processing card: what the pass is doing. "loading detection
    /// models" through warmup, otherwise "analysing · {burst label}".
    var scoringActivitySubtitle: String {
        if scoringPhase == .loading { return "loading detection models" }
        return "analysing · \(scoringCurrentBurstLabel)"
    }

    func backToReviewButtonTapped() {
        screen = .review
    }

    func exportButtonTapped() {
        screen = .export
    }

    // MARK: Export derivation + actions (issue 10)

    /// The export SET: every frame across the active result whose id is a Favourite,
    /// in burst/best→worst order. Frame ids are shared across groupings, so this is
    /// exactly the human's picks regardless of which grouping is active. Empty when
    /// nothing is starred (drives the Export empty state).
    var exportFrames: [ScoreFrame] {
        guard let bursts = scoreResult?.bursts else { return [] }
        return bursts.flatMap { $0.frames }.filter { favourites.contains($0.id) }
    }

    /// `ExportItem` snapshots of the export set, ready to hand to `ExportService`.
    var exportItems: [ExportItem] {
        exportFrames.map(ExportItem.init(frame:))
    }

    /// Sum of the export set's original file sizes, in bytes — the "Approx. size"
    /// card. Reflects the live Favourite selection.
    var exportApproxBytes: Int64 {
        exportFrames.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Human-formatted approximate size for the summary card, e.g. `1.2 GB`.
    var exportApproxSizeDisplay: String {
        Self.humanSize(exportApproxBytes)
    }

    /// Grouped count string for the "Selected" card / button / list header.
    var exportCountDisplay: String {
        Self.grouped(favourites.count)
    }

    /// The destination path for the "Copy to" card, abbreviated with `~` for home.
    var exportDestinationDisplay: String {
        let path = exportDestination.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// "Choose…" on the destination card: an NSOpenPanel restricted to directories.
    /// The grant is process-wide for this (unsandboxed) app and stays valid for the
    /// session; if the app is ever sandboxed, the same panel grant carries the
    /// security scope, so no extra bookmarking is needed for the chosen folder.
    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportDestination
        panel.prompt = "Choose"
        panel.message = "Choose a folder to copy your favourites into"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportDestination = url
        // A new destination invalidates the previous run's report.
        exportReport = nil
    }

    /// Run the export: copy every Favourite's original into `exportDestination` and
    /// write the manifest. Created as an unstructured `Task` by ExportView, so it
    /// drives `ExportService` off the main actor and hops progress/result back here.
    /// No-op while a run is already in flight or when nothing is selected.
    func runExport() async {
        guard !isExporting, !exportItems.isEmpty else { return }
        isExporting = true
        exportReport = nil
        exportProgress = ExportProgress(done: 0, total: exportItems.count)

        let items = exportItems
        let source = sourceURL
        let destination = exportDestination

        // ExportService runs off the main actor (it is a plain `async` method on a
        // non-actor type touching only the file system + Sendable values). Source
        // originals are only READ; nothing is moved or deleted (ADR 0001/0002/0006).
        let report = await ExportService().run(
            items: items,
            source: source,
            destination: destination,
            progress: { p in
                // Hop back to the main actor to publish progress.
                Task { @MainActor [weak self] in self?.exportProgress = p }
            }
        )

        exportReport = report
        exportProgress = nil
        isExporting = false
    }

    /// Kick off `runExport()` as an unstructured task (ExportView's button action).
    func startExport() {
        exportTask?.cancel()
        exportTask = Task { [weak self] in await self?.runExport() }
    }

    func setSource(_ url: URL) {
        sourceURL = url
        scanSource(url)
    }

    private func scanSource(_ url: URL) {
        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
            "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2",
        ]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            detectedPhotoCount = 0
            detectedSizeBytes = 0
            detectedFileTypeCount = 0
            return
        }

        var count = 0
        var bytes: Int64 = 0
        var types = Set<String>()
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            count += 1
            types.insert(ext)
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                bytes += Int64(size)
            }
        }
        detectedPhotoCount = count
        detectedSizeBytes = bytes
        detectedFileTypeCount = types.count
    }

    private static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func humanSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 GB" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

extension Duration {
    /// This duration as fractional seconds (`TimeInterval`).
    var seconds: TimeInterval {
        let (s, attos) = components
        return Double(s) + Double(attos) / 1e18
    }
}
