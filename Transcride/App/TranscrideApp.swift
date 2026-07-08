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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
