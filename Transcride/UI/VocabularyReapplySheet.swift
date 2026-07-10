import SwiftUI

/// VOC-4 preview sheet: shows what the correction backstop would change in
/// existing transcripts for the given terms, lets the user exclude entries,
/// and applies on confirm. Corrections follow the M3 rules — `corrected_from`
/// in the JSON, hand-edited `transcript.md` never touched.
struct VocabularyReapplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The terms to scan for — the just-added ones, or the whole vocabulary
    /// from the explicit "Re-apply…" button.
    let terms: [String]

    private enum Phase {
        case scanning
        case results(AppModel.VocabularyReapplyScan)
        case applying
        case done(VocabularyReapplyApplier.Summary)
    }

    @State private var phase: Phase = .scanning
    @State private var excluded: Set<RelativePath> = []
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            footer
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 300, idealHeight: 420)
        .task {
            let scan = await model.previewVocabularyReapply(terms: terms)
            if case .scanning = phase {
                phase = .results(scan ?? .init(previews: [], skippedBusyCount: 0))
            }
        }
    }

    private var termsDescription: String {
        terms.count == 1 ? "“\(terms[0])”" : "\(terms.count) vocabulary terms"
    }

    @ViewBuilder
    private var header: some View {
        Text("Re-apply Vocabulary")
            .font(.headline)
        Text("Checking existing transcripts for \(termsDescription). Corrections keep the engine’s words recoverable; hand-edited notes keep their text (only their transcript data is corrected).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning transcripts…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let scan) where scan.previews.isEmpty:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No existing transcript would change.")
                if scan.skippedBusyCount > 0 {
                    Text(skippedNote(scan.skippedBusyCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let scan):
            List {
                ForEach(scan.previews, id: \.entryRelativePath) { preview in
                    entryRow(preview)
                }
            }
            .listStyle(.inset)
            if case .results(let scan) = phase, scan.skippedBusyCount > 0 {
                Text(skippedNote(scan.skippedBusyCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .applying:
            VStack(spacing: 8) {
                ProgressView()
                Text("Applying corrections…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let summary):
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text(summaryText(summary))
                    .multilineTextAlignment(.center)
                if summary.handEditedKeptCount > 0 {
                    Text("\(summary.handEditedKeptCount) hand-edited \(summary.handEditedKeptCount == 1 ? "note kept its text" : "notes kept their text"); their transcript data was still corrected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryRow(_ preview: VocabularyReapply.EntryPreview) -> some View {
        let entry = model.snapshot?.entry(withID: preview.entryRelativePath)
        let included = Binding<Bool>(
            get: { !excluded.contains(preview.entryRelativePath) },
            set: { include in
                if include {
                    excluded.remove(preview.entryRelativePath)
                } else {
                    excluded.insert(preview.entryRelativePath)
                }
            }
        )
        return DisclosureGroup {
            ForEach(Array(preview.corrections.enumerated()), id: \.offset) { _, correction in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(correction.originalText)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(correction.correctedText)
                            .fontWeight(.medium)
                    }
                    Text(correction.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
        } label: {
            Toggle(isOn: included) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry?.displayTitle ?? preview.entryRelativePath)
                            .lineLimit(1)
                        if let created = entry?.created {
                            Text(created.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(preview.corrections.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .scanning, .applying:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .results(let scan) where scan.previews.isEmpty:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .results(let scan):
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle(scan)) {
                    apply(scan)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(includedPaths(scan).isEmpty)
            case .done:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func includedPaths(_ scan: AppModel.VocabularyReapplyScan) -> [RelativePath] {
        scan.previews.map(\.entryRelativePath).filter { !excluded.contains($0) }
    }

    private func applyTitle(_ scan: AppModel.VocabularyReapplyScan) -> String {
        let paths = Set(includedPaths(scan))
        let count = scan.previews
            .filter { paths.contains($0.entryRelativePath) }
            .reduce(0) { $0 + $1.corrections.count }
        return "Apply \(count) \(count == 1 ? "Correction" : "Corrections")"
    }

    private func apply(_ scan: AppModel.VocabularyReapplyScan) {
        let paths = includedPaths(scan)
        phase = .applying
        Task {
            let summary = await model.applyVocabularyReapply(terms: terms, toEntriesAt: paths)
            phase = .done(summary ?? .init())
        }
    }

    private func summaryText(_ summary: VocabularyReapplyApplier.Summary) -> String {
        let entries = summary.changedEntryPaths.count
        return "\(summary.correctionCount) \(summary.correctionCount == 1 ? "correction" : "corrections") applied in \(entries) \(entries == 1 ? "entry" : "entries")."
    }

    private func skippedNote(_ count: Int) -> String {
        "\(count) \(count == 1 ? "entry is" : "entries are") being transcribed and \(count == 1 ? "was" : "were") skipped — new transcriptions use the updated vocabulary automatically."
    }
}
