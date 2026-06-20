import SwiftUI

// The window uses `.hiddenTitleBar`, so this bar IS the draggable chrome region.
// New Session moved to `File ▸ New Session` (⌘N) and Settings to the native ⌘,
// window, so the bar now carries no controls — just the gradient + hairline and
// the reserved traffic-light gutter.
struct TitleBar: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.Chrome.titleBarHeight)
            .background(Palette.titleBarGradient)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.borderSubtleAlt2)
                    .frame(height: Metrics.Stroke.hairline)
            }
    }
}
