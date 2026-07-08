import SwiftUI

/// Milestone-1 placeholder detail view: frontmatter metadata plus the raw
/// `transcript.md` body, rendered read-only.
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                entryDetail(entry)
                    .task(id: taskKey(for: entry)) {
                        document = await model.readTranscript(for: entry)
                    }
            } else {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "waveform",
                    description: Text("Select an entry to see its transcript.")
                )
            }
        }
    }

    /// Reload when a different entry is selected or the file changes on disk.
    private func taskKey(for entry: Entry) -> String {
        "\(entry.relativePath)|\(entry.title ?? "")|\(entry.snippet)"
    }

    @ViewBuilder
    private func entryDetail(_ entry: Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayTitle)
                        .font(.title.bold())
                    Text(entry.created.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                metadataGrid(entry)

                Divider()

                if let document, !document.body.isEmpty {
                    Text(document.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if entry.hasTranscript {
                    Text("This entry’s transcript has no text yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No transcript.md in this entry yet — transcription arrives in a later milestone.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.revealInFinder(relativePath: entry.relativePath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
            }
        }
    }

    @ViewBuilder
    private func metadataGrid(_ entry: Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let duration = entry.duration {
                metadataRow("Duration", EntryListView.formatDuration(duration))
            }
            metadataRow("Audio", entry.hasAudio ? "Yes" : (entry.audioDeleted ? "Deleted" : "None"))
            if let source = document?.source {
                metadataRow("Source", source)
            }
            if let engine = document?.engine {
                metadataRow("Engine", engine)
            }
            if entry.favorite {
                metadataRow("Favorite", "Yes")
            }
            metadataRow("Folder", entry.parentRelativePath.isEmpty ? "Vault Root" : entry.parentRelativePath)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
        }
    }
}
