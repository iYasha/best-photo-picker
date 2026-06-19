import SwiftUI

// MARK: - Shared building blocks for the centered Review-state cards (issue 9)
//
// The no-faces (⚠) and empty (🔍) states share a centered, fade-up card layout
// with a 62px icon tile, a 19px/700 title, a 13.5px body, and one or two action
// buttons (.dc.html ~143-163). These small components capture that shared shape
// so each state file stays declarative.

// MARK: Centered card container
//
// A vertically-stacked, horizontally-centered card with a max width and a top
// margin, matching the design's `margin:60-70px auto 0; text-align:center` blocks
// with the `bpp-up` fade-up entrance.
struct ReviewStateCard<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) {
            content
        }
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 64)
        // bpp-up: shared fade-up entrance (DesignSystem/Animations).
        .screenEntrance()
    }
}

// MARK: Icon tile
//
// 62px rounded tile (radius 16) holding a centered glyph, tinted per state
// (red-tinted for no-faces, neutral panel for empty).
struct StateIconTile: View {
    let icon: String
    let iconSize: CGFloat
    let tint: Color
    let background: Color
    let border: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(background)
            .frame(width: 62, height: 62)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(border, lineWidth: 1)
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(tint)
            )
            .padding(.bottom, 10)
    }
}

// MARK: Neutral action button
//
// .dc.html: bg #1c1c20, border #2c2c33, radius 8, 13px/600 text, 9×18 padding.
// Reused by "Continue without faces" and "Reset view".
struct NeutralStateButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .fill(hovering ? Palette.hoverRaisedStronger : Palette.hoverRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .strokeBorder(Palette.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: Gold action button (compact)
//
// .dc.html: gold gradient, text-on-gold #231703, radius 8, 13px/700, 9×18 padding.
// A compact sibling of `PrimaryButton` sized for the no-faces card's "Retry model".
struct GoldStateButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(13, weight: .bold))
                .foregroundStyle(Palette.accentTextOnGold)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .fill(Palette.accentGradient)
                )
                // bpp hover: gold buttons brighten by 1.06 (shared modifier).
                .goldHover()
        }
        .buttonStyle(.plain)
    }
}
