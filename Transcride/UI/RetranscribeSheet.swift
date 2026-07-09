import SwiftUI

/// Retranscribe dialog (TRN-5): model picker (default = the user's default
/// model) plus the speaker-detection toggle, greyed out until M5. Confirming
/// enqueues the entry; the prior original is archived by the applier.
struct RetranscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var selectedModelID = ModelCatalog.preferredDefaultModelID()

    private var selectedIsDownloaded: Bool {
        model.modelManager.state(forModelInfoID: selectedModelID).isDownloaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Retranscribe “\(entry.displayTitle)”")
                .font(.headline)

            Picker("Model", selection: $selectedModelID) {
                ForEach(ModelCatalog.available) { info in
                    Text(pickerLabel(info)).tag(info.id)
                }
            }
            if !selectedIsDownloaded {
                Text("This model is not downloaded — download it in Settings → Transcription first.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Detect speakers", isOn: .constant(false))
                    .disabled(true)
                Text("Coming in a later milestone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The current original transcript is archived first. A hand-edited transcript is never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Retranscribe") {
                    model.transcriptionQueue?.enqueue(
                        entryRelativePath: entry.relativePath,
                        source: "retranscribe",
                        isRetranscribe: true,
                        modelID: selectedModelID
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selectedIsDownloaded)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task { await model.modelManager.refresh() }
    }

    private func pickerLabel(_ info: TranscriptionModelInfo) -> String {
        model.modelManager.state(forModelInfoID: info.id).isDownloaded
            ? info.displayName
            : info.displayName + " (not downloaded)"
    }
}
