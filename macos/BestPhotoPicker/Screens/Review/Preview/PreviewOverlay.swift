import SwiftUI

// MARK: - PreviewOverlay (issue 7) — full-screen Preview over Review
//
// README "3b. Full-screen Preview" / .dc.html PREVIEW block (~199-245). An absolute
// overlay filling the Review content area for inspecting one frame large:
//   • top bar  — ‹ Back to grid + burst label + mono "frame i / n"
//   • middle   — large photo STAGE (flex:1, radius 12, inner vignette) with ‹ › nav
//                arrows, a "★ AI BEST" badge on the Keeper, a "100% · checking
//                sharpness" tag when zoomed; a 264px right INFO PANEL (mark, WHY,
//                SCORES sharpness bar + Eyes/Faces chips + exposure row, Select for
//                export + zoom toggle, keyboard hints); a bottom FILMSTRIP.
//   • keyboard — ←/→ frames, F select, Z zoom, Esc close (only while open).
//
// Frame resolution is via `AppModel.previewFrame` / `previewVisibleFrames`, which
// index the burst's DISPLAYED frames (`visibleFrames(filter:)`), so the preview
// matches the grid the user clicked from (issue 3). All state lives on AppModel;
// this view is a pure projection over it.
struct PreviewOverlay: View {
    @Environment(AppModel.self) private var model

    /// Focus for the overlay's key handling — taken when shown so ←/→/F/Z/Esc work.
    @FocusState private var focused: Bool

    var body: some View {
        // Resolve once; guard so an out-of-range index never crashes — fall back to
        // closing rather than rendering an empty shell.
        let frames = model.previewVisibleFrames
        let frame = model.previewFrame

        ZStack {
            Color(hex: "#08080a")

            if let frame, let burst = model.previewBurst {
                VStack(spacing: 12) {
                    topBar(burst: burst, count: frames.count)
                    middleRow(frame: frame, frames: frames)
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        // Take focus so `.onKeyPress` fires while the preview is open.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress { press in handleKey(press) }
    }

    // MARK: Keyboard (macOS 14+)
    //
    // ←/→ move frames, F toggle Favourite, Z toggle 100% zoom, Esc close. Active
    // only while the overlay is on screen (it is only inserted when open).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            model.previewPrev(); return .handled
        case .rightArrow:
            model.previewNext(); return .handled
        case .upArrow:
            model.previewPrevBurst(); return .handled
        case .downArrow:
            model.previewNextBurst(); return .handled
        case .escape:
            model.closePreview(); return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "f":
            model.previewToggleFavourite(); return .handled
        case "z":
            model.previewToggleZoom(); return .handled
        default:
            return .ignored
        }
    }

    // MARK: Top bar — Back · burst label · mono frame i / n

    private func topBar(burst: ScoreBurst, count: Int) -> some View {
        HStack(spacing: 14) {
            BackToGridButton { model.closePreview() }
            VStack(alignment: .leading, spacing: 1) {
                Text(burst.label)
                    .font(Typography.ui(14.5, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("frame \(model.previewFrameIndex + 1) / \(count)")
                    .font(Typography.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Middle row — stage (+ filmstrip) | info panel

    private func middleRow(frame: ScoreFrame, frames: [ScoreFrame]) -> some View {
        let display = frame.display(isFavourite: model.isFavourite(frame.id))
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                PreviewStage(
                    display: display,
                    zoomed: model.previewZoom,
                    onPrev: { model.previewPrev() },
                    onNext: { model.previewNext() }
                )
                PreviewFilmstrip(
                    frames: frames,
                    activeIndex: model.previewFrameIndex,
                    keeperId: model.previewBurst?.keeperId,
                    onSelect: { model.previewSelect(frameIndex: $0) }
                )
            }
            .frame(maxWidth: .infinity)

            PreviewInfoPanel(
                display: display,
                isFavourite: model.previewIsFavourite,
                zoomed: model.previewZoom,
                onToggleFavourite: { model.previewToggleFavourite() },
                onToggleZoom: { model.previewToggleZoom() }
            )
        }
    }
}

// MARK: - Back to grid button (.dc.html ~203)
//
// 34px tall, #161618 bg, #232328 border, radius 8, ‹ glyph + "Back to grid"; hover
// steps to #222227 / #ededf0.
private struct BackToGridButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: Icon.chevronLeft)
                    .font(.system(size: 12, weight: .semibold))
                Text("Back to grid")
                    .font(Typography.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? Palette.textPrimary : Color(hex: "#bcbcc4"))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .fill(hovering ? Palette.hoverRaisedStrong : Palette.titleBarBottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Back to grid (Esc)")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .fixedSize()
    }
}
