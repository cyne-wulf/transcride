import SwiftUI

struct EntryListView: View {
    @Environment(AppModel.self) private var model

    @State private var renamingEntryID: String?
    @State private var renameDraft = ""
    @State private var deletingEntry: Entry?
    @FocusState private var renameFieldFocused: Bool

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
        .confirmationDialog(
            "Move “\(deletingEntry?.displayTitle ?? "")” to Recently Deleted?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                if let entry = deletingEntry {
                    Task { await model.deleteItem(atRelativePath: entry.relativePath) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It can be restored from Recently Deleted for 30 days.")
        }
    }

    private func folderTitle(_ folder: FolderNode) -> String {
        folder.relativePath.isEmpty ? (model.vaultURL?.lastPathComponent ?? "Vault") : folder.name
    }

    // MARK: - Row

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if renamingEntryID == entry.id {
                TextField("Title", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(entry) }
                    .onExitCommand { renamingEntryID = nil }
            } else {
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
            Button("Delete", role: .destructive) { deletingEntry = entry }
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
        renamingEntryID = entry.id
        renameFieldFocused = true
    }

    private func commitRename(_ entry: Entry) {
        let title = renameDraft
        renamingEntryID = nil
        Task { await model.renameEntry(entry, toTitle: title) }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
