import SwiftUI

struct SettingsView: View {
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
                LabeledContent("Retention", value: "\(TrashStore.retentionDays) days")
                Text("Deleted items are kept in the vault’s .trash folder and purged automatically on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
