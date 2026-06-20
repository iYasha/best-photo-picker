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
        .commands {
            // New Session lives in the menu now (the title bar carries no controls).
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSessionButtonTapped() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Native Settings scene — opened by the standard ⌘, / app-menu item, so the
        // gear button is gone from the title bar. Dark scheme + fixed frame so the
        // dark column reads correctly in a standalone window (no `WindowChrome` here).
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 720, height: 640)
                .background(Palette.windowBody)
                .preferredColorScheme(.dark)
        }
    }
}
