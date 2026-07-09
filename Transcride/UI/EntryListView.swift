import SwiftUI

struct EntryListView: View {
    @Environment(AppModel.self) private var model

    // Alert payloads are separate from the isPresented Bools: SwiftUI clears
    // the presentation binding before the button action runs, so actions must
    // never read state tied to isPresented.
    @State private var showRenamePrompt = false
    @State private var renamingEntry: Entry?
    @State private var renameDraft = ""

    private var folder: FolderNode? { model.selectedFolder }

    var body: some View {
        @Bindable var model = model
        Group {
            if let folder {
                if folder.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Entries", systemImage: "waveform")
                    } description: {
                        Text("Entries in “\(folderTitle(folder))” will appear here.")
                    }
                } else {
                    List(selection: $model.selectedEntryID) {
                        ForEach(folder.entries) { entry in
                            entryRow(entry)
                                .tag(entry.id)
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "folder")
            }
        }
        .navigationTitle(folder.map(folderTitle) ?? "Entries")
        .alert("Rename Entry", isPresented: $showRenamePrompt) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let entry = renamingEntry {
                    let title = renameDraft
                    Task { await model.renameEntry(entry, toTitle: title) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The title is saved into the entry’s frontmatter and appended to its folder name as a slug.")
        }
    }

    private func folderTitle(_ folder: FolderNode) -> String {
        folder.relativePath.isEmpty ? (model.vaultURL?.lastPathComponent ?? "Vault") : folder.name
    }

    // MARK: - Row

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if entry.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Spacer()
                if let duration = entry.duration {
                    Text(Self.formatDuration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(entry.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.hasAudio {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if entry.audioDeleted {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !entry.snippet.isEmpty {
                Text(entry.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .draggable(entry.relativePath)
        .contextMenu {
            Button("Rename…") { beginRename(entry) }
            moveToMenu(entry)
            Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
            Divider()
            // No confirmation: trashing is restorable for 30 days from
            // Recently Deleted, so it doesn't warrant a safety dialog.
            Button("Delete", role: .destructive) {
                Task { await model.deleteItem(atRelativePath: entry.relativePath) }
            }
        }
    }

    @ViewBuilder
    private func moveToMenu(_ entry: Entry) -> some View {
        if let root = model.snapshot?.root {
            Menu("Move To") {
                ForEach(root.allFolders) { target in
                    if target.relativePath != entry.parentRelativePath {
                        Button(target.relativePath.isEmpty ? "Vault Root" : target.relativePath) {
                            Task {
                                await model.moveItem(
                                    atRelativePath: entry.relativePath,
                                    toFolder: target.relativePath
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rename

    private func beginRename(_ entry: Entry) {
        renameDraft = entry.title ?? entry.displayTitle
        renamingEntry = entry
        showRenamePrompt = true
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
