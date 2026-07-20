import SwiftUI

/// Settings window: General, Recording, Keybinds, Transcription, and Storage.
/// Deleted retention), Recording, Transcription (models + vocabulary),
/// Storage (AUD-6).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsPane()
                .tabItem { Label("Recording", systemImage: "mic") }
            EditorSettingsPane()
                .tabItem { Label("Editor", systemImage: "textformat") }
            KeybindsSettingsPane()
                .tabItem { Label("Keybinds", systemImage: "keyboard") }
            TranscriptionSettingsPane()
                .tabItem { Label("Transcription", systemImage: "text.quote") }
            StorageSettingsPane()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 680)
        .frame(minHeight: 320, maxHeight: 640)
    }
}

private struct EditorSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Typography") {
                Stepper(
                    "Font size: \(model.editorPreferences.fontSize) pt",
                    value: fontSizeBinding,
                    in: EditorPreferences.minimumFontSize...EditorPreferences.maximumFontSize
                )
                Picker("Editor width", selection: widthBinding) {
                    ForEach(EditorWidthPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("Edited prose alignment", selection: alignmentBinding) {
                    ForEach(EditorAlignment.allCases) { alignment in
                        Text(alignment.title).tag(alignment)
                    }
                }
                Text("Original prose remains centered. Lists, tasks, quotes, code, and tables remain left-aligned in every mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Focus") {
                Toggle("Focus Mode", isOn: focusModeBinding)
                Text("While editing, dim Markdown blocks other than the block containing the caret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Editor Settings") {
                        model.resetEditorPreferences()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { model.editorPreferences.fontSize },
            set: { value in
                var preferences = model.editorPreferences
                preferences.fontSize = value
                model.updateEditorPreferences(preferences)
            }
        )
    }

    private var widthBinding: Binding<EditorWidthPreset> {
        Binding(
            get: { model.editorPreferences.width },
            set: { value in
                var preferences = model.editorPreferences
                preferences.width = value
                model.updateEditorPreferences(preferences)
            }
        )
    }

    private var alignmentBinding: Binding<EditorAlignment> {
        Binding(
            get: { model.editorPreferences.editedAlignment },
            set: { value in
                var preferences = model.editorPreferences
                preferences.editedAlignment = value
                model.updateEditorPreferences(preferences)
            }
        )
    }

    private var focusModeBinding: Binding<Bool> {
        Binding(
            get: { model.editorPreferences.focusMode },
            set: { value in
                var preferences = model.editorPreferences
                preferences.focusMode = value
                model.updateEditorPreferences(preferences)
            }
        )
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Vault") {
                LabeledContent("Location") {
                    Text(model.vaultURL?.path ?? "No vault selected")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Switch Vault…") {
                        model.chooseExistingVault()
                    }
                    Button("Create New Vault…") {
                        model.createNewVault()
                    }
                    if let url = model.vaultURL {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            Section("Library") {
                Toggle(
                    "Include entries from subfolders",
                    isOn: $model.includeEntriesFromSubfolders
                )
                Text("When you select a folder, its entry list also includes entries stored in folders below it. New recordings still save directly to the selected folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recently Deleted") {
                Picker("Keep deleted items for", selection: retentionBinding) {
                    ForEach(retentionChoices, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                Text("Deleted items are kept in the vault’s .trash folder; anything older than \(model.trashRetentionDays) days is purged when the vault opens. The setting is stored with the vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A hand-edited settings.json may hold a non-standard window; keep the
    /// picker honest by including it.
    private var retentionChoices: [Int] {
        let base = VaultSettingsStore.trashRetentionChoices
        guard !base.contains(model.trashRetentionDays) else { return base }
        return (base + [model.trashRetentionDays]).sorted()
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { model.trashRetentionDays },
            set: { days in Task { await model.setTrashRetentionDays(days) } }
        )
    }
}

private struct RecordingSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.PreferenceKey.recordingQuality) private var recordingQuality =
        RecordingQuality.compressed.rawValue
    @AppStorage(AppModel.PreferenceKey.preferredMicUID) private var preferredMicUID = ""

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Microphone", selection: $preferredMicUID) {
                    Text("System Default").tag("")
                    ForEach(model.inputDevices.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Quality", selection: $recordingQuality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text(quality.label).tag(quality.rawValue)
                    }
                }
                Text("Applies to new recordings. Compressed is small and fine for speech; lossless keeps the microphone signal bit-perfect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeybindsSettingsPane: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case appShortcuts
        case globalControls

        var id: String { rawValue }
        var title: String {
            switch self {
            case .appShortcuts: "App Shortcuts"
            case .globalControls: "Global Controls"
            }
        }
    }

    @State private var destination = Destination.appShortcuts

    var body: some View {
        VStack(spacing: 0) {
            Picker("Keybind Type", selection: $destination) {
                ForEach(Destination.allCases) { destination in
                    Text(destination.title).tag(destination)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            switch destination {
            case .appShortcuts:
                AppShortcutSettingsPane()
            case .globalControls:
                CombinedGlobalShortcutSettingsPane()
            }
        }
    }
}

private struct AppShortcutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var validationMessages: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search commands, categories, or keys", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))

                Text("App shortcuts work while Transcride is active. Click a field and press the physical key combination you want; use Clear to remove an assignment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AppShortcutCategory.allCases) { category in
                let actions = filteredActions(in: category)
                if !actions.isEmpty {
                    Section(category.title) {
                        ForEach(actions) { action in
                            appShortcutRow(action)
                        }
                    }
                }
            }

            if hasNoSearchResults {
                ContentUnavailableView.search(text: searchText)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset App Shortcuts") {
                        validationMessages.removeAll()
                        model.resetAppShortcutPreferences()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func filteredActions(
        in category: AppShortcutCategory
    ) -> [AppShortcutAction] {
        let actions = AppShortcutAction.allCases.filter { $0.category == category }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return actions }
        return actions.filter { action in
            let bindings = model.appShortcutPreferences
                .bindingSet(for: action)
                .orderedChords
                .map(\.glyphDescription)
                .joined(separator: " ")
            return [action.title, action.detail, category.title, bindings]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var hasNoSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AppShortcutCategory.allCases.allSatisfy {
                filteredActions(in: $0).isEmpty
            }
    }

    private func appShortcutRow(_ action: AppShortcutAction) -> some View {
        let messages = AppShortcutSlot.allCases.compactMap { slot in
            feedbackMessage(for: action, slot: slot).map {
                "\(slot.title): \($0)"
            }
        }

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(AppShortcutSlot.allCases) { slot in
                    appShortcutSlot(action, slot: slot)
                }
            }

            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    private func appShortcutSlot(
        _ action: AppShortcutAction,
        slot: AppShortcutSlot
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(slot.title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ShortcutCaptureField(
                    chord: model.appShortcutPreferences[action, slot],
                    accessibilityLabel: "Record \(slot.title.lowercased()) shortcut for \(action.title)",
                    onCaptureStateChange: model.setShortcutCaptureOwnsInput,
                    onCapture: { chord in
                        setAppChord(chord, for: action, slot: slot)
                    }
                )
                .frame(width: 112, height: 28)

                Button {
                    clearAppChord(for: action, slot: slot)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(model.appShortcutPreferences[action, slot] == nil)
                .help("Clear \(slot.title.lowercased()) shortcut")
                .accessibilityLabel("Clear \(slot.title.lowercased()) shortcut for \(action.title)")
            }
        }
        .frame(width: 140, alignment: .leading)
    }

    private func feedbackMessage(
        for action: AppShortcutAction,
        slot: AppShortcutSlot
    ) -> String? {
        if let message = validationMessages[validationKey(action, slot)] {
            return message
        }
        let status = model.appShortcutPreferences.validationStatus(
            for: action,
            slot: slot,
            globalBindings: model.assignedGlobalShortcutBindings
        )
        switch status {
        case .available, .unassigned:
            return nil
        default:
            return status.message
        }
    }

    private func setAppChord(
        _ chord: ShortcutChord,
        for action: AppShortcutAction,
        slot: AppShortcutSlot
    ) {
        let status = model.appShortcutPreferences.validationStatus(
            for: action,
            slot: slot,
            candidate: chord,
            globalBindings: model.assignedGlobalShortcutBindings
        )
        guard status == .available else {
            validationMessages[validationKey(action, slot)] = status.message
            return
        }

        validationMessages[validationKey(action, slot)] = nil
        var preferences = model.appShortcutPreferences
        preferences[action, slot] = chord
        model.updateAppShortcutPreferences(preferences)
    }

    private func clearAppChord(
        for action: AppShortcutAction,
        slot: AppShortcutSlot
    ) {
        validationMessages[validationKey(action, slot)] = nil
        var preferences = model.appShortcutPreferences
        preferences[action, slot] = nil
        model.updateAppShortcutPreferences(preferences)
    }

    private func validationKey(
        _ action: AppShortcutAction,
        _ slot: AppShortcutSlot
    ) -> String {
        "\(action.rawValue)|\(slot.rawValue)"
    }
}

private struct CombinedGlobalShortcutSettingsPane: View {
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

            Section("Assignments") {
                ForEach(GlobalShortcutAction.allCases) { action in
                    globalShortcutRow(action)
                }
            }
            .disabled(!model.globalShortcutPreferences.isEnabled)

            Section("Background Access") {
                Toggle("Show Transcride in menu bar", isOn: menuBarItemBinding)
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
                    NotificationCenter.default.post(
                        name: .resetGlobalIndicatorPosition,
                        object: nil
                    )
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Global Shortcuts") {
                        validationMessages.removeAll()
                        model.resetGlobalShortcutPreferences()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func globalShortcutRow(_ action: GlobalShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(action.title)
                Spacer()
                ShortcutCaptureField(
                    chord: model.globalShortcutPreferences.bindings[action] ?? nil,
                    accessibilityLabel: "Record global shortcut for \(action.title)",
                    onCaptureStateChange: model.setShortcutCaptureOwnsInput,
                    onCapture: { chord in setGlobalChord(chord, for: action) }
                )
                .frame(width: 160, height: 28)
                Button("Clear") { clearGlobalChord(for: action) }
                    .disabled(
                        (model.globalShortcutPreferences.bindings[action] ?? nil) == nil
                    )
            }

            if let validation = validationMessages[action] {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                globalRegistrationLabel(for: action)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func globalRegistrationLabel(for action: GlobalShortcutAction) -> some View {
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

    private func setGlobalChord(
        _ chord: ShortcutChord,
        for action: GlobalShortcutAction
    ) {
        var preferences = model.globalShortcutPreferences
        let validation = preferences.validation(for: action, chord: chord)
        guard validation == .valid else {
            validationMessages[action] = validation.message
            return
        }

        if let localAction = AppShortcutAction.allCases.first(where: {
            model.appShortcutPreferences.bindingSet(for: $0).orderedChords.contains(chord)
        }) {
            validationMessages[action] = "Already assigned in the app to \(localAction.title)."
            return
        }

        validationMessages[action] = nil
        preferences.bindings[action] = chord
        model.updateGlobalShortcutPreferences(preferences)
    }

    private func clearGlobalChord(for action: GlobalShortcutAction) {
        validationMessages[action] = nil
        var preferences = model.globalShortcutPreferences
        preferences.bindings[action] = nil
        model.updateGlobalShortcutPreferences(preferences)
    }
}

private struct TranscriptionSettingsPane: View {
    var body: some View {
        Form {
            TranscriptionModelsSection()
            VocabularySection()
        }
        .formStyle(.grouped)
    }
}
