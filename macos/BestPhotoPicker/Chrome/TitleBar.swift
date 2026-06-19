import SwiftUI

struct TitleBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 70)   // reserve the macOS traffic-light area
            Spacer()
            HStack(spacing: 6) {
                IconButton(systemName: Icon.newSession, help: "New session") {
                    model.newSessionButtonTapped()
                }
                IconButton(systemName: Icon.settings, help: "Settings") {
                    model.settingsButtonTapped()
                }
            }
            // Locked while a regroup is processing — only the panel's Cancel acts.
            .disabled(model.regrouping)
            .opacity(model.regrouping ? 0.5 : 1)
        }
        .padding(.horizontal, Metrics.Chrome.titleBarPadding)
        .frame(height: Metrics.Chrome.titleBarHeight)
        .background(Palette.titleBarGradient)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.borderSubtleAlt2)
                .frame(height: Metrics.Stroke.hairline)
        }
    }
}
