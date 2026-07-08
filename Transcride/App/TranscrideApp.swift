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
                Button(model.recorder.isActive ? "Stop Recording" : "Start Recording") {
                    Task {
                        if model.recorder.isActive {
                            await model.stopRecording()
                        } else {
                            await model.startRecording()
                        }
                    }
                }
                .keyboardShortcut(.space, modifiers: [.shift])
                .disabled(model.phase != .ready || model.recorder.state == .finalizing)

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
