import SwiftUI

struct WindowChrome<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.contentBase)
        }
        .background(Palette.windowBody)
    }
}
