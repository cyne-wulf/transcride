import SwiftUI

/// Retranscribe dialog (TRN-5): model picker (default = the user's default
/// model) plus the speaker-detection toggle (TRN-6). Confirming enqueues the
/// entry; the prior original is archived by the applier.
struct RetranscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var selectedModelID = ModelCatalog.preferredDefaultModelID()
    @State private var detectSpeakers = false
    /// 0 = auto-detect the speaker count.
    @State private var speakerCount = 0

    private var selectedIsDownloaded: Bool {
        model.modelManager.state(forModelInfoID: selectedModelID).isDownloaded
    }

    private var selectedSupportsDiarization: Bool {
        ModelCatalog.info(forID: selectedModelID)?.supportsDiarization == true
    }

    private var diarizerState: ModelManager.ModelState {
        model.modelManager.state(forModelInfoID: ModelCatalog.speakerDiarization.id)
    }

    /// Speaker detection needs its own model set on disk before enqueueing.
    private var speakerDetectionReady: Bool {
        !detectSpeakers || !selectedSupportsDiarization || diarizerState.isDownloaded
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

            speakerDetectionSection

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
                        modelID: selectedModelID,
                        detectSpeakers: detectSpeakers && selectedSupportsDiarization,
                        speakerCount: speakerCount == 0 ? nil : speakerCount
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selectedIsDownloaded || !speakerDetectionReady)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task { await model.modelManager.refresh() }
    }

    @ViewBuilder
    private var speakerDetectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Detect speakers", isOn: $detectSpeakers)
                .disabled(!selectedSupportsDiarization)
            if !selectedSupportsDiarization {
                Text("This model does not support speaker detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if detectSpeakers {
                Picker("Speakers", selection: $speakerCount) {
                    Text("Auto").tag(0)
                    ForEach(2...6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .fixedSize()
                Text("Sections get labeled Speaker 1, Speaker 2, … — rename them afterwards. Choosing the exact number of speakers improves accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch diarizerState {
                case .downloaded:
                    EmptyView()
                case .downloading(let fraction):
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(width: 120)
                        Text("Downloading speaker detection…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .preparing, .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing speaker detection…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                default:
                    HStack(spacing: 8) {
                        Text("Speaker detection needs a one-time \(ModelCatalog.speakerDiarization.downloadSizeDescription) download.")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Download") {
                            model.modelManager.download(ModelCatalog.speakerDiarization.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func pickerLabel(_ info: TranscriptionModelInfo) -> String {
        model.modelManager.state(forModelInfoID: info.id).isDownloaded
            ? info.displayName
            : info.displayName + " (not downloaded)"
    }
}
