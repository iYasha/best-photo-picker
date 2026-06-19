import SwiftUI

@main
struct BestPhotoPickerApp: App {
    @State private var model = AppModel()

    init() {
        FontRegistration.registerBundledFonts()
    }

    private var defaultSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(Metrics.Window.maxWidth, screen.width * Metrics.Window.widthFraction)
        let height = min(Metrics.Window.maxHeight, screen.height * Metrics.Window.heightFraction)
        return CGSize(width: width, height: height)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        // .contentMinSize (not .contentSize): the window opens at `defaultSize` but stays
        // user-resizable and supports zoom / full-screen, bounded below by RootView's
        // minWidth/minHeight. `.contentSize` had pinned it to a fixed size.
        .windowResizability(.contentMinSize)
        .defaultSize(width: defaultSize.width, height: defaultSize.height)
    }
}
