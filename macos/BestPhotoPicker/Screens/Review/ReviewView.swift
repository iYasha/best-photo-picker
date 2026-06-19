import SwiftUI

// MARK: - ReviewView (issue 3) — the heart
//
// Renders the score result as the Review grid: a 52px toolbar (grouping segmented
// control + filter chips + Export button) over a scrolling grid of burst sections,
// each a header (label · time · n frames · faces) + a wrapping row of thumbnails.
//
// Reads `AppModel.scoreResult` (populated when scoring completes). Frames are
// filtered by `model.markFilter` and sorted best → worst (fixed) via
// `ScoreBurst.visibleFrames`. Bursts that become empty under a filter are hidden.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    private var result: ScoreResult? { model.scoreResult }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar (grouping / filter / export) stays visible in ALL states;
            // only the body below it swaps between the states and the grid.
            ReviewToolbar(counts: MarkCounts(result: result))
            gridBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Full-screen Preview (issue 7) sits over the whole Review content area
        // (toolbar + grid). Inserted only while open so its keyboard handling is
        // scoped to the preview. Issue 9 (which also edits ReviewView) should add
        // its content INSIDE the `VStack` above or as a separate modifier — this
        // `.overlay` is the last modifier and is dedicated to the preview.
        .overlay {
            if model.isPreviewOpen {
                PreviewOverlay()
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.isPreviewOpen)
    }

    // MARK: Grid body — state-aware (issue 9)
    //
    // The scroll + 22px-padding region that the design's three Review states share
    // with the normal grid (.dc.html: states live INSIDE the grid div). The state
    // content REPLACES the burst sections; the surrounding ScrollView/padding stay
    // so every state sits in the same well. This is wholly below the toolbar and
    // does NOT touch ReviewView's trailing preview `.overlay` (issue 7).
    //
    // Precedence: regrouping (issue 8) → no-faces → loading → empty → normal grid.
    private var gridBody: some View {
        ScrollView {
            Group {
                if model.regrouping {
                    RegroupPanel()
                } else if model.faceModelUnavailable {
                    ReviewNoFacesState()
                } else if model.isBuildingPreviews {
                    ReviewLoadingState()
                } else if model.hasNoFilterMatches {
                    ReviewEmptyState()
                } else {
                    gridSections
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 22, leading: 22, bottom: 40, trailing: 22))
        }
        // The transient loading state is set when a fresh `scoreResult` lands
        // (AppModel.runScoring → .completed). The grid's first appearance clears it
        // after a brief beat, so "Building previews…" reads as a real on-entry
        // transient rather than a UI toggle. A `.task` (cancelled if Review leaves)
        // owns the timing.
        .task {
            guard model.isBuildingPreviews else { return }
            try? await Task.sleep(for: .milliseconds(550))
            model.previewsReady()
        }
    }

    // MARK: Normal grid sections

    private var gridSections: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            if let result {
                let visible = visibleBursts(result)
                ForEach(visible, id: \.burst.id) { entry in
                    BurstSection(
                        burst: entry.burst,
                        burstIndex: entry.index,
                        frames: entry.frames
                    )
                }
            }
        }
    }

    // MARK: Visible bursts (filter applied; empty bursts dropped)

    private struct BurstEntry {
        let index: Int        // index into the result's bursts (for openPreview)
        let burst: ScoreBurst
        let frames: [ScoreFrame]
    }

    private func visibleBursts(_ result: ScoreResult) -> [BurstEntry] {
        result.bursts.enumerated().compactMap { index, burst in
            let frames = burst.visibleFrames(filter: model.markFilter)
            guard !frames.isEmpty else { return nil }
            return BurstEntry(index: index, burst: burst, frames: frames)
        }
    }
}

// MARK: - Burst section

private struct BurstSection: View {
    @Environment(AppModel.self) private var model
    let burst: ScoreBurst
    let burstIndex: Int
    let frames: [ScoreFrame]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            FlowLayout(spacing: 13) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { frameIndex, frame in
                    ThumbnailTile(
                        display: frame.display(isFavourite: model.isFavourite(frame.id)),
                        density: model.density,
                        onOpen: { model.openPreview(burstIndex: burstIndex, frameIndex: frameIndex) },
                        onToggleFavourite: { model.toggleFavourite(frame.id) }
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(burst.label)
                .font(Typography.ui(15, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(burst.time)
                .font(Typography.mono(11.5))
                .foregroundStyle(Palette.textTertiary)
            Text("·  \(burst.frames.count) frames")
                .font(Typography.ui(11.5))
                .foregroundStyle(Palette.textTertiary)
            if burst.faces {
                Text("·  faces")
                    .font(Typography.ui(11))
                    .foregroundStyle(Palette.textTertiary)
            }
            Rectangle()
                .fill(Palette.borderSubtle)
                .frame(height: 1)
        }
    }
}
