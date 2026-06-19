import SwiftUI

struct StubScreen: View {
    let title: String
    var subtitle: String = "TODO — built in a later slice."

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Typography.ui(23, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle)
                .font(Typography.ui(13.5))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.Spacing.screenPadding)
    }
}
