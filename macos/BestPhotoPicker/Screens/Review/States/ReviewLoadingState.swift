import SwiftUI

// MARK: - Review loading state (issue 9)
//
// .dc.html ~133-140 ("loading" block). A spinner + "Building previews…" caption
// over a wrapping row of shimmering skeleton tiles. Shown as a real transient
// while a fresh `scoreResult` warms up (driven by `AppModel.isBuildingPreviews`,
// set on `.completed` and cleared by the grid's first appearance).
//
// Sits INSIDE the grid region (replaces the burst sections) — it never touches
// ReviewView's trailing preview `.overlay` (issue 7).
struct ReviewLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Spinner + caption (.dc.html: 14px ring, 2px border, gold top, 13px text)
            HStack(spacing: 10) {
                SpinnerRing()
                Text("Building previews…")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.textIconIdle)
            }

            // Row of shimmering skeleton tiles (196×aspect 3/2, radius 9).
            FlowLayout(spacing: 12) {
                ForEach(0..<10, id: \.self) { _ in
                    SkeletonTile()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Spinner ring
//
// 14px ring, 2px stroke on a dark track with a gold leading arc, spinning at
// .8s/turn (.dc.html `bpp-spin`).
private struct SpinnerRing: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                AngularGradient(
                    colors: [Palette.accent, Palette.borderStrong],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Skeleton tile
//
// A comfortable-sized thumbnail placeholder (196px, aspect 3/2, radius 9) with a
// moving light band — the `bpp-shimmer` gradient sweep from the design.
private struct SkeletonTile: View {
    private let width: CGFloat = 196
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Radius.thumbnail)
            .fill(Palette.titleBarBottom) // base #161618
            .frame(width: width, height: width * 2 / 3)
            .overlay {
                GeometryReader { geo in
                    let bandWidth = geo.size.width * 0.6
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(hex: "#202024").opacity(0.9),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: phase * (geo.size.width + bandWidth))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.thumbnail))
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
