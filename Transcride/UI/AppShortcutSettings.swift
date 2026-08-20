import SwiftUI

/// Settings → Keybinds → App Shortcuts: a complete remapper for every
/// Transcride-specific command. Each action offers a primary and an alternate
/// binding; bare keys are allowed (they defer to text editing at dispatch
/// time). Reserved native keys, duplicates, and chords owned by the global
/// controls are rejected with inline feedback, and persisted bindings that
/// became conflicting are shown disabled rather than silently dropped.
struct AppShortcutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var validationMessages: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                TextField("Search commands", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text("Escape, Return, Tab, plain ↑/↓, and unmodified Delete stay native and can't be reassigned. Shortcuts without ⌘, ⌥, or ⌃ never fire while you're typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AppShortcutCategory.allCases) { category in
                let actions = filteredActions(in: category)
                if !actions.isEmpty {
                    Section(category.title) {
                        ForEach(actions) { action in
                            shortcutRow(action)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset App Shortcuts") {
                    validationMessages.removeAll()
                    model.resetAppShortcutPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func filteredActions(in category: AppShortcutCategory) -> [AppShortcutAction] {
        let all = AppShortcutAction.allCases.filter { $0.category == category }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { action in
            action.title.localizedCaseInsensitiveContains(query)
                || model.appShortcutPreferences.binding(for: action).chords
                    .contains { $0.glyphDescription.localizedCaseInsensitiveContains(query) }
        }
    }

    private func shortcutRow(_ action: AppShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(action.title)
                    .lineLimit(1)
                Spacer()
                ForEach(AppShortcutSlot.allCases, id: \.self) { slot in
                    slotControl(action, slot: slot)
                }
            }
            ForEach(AppShortcutSlot.allCases, id: \.self) { slot in
                feedbackLabel(action, slot: slot)
            }
        }
        .padding(.vertical, 2)
    }

    private func slotControl(_ action: AppShortcutAction, slot: AppShortcutSlot) -> some View {
        HStack(spacing: 3) {
            ShortcutCaptureField(
                chord: model.appShortcutPreferences.chord(for: action, slot: slot),
                onCapture: { setChord($0, for: action, slot: slot) },
                onCaptureStateChange: { model.isShortcutCaptureActive = $0 }
            )
            .frame(width: 108, height: 26)
            .help("\(slot.title) shortcut for \(action.title)")

            Button {
                setChord(nil, for: action, slot: slot)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.appShortcutPreferences.chord(for: action, slot: slot) == nil)
            .help("Clear the \(slot.title.lowercased()) shortcut")
            .accessibilityLabel("Clear \(slot.title.lowercased()) shortcut for \(action.title)")
        }
    }

    @ViewBuilder
    private func feedbackLabel(_ action: AppShortcutAction, slot: AppShortcutSlot) -> some View {
        if let message = validationMessages[feedbackKey(action, slot)] {
            Label("\(slot.title): \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if case .disabled(let reason) = model.appShortcutPreferences.status(
            for: action, slot: slot, globalChords: model.configuredGlobalChords
        ) {
            Label("\(slot.title): \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func feedbackKey(_ action: AppShortcutAction, _ slot: AppShortcutSlot) -> String {
        "\(action.rawValue).\(slot.rawValue)"
    }

    private func setChord(
        _ chord: ShortcutChord?, for action: AppShortcutAction, slot: AppShortcutSlot
    ) {
        var preferences = model.appShortcutPreferences
        if let chord {
            let validation = preferences.validation(
                settingChord: chord,
                for: action,
                slot: slot,
                globalBindings: model.globalShortcutPreferences.bindings
            )
            guard validation == .valid else {
                validationMessages[feedbackKey(action, slot)] = validation.message
                return
            }
        }
        validationMessages[feedbackKey(action, slot)] = nil
        var binding = preferences.binding(for: action)
        binding[slot] = chord
        preferences.bindings[action] = binding
        model.updateAppShortcutPreferences(preferences)
    }
}
