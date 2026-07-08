import SwiftUI

struct SettingsView: View {
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
