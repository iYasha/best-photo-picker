import SwiftUI

// MARK: - PreviewStage (issue 7) — the large photo stage
//
// .dc.html `pvBig` (~213) + overlays (~214-217). flex:1 photo stage, radius 12,
// inner vignette (`inset 0 0 140px rgba(0,0,0,.35)`) + 1px white hairline.
//   • ‹ › nav arrows  — 40×56, rgba(12,12,14,.55) + blur, centred vertically.
//   • ★ AI BEST badge — bottom-left, only on the Keeper (green #54cf93 / #072014).
//   • zoom tag        — bottom-right "100% · checking sharpness" gold, only zoomed.
//
// Zoom (issue 7 note): the prototype swaps `background-size: cover → 240%`. Here we
// scale the `ThumbnailImage` to ~2.4× inside the clipped stage (`scaleEffect`),
// matching the prototype's centred 240% crop. Kept deliberately simple — no pan.
struct PreviewStage: View {
    let display: FrameDisplay
    let zoomed: Bool
    let onPrev: () -> Void
    let onNext: () -> Void

    private let radius: CGFloat = Metrics.Radius.cardLarge // 12
    private let zoomScale: CGFloat = 2.4 // prototype's 240% background-size

    var body: some View {
        ThumbnailImage(frame: display.frame)
            .scaleEffect(zoomed ? zoomScale : 1)
            .animation(.easeOut(duration: 0.18), value: zoomed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            // Inner vignette so the surround stays near-black and photo colour reads
            // true (README "Assets"); the prototype's inset box-shadow.
            .overlay(vignette)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
            .overlay(alignment: .leading) { navArrow(Icon.chevronLeft, action: onPrev).padding(.leading, 10) }
            .overlay(alignment: .trailing) { navArrow(Icon.chevronRight, action: onNext).padding(.trailing, 10) }
            .overlay(alignment: .bottomLeading) { bestBadge.padding(14) }
            .overlay(alignment: .bottomTrailing) { zoomTag.padding(14) }
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }

    // MARK: Inner vignette

    private var vignette: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.35)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 520
                )
            )
            .allowsHitTesting(false)
    }

    // MARK: ‹ › nav arrows (translucent, blur)

    private func navArrow(_ icon: String, action: @escaping () -> Void) -> some View {
        NavArrowButton(icon: icon, action: action)
    }

    // MARK: ★ AI BEST badge — Keeper only

    @ViewBuilder private var bestBadge: some View {
        if display.isKeeper {
            HStack(spacing: 4) {
                Image(systemName: Icon.star).font(.system(size: 9, weight: .bold))
                Text("AI BEST")
            }
            .font(Typography.ui(11, weight: .bold))
            .foregroundStyle(Color(hex: "#072014"))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .fill(Palette.markBest)
            )
        }
    }

    // MARK: Zoom tag — only while zoomed

    @ViewBuilder private var zoomTag: some View {
        if zoomed {
            Text("100% · checking sharpness")
                .font(Typography.mono(11, weight: .semibold))
                .foregroundStyle(Palette.accentTextOnGold)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .fill(Palette.accent)
                )
        }
    }
}

// MARK: - Nav arrow button (40×56, translucent + blur)

private struct NavArrowButton: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Palette.textPrimaryAlt)
                .frame(width: 40, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.button)
                        .fill(Color(hex: "#0c0c0e").opacity(hovering ? 0.8 : 0.55))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.button))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
