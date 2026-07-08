import SwiftUI

/// Milestone-1 placeholder detail view. The transcript body is the first-class
/// content; entry metadata is tucked behind "Show Info" (right-click or the
/// toolbar ⓘ button).
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?
    @State private var showingInfo = false

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
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text(entry.created.formatted(date: .abbreviated, time: .shortened))
                        if let duration = entry.duration {
                            Text("·")
                            Text(EntryListView.formatDuration(duration))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let document, !document.body.isEmpty {
                    Text(document.body)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if entry.hasTranscript {
                    Text("This entry’s transcript has no text yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No transcript file in this entry yet — transcription arrives in a later milestone.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Show Info") { showingInfo = true }
                Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingInfo.toggle()
                } label: {
                    Label("Show Info", systemImage: "info.circle")
                }
                .help("Show Info")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    infoPopover(entry)
                }
            }
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

    // MARK: - Info popover

    @ViewBuilder
    private func infoPopover(_ entry: Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            infoRow("Created", entry.created.formatted(date: .complete, time: .standard))
            if let duration = entry.duration {
                infoRow("Duration", EntryListView.formatDuration(duration))
            }
            infoRow("Audio", entry.hasAudio ? "Yes" : (entry.audioDeleted ? "Deleted" : "None"))
            if let source = document?.source {
                infoRow("Source", source)
            }
            if let engine = document?.engine {
                infoRow("Engine", engine)
            }
            infoRow("Favorite", entry.favorite ? "Yes" : "No")
            infoRow("Folder", entry.parentRelativePath.isEmpty ? "Vault Root" : entry.parentRelativePath)
            infoRow("Entry ID", entry.folderName.string)
        }
        .font(.callout)
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
