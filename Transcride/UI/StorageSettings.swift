import SwiftUI

/// Settings → Storage (AUD-6): where the vault's bytes live, and the ranked
/// list of largest-audio entries with the Delete Audio… flow inline.
struct StorageSettingsPane: View {
    @Environment(AppModel.self) private var model

    // Payload separate from isPresented — SwiftUI clears the presentation
    // binding before running dialog button actions.
    @State private var showingDeleteAudio = false
    @State private var deleteCandidate: EntryAudioSize?

    var body: some View {
        Form {
            vaultSizeSection
            largestAudioSection
        }
        .formStyle(.grouped)
        .task { await model.refreshStorageSummary() }
        .confirmationDialog(
            "Delete the audio of “\(deleteCandidateTitle)”?",
            isPresented: $showingDeleteAudio,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                if let candidate = deleteCandidate {
                    Task {
                        if let entry = model.snapshot?.entry(withID: candidate.entryRelativePath) {
                            await model.deleteAudio(for: entry)
                        }
                        await model.refreshStorageSummary()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Same statement of consequences as the entry-level flow (AUD-1).
            Text("This frees \(deleteCandidate.map { Self.format($0.audioBytes) } ?? "its disk space"). "
                + "The transcript is kept, and the audio can be restored from "
                + "Recently Deleted for \(model.trashRetentionDays) days.")
        }
    }

    // MARK: - Vault size

    @ViewBuilder
    private var vaultSizeSection: some View {
        Section {
            if let summary = model.storageSummary {
                LabeledContent("Total Vault Size") {
                    HStack(spacing: 6) {
                        if model.storageSummaryIsLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Text(Self.format(summary.totalBytes))
                    }
                }
                splitBar(summary)
                LabeledContent("Audio", value: Self.format(summary.audioBytes))
                LabeledContent("Text & Metadata", value: Self.format(summary.textBytes))
                LabeledContent("Recently Deleted", value: Self.format(summary.trashBytes))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring vault…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Vault Size")
        } footer: {
            Text("Audio counts every recording and import; text is transcripts, metadata, and caches. Recently Deleted empties itself after \(model.trashRetentionDays) days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func splitBar(_ summary: VaultStorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    segment(summary.audioBytes, of: summary.totalBytes,
                            width: proxy.size.width, color: .accentColor)
                    segment(summary.textBytes, of: summary.totalBytes,
                            width: proxy.size.width, color: .green)
                    segment(summary.trashBytes, of: summary.totalBytes,
                            width: proxy.size.width, color: Color(nsColor: .systemGray))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                legendDot(.accentColor, "Audio")
                legendDot(.green, "Text & Metadata")
                legendDot(Color(nsColor: .systemGray), "Recently Deleted")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true) // the labeled rows carry the numbers
    }

    @ViewBuilder
    private func segment(_ bytes: Int64, of total: Int64, width: CGFloat, color: Color) -> some View {
        if bytes > 0, total > 0 {
            color.frame(width: max(3, width * CGFloat(bytes) / CGFloat(total)))
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: - Largest audio

    @ViewBuilder
    private var largestAudioSection: some View {
        Section("Largest Audio") {
            let ranked = model.storageSummary?.largestAudioEntries ?? []
            if ranked.isEmpty {
                Text(model.storageSummary == nil ? "Measuring…" : "No entries with audio.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ranked) { item in
                    largestAudioRow(item)
                }
            }
        }
    }

    private func largestAudioRow(_ item: EntryAudioSize) -> some View {
        let entry = model.snapshot?.entry(withID: item.entryRelativePath)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.displayTitle ?? item.entryRelativePath.lastComponent)
                    .lineLimit(1)
                Text(rowCaption(item, entry: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Self.format(item.audioBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Delete Audio…") {
                deleteCandidate = item
                showingDeleteAudio = true
            }
            .disabled(!canDeleteAudio(item, entry: entry))
        }
    }

    private func rowCaption(_ item: EntryAudioSize, entry: Entry?) -> String {
        let folder = item.entryRelativePath.parentRelativePath
        let location = folder.isEmpty ? "Vault Root" : folder
        guard let entry else { return location }
        return "\(location) · \(entry.created.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Same guard as the entry-level flow: the file must exist and not be
    /// mid-recording. Entries missing from the snapshot can't be resolved.
    private func canDeleteAudio(_ item: EntryAudioSize, entry: Entry?) -> Bool {
        guard let entry else { return false }
        return entry.hasAudio && model.recorder.currentEntryPath != entry.relativePath
    }

    private var deleteCandidateTitle: String {
        guard let candidate = deleteCandidate else { return "" }
        return model.snapshot?.entry(withID: candidate.entryRelativePath)?.displayTitle
            ?? candidate.entryRelativePath.lastComponent
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
