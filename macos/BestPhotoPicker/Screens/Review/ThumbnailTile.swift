import SwiftUI

// MARK: - ThumbnailTile
//
// One Review-grid thumbnail (README screen 3 / .dc.html ~178-189):
//   • photo background (placeholder via `ThumbnailImage`, issue 4 swaps it),
//   • AI Best frame: subtle GREEN ring + top-left "★ BEST" green badge — never
//     gold/orange (gold is reserved for the human's Favourite),
//   • top-right gold star button toggling Favourite (stops propagation — does
//     NOT open the preview),
//   • bottom gradient-scrim overlay: mark dot + label (mark colour) · spacer ·
//     exposure ▲ if flagged · 2-digit mono sharpness.
// Click anywhere else on the tile opens the Preview (issue 7 renders it).
struct ThumbnailTile: View {
    let display: FrameDisplay
    let density: Density
    let onOpen: () -> Void
    let onToggleFavourite: () -> Void

    @State private var hovering = false

    private var width: CGFloat { density == .dense ? 132 : 196 }
    private var radius: CGFloat {
        density == .dense ? Metrics.Radius.thumbnailDense : Metrics.Radius.thumbnail
    }

    var body: some View {
        // Base tile = the photo, made clickable to open the preview.
        ThumbnailImage(frame: display.frame, contentMode: .fit)
            .frame(width: width, height: width * 2 / 3) // uniform 3/2 box; photo fits inside
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(alignment: .topLeading) { bestBadge }
            .overlay(alignment: .bottom) { bottomOverlay }
            .overlay(ringOrHairline)
            // Open on tile tap. The star (added on top) consumes its own taps so
            // this gesture does not also fire when the star is hit.
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onTapGesture { onOpen() }
            // Star on top, OUTSIDE the tap-to-open content shape so its Button
            // swallows the click (no propagation to the open gesture).
            .overlay(alignment: .topTrailing) { starButton }
            .offset(y: hovering ? -2 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }

    // MARK: AI Best — green badge (no gold)

    @ViewBuilder private var bestBadge: some View {
        if display.isKeeper {
            HStack(spacing: 4) {
                Image(systemName: Icon.star)
                    .font(.system(size: 8, weight: .bold))
                Text("BEST")
            }
            .font(Typography.ui(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Color(hex: "#072014"))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.badge)
                    .fill(Palette.markBest)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 3, y: 2)
            .padding(7)
        }
    }

    // MARK: Green ring (Best) or faint hairline (everything else)

    private var ringOrHairline: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(
                display.isKeeper ? Shadows.keeperRingColor : Shadows.thumbHairline,
                lineWidth: display.isKeeper ? 1.5 : 1
            )
    }

    // MARK: Favourite star (gold) — stops propagation

    private var starButton: some View {
        Button(action: onToggleFavourite) {
            Image(systemName: display.isFavourite ? Icon.star : Icon.star)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    display.isFavourite ? Palette.accentTextOnGold : Color(hex: "#cfcfd6")
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .fill(
                            display.isFavourite
                                ? Palette.accent.opacity(0.92)
                                : Color(hex: "#0c0c0e").opacity(0.55)
                        )
                )
                .shadow(
                    color: display.isFavourite ? Color.black.opacity(0.4) : .clear,
                    radius: 4, y: 2
                )
        }
        .buttonStyle(.plain)
        .help(display.isFavourite ? "Unfavourite" : "Favourite (select for export)")
        .padding(7)
    }

    // MARK: Bottom overlay — mark · exposure · sharpness

    private var bottomOverlay: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(display.markColor)
                    .frame(width: 7, height: 7)
                Text(display.markLabel)
                    .font(Typography.ui(10.5, weight: .semibold))
                    .foregroundStyle(display.markColor)
            }
            Spacer(minLength: 0)
            if display.hasExposureWarning {
                Image(systemName: Icon.exposureWarning)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.exposureWarning)
                    .help("Exposure warning")
            }
            Text(display.sharpnessString)
                .font(Typography.mono(11))
                .foregroundStyle(Palette.textTitle)
                .monospacedDigit()
                .help("Sharpness")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(hex: "#08080a").opacity(0.82), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }
}
