import SwiftUI

// MARK: - HistogramCard — RGB + Luma tone charts (Preview info panel)
//
// Two stacked charts in one card: an RGB overlay (red/green/blue curves blended
// with `.plusLighter`, so overlaps read white like a camera/editor histogram)
// over a separate luminance chart (a single grey fill of overall brightness).
// Both share the panel width; shadows sit at the left edge, highlights at the
// right. Fed the memoised `Histogram` from `ImageCache`; while it loads (`nil`)
// the chart wells render empty so there's no layout pop between frames.
struct HistogramCard: View {
    let histogram: Histogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            chart(
                title: "RGB",
                height: 92,
                channels: rgbChannels,
                peak: histogram?.rgbPeak ?? 1,
                blend: .plusLighter
            )
            chart(
                title: "Luma",
                height: 60,
                channels: lumaChannels,
                peak: histogram?.lumaPeak ?? 1,
                blend: .normal
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1)
                .fill(Palette.panelDeepAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1)
                .strokeBorder(Palette.borderSubtle, lineWidth: 1)
        )
    }

    private var rgbChannels: [HistogramChart.Channel] {
        [
            .init(values: histogram?.red ?? [], color: Color(hex: "#ff5b5b")),
            .init(values: histogram?.green ?? [], color: Color(hex: "#54cf72")),
            .init(values: histogram?.blue ?? [], color: Color(hex: "#5b8bff")),
        ]
    }

    private var lumaChannels: [HistogramChart.Channel] {
        [.init(values: histogram?.luma ?? [], color: Palette.textSecondary)]
    }

    private func chart(
        title: String,
        height: CGFloat,
        channels: [HistogramChart.Channel],
        peak: Int,
        blend: GraphicsContext.BlendMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Typography.ui(10))
                .tracking(0.6)
                .foregroundStyle(Palette.textTertiary)
            HistogramChart(channels: channels, peak: peak, blend: blend)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.badge)
                        .fill(Color.black.opacity(0.25))
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.badge))
        }
    }
}

// MARK: - HistogramChart — one Canvas of filled tonal curves

private struct HistogramChart: View {
    struct Channel: Equatable {
        let values: [Int]
        let color: Color
    }

    let channels: [Channel]
    let peak: Int
    let blend: GraphicsContext.BlendMode

    var body: some View {
        Canvas { context, size in
            context.blendMode = blend
            for channel in channels {
                let path = curve(channel.values, in: size)
                // Filled body (translucent) + a crisp top edge.
                context.fill(path, with: .color(channel.color.opacity(0.5)))
                context.stroke(path, with: .color(channel.color.opacity(0.9)), lineWidth: 1)
            }
        }
        .drawingGroup() // flatten the blended layers once, off the main pass
    }

    /// A closed area path: across the bins along the top, then down to the
    /// baseline and back, so `fill` paints the body under the curve.
    private func curve(_ values: [Int], in size: CGSize) -> Path {
        var path = Path()
        let n = values.count
        guard n > 1, peak > 0 else { return path }
        let stepX = size.width / CGFloat(n - 1)
        path.move(to: CGPoint(x: 0, y: size.height))
        for i in 0..<n {
            let x = CGFloat(i) * stepX
            let frac = min(1, CGFloat(values[i]) / CGFloat(peak))
            path.addLine(to: CGPoint(x: x, y: size.height - frac * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}
