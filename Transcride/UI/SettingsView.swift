import AVFoundation
import AppKit
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
            KeybindsSettingsPane()
                .tabItem { Label("Keybinds", systemImage: "keyboard") }
            TranscriptionSettingsPane()
                .tabItem { Label("Transcription", systemImage: "text.quote") }
            StorageSettingsPane()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 540)
        .frame(minHeight: 320, maxHeight: 640)
    }
}

/// Keybinds: the in-app remapper (every Transcride command) and the global
/// system-wide recording controls, as two subviews of one pane.
private struct KeybindsSettingsPane: View {
    private enum Subpane: String, CaseIterable, Identifiable {
        case appShortcuts = "App Shortcuts"
        case globalControls = "Global Controls"

        var id: String { rawValue }
    }

    @State private var subpane: Subpane = .appShortcuts

    var body: some View {
        VStack(spacing: 0) {
            Picker("Keybind scope", selection: $subpane) {
                ForEach(Subpane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)

            switch subpane {
            case .appShortcuts:
                AppShortcutSettingsPane()
            case .globalControls:
                GlobalShortcutSettingsPane()
            }
        }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
            PermissionsSection()
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
                Text("Every new recording starts with the selected microphone. When macOS permits it and meaningful sound is present, Transcride also adds audio playing on this Mac. Permission or Mac-audio failures never interrupt the microphone recording; notifications and other Mac sounds may be included. Extensions and replacement takes remain microphone-only. Compressed is small and well suited to speech; lossless avoids lossy encoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Explicit state for the two capture permissions Transcride uses: Microphone
/// (required for every recording) and Screen & System Audio Recording (adds
/// Mac audio to recordings). Statuses are re-read on a short loop so changes
/// made in System Settings show up while the pane is open.
private struct PermissionsSection: View {
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var systemAudioGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        Section("Permissions") {
            LabeledContent {
                HStack(spacing: 12) {
                    switch micStatus {
                    case .notDetermined:
                        Button("Request Access…") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                refresh()
                            }
                        }
                    case .denied, .restricted:
                        openSystemSettingsButton(pane: "Privacy_Microphone")
                    default:
                        EmptyView()
                    }
                    statusBadge(micStatusText, kind: micStatusKind)
                }
            } label: {
                Text("Microphone")
                Text("Required for every recording.")
            }

            LabeledContent {
                HStack(spacing: 12) {
                    if !systemAudioGranted {
                        openSystemSettingsButton(pane: "Privacy_ScreenCapture")
                    }
                    statusBadge(
                        systemAudioGranted ? "Granted" : "Not granted",
                        kind: systemAudioGranted ? .granted : .pending
                    )
                }
            } label: {
                Text("System Audio Recording")
                Text("Adds audio playing on this Mac to recordings. Listed as “Screen & System Audio Recording” in System Settings; without it, recordings are microphone-only.")
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        systemAudioGranted = CGPreflightScreenCaptureAccess()
    }

    private var micStatusText: String {
        switch micStatus {
        case .authorized: "Granted"
        case .notDetermined: "Not requested yet"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    private enum StatusKind {
        case granted, pending, blocked
    }

    private var micStatusKind: StatusKind {
        switch micStatus {
        case .authorized: .granted
        case .notDetermined: .pending
        default: .blocked
        }
    }

    private func statusBadge(_ text: String, kind: StatusKind) -> some View {
        Label {
            Text(text)
        } icon: {
            switch kind {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .pending:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .blocked:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .foregroundStyle(kind == .granted ? .primary : .secondary)
    }

    private func openSystemSettingsButton(pane: String) -> some View {
        Button("Open System Settings…") {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}

private struct TranscriptionSettingsPane: View {
    var body: some View {
        Form {
            TranscriptionModelsSection()
            AISummaryModelsSection()
            VocabularySection()
        }
        .formStyle(.grouped)
    }
}
