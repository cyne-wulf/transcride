import SwiftUI

@main
struct TranscrideApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            AboutCommands()
            AppCommands(model: model)
            KeyboardShortcutsCommands()
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("About Transcride", id: AboutCommands.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Keyboard Shortcuts", id: KeyboardShortcutsCommands.windowID) {
            KeyboardShortcutsView()
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentSize)
    }
}
