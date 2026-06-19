import SwiftUI

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Palette.textTitle : Palette.textIconIdle)
                .frame(
                    width: Metrics.Chrome.iconButtonWidth,
                    height: Metrics.Chrome.iconButtonHeight
                )
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.badge)
                        .fill(hovering ? Palette.windowBorder : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Match the app's other neutral controls' hover timing (0.12s).
        .animation(Anim.hover, value: hovering)
        .help(help)
    }
}
