import SwiftUI

struct ExtensionRecoveryView: View {
    @Environment(AppModel.self) private var model
    @State private var discardCandidate: RecoverableRecordingExtension?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Recover Interrupted Extensions", systemImage: "waveform.badge.exclamationmark")
                .font(.title2.weight(.semibold))

            Text("The existing recordings are unchanged. Choose what to do with each recovered extension segment.")
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.extensionRecoveries) { recovery in
                        recoveryCard(recovery)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    model.isExtensionRecoveryPresented = false
                }
                .disabled(!model.extensionRecoveries.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 430)
        .interactiveDismissDisabled(!model.extensionRecoveries.isEmpty)
        .confirmationDialog(
            "Discard this recovered extension segment?",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Segment", role: .destructive) {
                if let recovery = discardCandidate {
                    Task { await model.discardRecoveredExtension(recovery) }
                }
                discardCandidate = nil
            }
            Button("Cancel", role: .cancel) { discardCandidate = nil }
        } message: {
            Text("The selected entry's existing audio is not changed. Only the interrupted extension artifacts are removed.")
        }
    }

    private func recoveryCard(_ recovery: RecoverableRecordingExtension) -> some View {
        let processing = model.extensionRecoveryProcessingIDs.contains(recovery.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle(for: recovery))
                        .font(.headline)
                    Text(recovery.phaseDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if processing { ProgressView().controlSize(.small) }
            }

            HStack {
                Button("Finish Extending") {
                    Task { await model.finishRecoveredExtension(recovery) }
                }
                .buttonStyle(.borderedProminent)

                Button("Save Segment as New Entry") {
                    Task { await model.saveRecoveredExtensionAsNewEntry(recovery) }
                }

                Spacer()

                Button("Discard Segment", role: .destructive) {
                    discardCandidate = recovery
                }
            }
            .disabled(processing)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func displayTitle(for recovery: RecoverableRecordingExtension) -> String {
        model.snapshot?.entry(withID: recovery.entryRelativePath)?.displayTitle
            ?? recovery.entryRelativePath.lastComponent
    }
}
