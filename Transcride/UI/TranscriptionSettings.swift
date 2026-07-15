import SwiftUI

/// Settings → Transcription: the default-model picker plus one management row
/// per catalog model (ENG-2: download with progress, cancel, delete).
struct TranscriptionModelsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ModelCatalog.defaultModelPreferenceKey) private var defaultModelID =
        ModelCatalog.defaultModelID

    var body: some View {
        Section("Transcription") {
            Picker("Default Model", selection: $defaultModelID) {
                ForEach(ModelCatalog.available) { info in
                    Text(modelPickerLabel(info)).tag(info.id)
                }
            }
            Text("Parakeet is the best all-around model. New recordings and imports are transcribed with the selected model; Retranscribe lets you choose a different one per entry.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(ModelCatalog.available) { info in
                ModelRow(info: info)
            }
            ModelRow(info: ModelCatalog.speakerDiarization)
            Text("Speaker detection labels who said what (Speaker 1, Speaker 2, …) when enabled in the Retranscribe dialog. One download serves every model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await model.modelManager.refresh() }
    }

    private func modelPickerLabel(_ info: TranscriptionModelInfo) -> String {
        info.id == ModelCatalog.parakeetV3.id
            ? info.displayName + " (Recommended)"
            : info.displayName
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let info: TranscriptionModelInfo

    private var state: ModelManager.ModelState {
        model.modelManager.state(forModelInfoID: info.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayName)
                Text("\(info.languagesDescription) · \(info.downloadSizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        if info.downloadSizeBytes == 0 {
            Text("Built into macOS")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch state {
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .notDownloaded, .failed:
                Button("Download") { model.modelManager.download(info.id) }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 90)
                Button {
                    model.modelManager.cancelDownload(info.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                Text("Preparing model… (first-time setup, can take a few minutes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloaded(let byteSize):
                if let byteSize {
                    Text(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        if let url = await model.modelManager.modelDirectory(forModelInfoID: info.id) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show in Finder")
                Button("Delete", role: .destructive) {
                    Task { await model.modelManager.delete(info.id) }
                }
            }
        }
    }
}

/// Settings → Custom Vocabulary: edits `<vault>/vocabulary.txt` in place —
/// every add/edit/delete persists immediately (VOC-1).
struct VocabularySection: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let id = UUID()
        var text: String
    }

    @State private var rows: [Row] = []
    @State private var newTerm = ""
    @State private var loaded = false
    @State private var transferMessage: String?
    /// Terms added this session and not yet offered for re-apply (VOC-4).
    @State private var pendingReapplyTerms: [String] = []
    @State private var reapplyRequest: ReapplyRequest?

    private struct ReapplyRequest: Identifiable {
        let id = UUID()
        var terms: [String]
    }

    var body: some View {
        Section("Custom Vocabulary") {
            if model.vaultURL == nil {
                Text("Open a vault to edit its vocabulary.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Add Words or Phrases", systemImage: "text.badge.plus")
                            .font(.subheadline.weight(.medium))

                        Spacer()

                        Button {
                            pasteAndImport()
                        } label: {
                            Label("Paste & Import", systemImage: "doc.on.clipboard")
                        }
                        .help("Import a Markdown or plain-text list from the clipboard")

                        Button {
                            copyDictionary()
                        } label: {
                            Label("Copy Dictionary", systemImage: "doc.on.doc")
                        }
                        .disabled(currentTerms.isEmpty)
                        .help("Copy the vocabulary as a Markdown list")
                    }

                    HStack {
                        TextField(
                            "New vocabulary terms",
                            text: $newTerm,
                            prompt: Text("For example: Transcride"),
                            axis: .vertical
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 5)
                        .accessibilityLabel("New vocabulary words or phrases")
                        .onSubmit(addTerm)

                        Button("Add", action: addTerm)
                            .disabled(VocabularyFile.parseImportedTerms(newTerm).isEmpty)
                    }

                    Text("Enter one term, or paste a Markdown or plain-text list. Names, product terms, and jargon should appear exactly as written.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let transferMessage {
                        Text(transferMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                }
                if !pendingReapplyTerms.isEmpty {
                    HStack {
                        Text(offerText)
                            .font(.caption)
                        Spacer()
                        Button("Preview…") {
                            reapplyRequest = ReapplyRequest(terms: pendingReapplyTerms)
                        }
                        Button {
                            pendingReapplyTerms = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                HStack {
                    Text("Whisper Small is the most reliable model for applying custom dictionary words. Other models may apply them some of the time. Terms are saved to vocabulary.txt in the vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-apply to Existing Transcripts…") {
                        let terms = rows
                            .map { $0.text.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        reapplyRequest = ReapplyRequest(terms: terms)
                    }
                    .disabled(rows.allSatisfy {
                        $0.text.trimmingCharacters(in: .whitespaces).isEmpty
                    })
                    .help("Check every existing transcript against the whole vocabulary")
                }
                ForEach($rows) { $row in
                    HStack {
                        TextField("Term", text: $row.text)
                            .textFieldStyle(.plain)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove term")
                    }
                }
            }
        }
        .sheet(item: $reapplyRequest) { request in
            VocabularyReapplySheet(terms: request.terms)
                .onDisappear {
                    pendingReapplyTerms.removeAll { request.terms.contains($0) }
                }
        }
        .task(id: model.vaultURL) {
            rows = await model.vocabularyTerms().map { Row(text: $0) }
            loaded = true
        }
        .onChange(of: rows.map(\.text)) {
            guard loaded else { return }
            persist()
        }
    }

    private var offerText: String {
        pendingReapplyTerms.count == 1
            ? "Check existing transcripts for “\(pendingReapplyTerms[0])”?"
            : "Check existing transcripts for the \(pendingReapplyTerms.count) new terms?"
    }

    private func addTerm() {
        guard importTerms(VocabularyFile.parseImportedTerms(newTerm)) > 0 else { return }
        newTerm = ""
        transferMessage = nil
    }

    private var currentTerms: [String] {
        rows
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @discardableResult
    private func importTerms(_ candidates: [String]) -> Int {
        var existing = Set(currentTerms)
        let additions = candidates.filter { existing.insert($0).inserted }
        guard !additions.isEmpty else { return 0 }

        rows.append(contentsOf: additions.map { Row(text: $0) })
        // Offer re-apply for completed additions only — never per keystroke.
        for term in additions where !pendingReapplyTerms.contains(term) {
            pendingReapplyTerms.append(term)
        }
        return additions.count
    }

    private func pasteAndImport() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            transferMessage = "The clipboard does not contain text."
            return
        }
        let count = importTerms(VocabularyFile.parseImportedTerms(text))
        transferMessage = count == 0
            ? "No new terms were found."
            : "Imported \(count) new \(count == 1 ? "term" : "terms")."
    }

    private func copyDictionary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            VocabularyFile.markdownList(currentTerms),
            forType: .string
        )
        transferMessage = "Copied \(currentTerms.count) \(currentTerms.count == 1 ? "term" : "terms") as Markdown."
    }

    private func persist() {
        let terms = rows
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task { await model.saveVocabularyTerms(terms) }
    }
}
