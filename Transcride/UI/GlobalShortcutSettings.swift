import AppKit
import SwiftUI

struct GlobalShortcutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var validationMessages: [GlobalShortcutAction: String] = [:]

    var body: some View {
        Form {
            Section("Global Controls") {
                Toggle("Enable Global Controls", isOn: enabledBinding)
                Text("Global controls work while Transcride is running, even when its window is closed. They stop when you quit Transcride.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keybinds") {
                ForEach(GlobalShortcutAction.allCases) { action in
                    shortcutRow(action)
                }
            }
            .disabled(!model.globalShortcutPreferences.isEnabled)

            Section("Background Access") {
                Toggle(
                    "Show Transcride in menu bar",
                    isOn: menuBarItemBinding
                )
                Toggle(
                    "Show indicator while Transcride is in the background",
                    isOn: indicatorBinding
                )
                Picker("Keep visible after recording", selection: retentionBinding) {
                    ForEach(BackgroundIndicatorRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .disabled(!model.globalShortcutPreferences.showsBackgroundIndicator)
                Text("The indicator stays available for follow-up recordings, or until you hide it from its hover control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Indicator Position") {
                    NotificationCenter.default.post(name: .resetGlobalIndicatorPosition, object: nil)
                }
            }

            HStack {
                Spacer()
                Button("Reset Global Shortcuts") {
                    validationMessages.removeAll()
                    model.resetGlobalShortcutPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(action.title)
                Spacer()
                ShortcutCaptureField(
                    chord: model.globalShortcutPreferences.bindings[action] ?? nil,
                    onCapture: { setChord($0, for: action) },
                    onCaptureStateChange: { model.isShortcutCaptureActive = $0 }
                )
                .frame(width: 150, height: 28)
                Button("Clear") { setChord(nil, for: action) }
                    .disabled((model.globalShortcutPreferences.bindings[action] ?? nil) == nil)
            }
            if let validation = validationMessages[action] {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                registrationLabel(for: action)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func registrationLabel(for action: GlobalShortcutAction) -> some View {
        switch model.globalShortcutService.statuses[action] ?? .disabled {
        case .registered:
            Label("Registered", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .cleared:
            Text("No global shortcut assigned")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .disabled:
            Text("Global controls are disabled")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.isEnabled },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.isEnabled = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var indicatorBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.showsBackgroundIndicator },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.showsBackgroundIndicator = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var menuBarItemBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.showsMenuBarItem },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.showsMenuBarItem = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var retentionBinding: Binding<BackgroundIndicatorRetention> {
        Binding(
            get: { model.globalShortcutPreferences.backgroundIndicatorRetention },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.backgroundIndicatorRetention = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private func setChord(_ chord: GlobalShortcutChord?, for action: GlobalShortcutAction) {
        var preferences = model.globalShortcutPreferences
        if let chord {
            let validation = preferences.validation(for: action, chord: chord)
            guard validation == .valid else {
                validationMessages[action] = validation.message
                return
            }
        }
        validationMessages[action] = nil
        preferences.bindings[action] = chord
        model.updateGlobalShortcutPreferences(preferences)
    }
}

extension Notification.Name {
    static let resetGlobalIndicatorPosition = Notification.Name("resetGlobalIndicatorPosition")
}
