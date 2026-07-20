import SwiftUI

struct EntryListView: View {
    @Environment(AppModel.self) private var model

    // Alert payloads are separate from the isPresented Bools: SwiftUI clears
    // the presentation binding before the button action runs, so actions must
    // never read state tied to isPresented.
    @State private var showRenamePrompt = false
    @State private var renamingEntry: Entry?
    @State private var renameDraft = ""
    @State private var sortPopover = SortPopoverController()
    @FocusState private var entryListHasFocus: Bool

    private var folder: FolderNode? { model.selectedFolder }
    private var isFavoritesView: Bool { model.sidebarSelection == .favorites }
    private var displayedNavigationTitle: String {
        isFavoritesView ? "Favorites" : folder.map(folderTitle) ?? "Entries"
    }

    var body: some View {
        @Bindable var model = model
        let entries = model.displayedEntries
        Group {
            if isFavoritesView, entries.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Star an entry — the ☆ in its toolbar or ⌘D — and it appears here.")
                }
            } else if isFavoritesView || folder != nil {
                if entries.isEmpty {
                    if vaultIsEmpty {
                        emptyVaultState
                    } else {
                        emptyFolderState
                    }
                } else {
                    List(selection: Binding(
                        get: { model.selectedEntryID },
                        set: { model.requestEntrySelection($0) }
                    )) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .tag(entry.id)
                        }
                    }
                    .listStyle(.inset)
                    .focused($entryListHasFocus)
                    .defaultFocus($entryListHasFocus, true)
                    .task {
                        // Make the vault immediately keyboard-navigable after
                        // launch. Native List handling keeps Up/Down selection;
                        // AppModel routes Option-Up/Down to the folder sidebar.
                        await Task.yield()
                        entryListHasFocus = true
                    }
                }
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "folder")
            }
        }
        .navigationTitle("")
        .onChange(of: model.renameEntryRequestRevision) { _, _ in
            // Entry → Rename… routes here; same prompt as the context menu.
            if let entry = model.selectedEntry { beginRename(entry) }
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(id: "middleTitle", placement: .navigation) {
                    middleTitleAndSearch
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(id: "middleTitle", placement: .navigation) {
                    middleTitleAndSearch
                }
            }

            ToolbarItem(id: "middleImport") {
                Button {
                    model.importViaPanel()
                } label: {
                    Label("Import Audio", systemImage: "plus")
                }
                .disabled(model.phase != .ready)
                .help("Import Audio")
                .accessibilityLabel("Import Audio")
                .accessibilityIdentifier("middleImport")
            }

            if let queue = model.transcriptionQueue {
                ToolbarItem(id: "middleQueue") {
                    TranscriptionQueueButton(queue: queue) {
                        sortPopover.dismiss()
                    }
                }
            }

            ToolbarItem(id: "middleSort") {
                Button {
                    model.toggleEntrySortDirection()
                    sortPopover.presentOrKeepOpen()
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .background {
                            SortPopoverAnchor(controller: sortPopover)
                        }
                }
                .help("Sort entries by \(model.entrySortOrder.displayName.lowercased()), \(model.entrySortDirection.rawValue)")
                .accessibilityLabel("Sort entries")
                .accessibilityIdentifier("middleSort")
            }
        }
        .onAppear {
            configureSortPopover()
        }
        .onChange(of: model.entrySortOrder) { _, _ in
            configureSortPopover()
        }
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

    private var middleTitleAndSearch: some View {
        HStack(spacing: 10) {
            Text(displayedNavigationTitle)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                model.presentVaultSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.phase != .ready)
            .help("Search this vault")
            .accessibilityLabel("Search this vault")
            .accessibilityIdentifier("middleGlobalSearch")
        }
    }

    private func configureSortPopover() {
        sortPopover.configure(selection: model.entrySortOrder) { order in
            model.selectEntrySortOrder(order)
        }
    }

    private func folderTitle(_ folder: FolderNode) -> String {
        folder.relativePath.isEmpty ? (model.vaultURL?.lastPathComponent ?? "Vault") : folder.name
    }

    // MARK: - Empty states

    private var vaultIsEmpty: Bool {
        model.snapshot?.allEntries.isEmpty ?? true
    }

    /// First-run feel: a brand-new vault greets rather than reports absence.
    private var emptyVaultState: some View {
        ContentUnavailableView {
            Label("Your Vault Is Ready", systemImage: "waveform.and.mic")
        } description: {
            Text("Everything you say becomes a searchable, editable note — stored as plain files in this folder.")
        } actions: {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.recorder.isActive)

            Button("Import Audio…") {
                model.importViaPanel()
            }
        }
    }

    private var emptyFolderState: some View {
        ContentUnavailableView {
            Label("No Entries", systemImage: "folder")
        } description: {
            Text("“\(folder.map(folderTitle) ?? "This folder")” is empty. New recordings land in the selected folder — or drop audio files anywhere in the window to import.")
        } actions: {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Record Here", systemImage: "record.circle")
            }
            .disabled(model.recorder.isActive)
        }
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
            Button(entry.favorite ? "Unfavorite" : "Favorite") {
                Task { await model.toggleFavorite(for: entry) }
            }
            Divider()
            Button("Rename…") { beginRename(entry) }
            Button("Duplicate") { Task { await model.duplicateEntry(entry) } }
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
