import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Export Markdown…" (EXP-2): writes the chosen layer as a clean `.md` —
/// body only, no frontmatter — into a user-picked folder such as an Obsidian
/// vault, remembering the destination for next time.
struct ExportMarkdownSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    let original: TranscriptOriginal?
    let document: FrontmatterDocument?

    @State private var layer: TranscriptWorkbenchView.Layer = .original
    @State private var includeSpeakerLabels = true
    @State private var includeTimestamps = false
    @State private var exportError: String?
    @State private var exportedFileURL: URL?

    private var isForked: Bool {
        guard let document else { return false }
        return TranscriptEditDocument.isForked(document, comparedTo: original)
    }

    private var hasSpeakers: Bool {
        original?.segments.contains { $0.speaker != nil } == true
    }

    /// The options only shape regenerated original-layer content; an edited
    /// body is the user's text and exports verbatim.
    private var optionsApply: Bool { layer == .original && original != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let exportedFileURL {
                exportedView(exportedFileURL)
            } else {
                configureView
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            layer = isForked ? .edited : .original
            if original == nil { layer = .edited }
        }
    }

    @ViewBuilder
    private var configureView: some View {
        Text("Export Markdown")
            .font(.headline)

        if isForked, original != nil {
            Picker("Layer", selection: $layer) {
                ForEach(TranscriptWorkbenchView.Layer.allCases) { layer in
                    Text(layer.rawValue).tag(layer)
                }
            }
            .pickerStyle(.segmented)
        }

        Toggle("Include speaker labels", isOn: $includeSpeakerLabels)
            .disabled(!optionsApply || !hasSpeakers)
            .help(hasSpeakers
                ? "Label paragraphs with **Speaker:** using your chosen names"
                : "This transcript has no speaker detection")

        Toggle("Include paragraph timestamps", isOn: $includeTimestamps)
            .disabled(!optionsApply)
            .help("Prefix each paragraph with its audio time, like [1:24]")

        if layer == .edited, isForked {
            Text("The edited note exports exactly as written; options apply when exporting the Original layer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Writes a clean .md file — no frontmatter — ready for an Obsidian vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let exportError {
            Label(exportError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Export…") { chooseDestinationAndExport() }
                .keyboardShortcut(.defaultAction)
                .disabled(exportContent() == nil)
        }
    }

    @ViewBuilder
    private func exportedView(_ fileURL: URL) -> some View {
        Label("Exported “\(fileURL.lastPathComponent)”", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.primary)

        Text(fileURL.deletingLastPathComponent().path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)

        HStack {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            if ObsidianLink.isObsidianVault(fileURL.deletingLastPathComponent()),
               let link = ObsidianLink.openURL(forPath: fileURL.path) {
                Button("Open in Obsidian") {
                    NSWorkspace.shared.open(link)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func exportContent() -> String? {
        switch layer {
        case .original:
            guard let original else { return nil }
            let names = document.map { SpeakerNames.names(in: $0) } ?? [:]
            return MarkdownExport.originalContent(
                from: original,
                speakerNames: names,
                options: .init(
                    includeSpeakerLabels: includeSpeakerLabels,
                    includeParagraphTimestamps: includeTimestamps
                )
            )
        case .edited:
            guard let document else { return nil }
            return MarkdownExport.editedContent(body: document.body)
        }
    }

    private func chooseDestinationAndExport() {
        guard let content = exportContent() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder to export “\(entry.displayTitle)” into."
        if let remembered = ExportDestination.resolve() {
            panel.directoryURL = remembered
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        do {
            let existing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            // displayTitle so untitled entries export under their date, not
            // as an anonymous "transcript.md" in someone's Obsidian vault.
            let fileName = MarkdownExport.fileName(
                forTitle: entry.displayTitle, existingNames: existing
            )
            let fileURL = folder.appending(path: fileName)
            let text = content.hasSuffix("\n") ? content : content + "\n"
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            ExportDestination.save(folder)
            exportError = nil
            exportedFileURL = fileURL
        } catch {
            exportError = error.localizedDescription
        }
    }
}
