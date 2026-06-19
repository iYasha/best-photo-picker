import SwiftUI

struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Metrics.Spacing.lg) {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: Icon.lock)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.nonDestructiveAccent)
                Text("Originals untouched")
                    .font(Typography.ui(11.5))
                    .foregroundStyle(Palette.textIconIdle)
            }

            Rectangle()
                .fill(Palette.hoverNeutral)
                .frame(width: 1, height: 14)

            Text(model.footerStatsDisplay)
                .font(Typography.mono(11.5))
                .foregroundStyle(Palette.textTertiary)

            Spacer()
        }
        .padding(.horizontal, Metrics.Chrome.footerPadding)
        .frame(height: Metrics.Chrome.footerHeight)
        .background(Palette.footerGradient)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.borderSubtleAlt2)
                .frame(height: Metrics.Stroke.hairline)
        }
    }
}
