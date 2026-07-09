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
                    Text(info.displayName).tag(info.id)
                }
            }
            Text("New recordings and imports are transcribed with this model. Retranscribe lets you pick a different one per entry.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(ModelCatalog.available) { info in
                ModelRow(info: info)
            }
        }
        .task { await model.modelManager.refresh() }
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
            case .downloaded(let byteSize):
                if let byteSize {
                    Text(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    var body: some View {
        Section("Custom Vocabulary") {
            if model.vaultURL == nil {
                Text("Open a vault to edit its vocabulary.")
                    .foregroundStyle(.secondary)
            } else {
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
                HStack {
                    TextField("Add a word or phrase…", text: $newTerm)
                        .textFieldStyle(.plain)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Names and jargon listed here are corrected in every transcript (and passed to models that support biasing). Saved to vocabulary.txt in the vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        rows.append(Row(text: term))
        newTerm = ""
    }

    private func persist() {
        let terms = rows
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task { await model.saveVocabularyTerms(terms) }
    }
}
