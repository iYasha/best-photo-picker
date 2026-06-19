import SwiftUI

// MARK: - PreviewFilmstrip (issue 7) — bottom filmstrip
//
// .dc.html ~219-226 + `pvFilm` cell styling (~655). A horizontal scroll of the
// burst's DISPLAYED frames (same ordering as the grid). 90px cells, aspect 3/2:
//   • active cell   — 2px gold ring, full opacity
//   • Keeper        — 1.5px green ring (when not active)
//   • Favourite     — gold ★ chip, top-right
//   • mark dot      — bottom-left, mark colour
// Tapping a cell jumps the preview to it. Inactive cells sit at 0.8 opacity.
struct PreviewFilmstrip: View {
    @Environment(AppModel.self) private var model
    let frames: [ScoreFrame]
    let activeIndex: Int
    let keeperId: String?
    let onSelect: (Int) -> Void

    private let cellWidth: CGFloat = 90

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                    cell(frame: frame, index: index)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(height: cellWidth * 2 / 3 + 4) // cell height (aspect 3/2) + scroll pad
    }

    private func cell(frame: ScoreFrame, index: Int) -> some View {
        let isActive = index == activeIndex
        let isKeeper = frame.id == keeperId
        let isFavourite = model.isFavourite(frame.id)
        let radius = Metrics.Radius.badge // 6

        return ThumbnailImage(frame: frame)
            .frame(width: cellWidth, height: cellWidth * 2 / 3)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(alignment: .topTrailing) {
                if isFavourite {
                    Image(systemName: Icon.star)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.accentTextOnGold)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.accent.opacity(0.92))
                        )
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(frame.mark.color)
                    .frame(width: 7, height: 7)
                    .padding(4)
            }
            .overlay(ring(isActive: isActive, isKeeper: isKeeper, radius: radius))
            .opacity(isActive ? 1 : 0.8)
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onTapGesture { onSelect(index) }
    }

    // Active = 2px gold ring; else Keeper = 1.5px green ring; else faint hairline.
    private func ring(isActive: Bool, isKeeper: Bool, radius: CGFloat) -> some View {
        let color: Color
        let width: CGFloat
        if isActive {
            color = Palette.accent; width = 2
        } else if isKeeper {
            color = Palette.markBest.opacity(0.6); width = 1.5
        } else {
            color = Color.white.opacity(0.06); width = 1
        }
        return RoundedRectangle(cornerRadius: radius)
            .strokeBorder(color, lineWidth: width)
    }
}
