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
            CommandGroup(after: .newItem) {
                Button("Import Audio…") {
                    model.importViaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.phase != .ready)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
