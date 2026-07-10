import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    // Alert payloads live in separate state from the isPresented Bools:
    // SwiftUI clears the presentation binding before running the button
    // action, so an action must never read state tied to isPresented.
    @State private var showNewFolderPrompt = false
    @State private var newFolderParent: RelativePath = ""
    @State private var newFolderName = ""
    @State private var showRenamePrompt = false
    @State private var renamingFolderPath: RelativePath = ""
    @State private var renameFolderName = ""
    @State private var showDeletePrompt = false
    @State private var deletingFolderPath: RelativePath = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            if let root = model.snapshot?.root {
                Section("Vault") {
                    folderRow(root, isRoot: true)
                        .tag(SidebarSelection.folder(""))
                    OutlineGroup(root.subfolders, id: \.relativePath, children: \.outlineChildren) { node in
                        folderRow(node, isRoot: false)
                            .tag(SidebarSelection.folder(node.relativePath))
                    }
                }
            }
            Section {
                Label("Favorites", systemImage: "star")
                    .badge(model.favoriteEntries.count)
                    .tag(SidebarSelection.favorites)
                Label("Recently Deleted", systemImage: "trash")
                    .badge(model.trashItems.count)
                    .tag(SidebarSelection.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.newFolderRequestRevision) { _, _ in
            // File → New Folder… routes here; same prompt as the toolbar button.
            beginNewFolder(in: currentFolderPath)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            vaultFooter
        }
        .toolbar {
            ToolbarItem {
                Button {
                    beginNewFolder(in: currentFolderPath)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New Folder")
            }
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let parent = newFolderParent
                let name = newFolderName
                Task { await model.createFolder(named: name, inFolder: parent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder inside “\(folderDisplayName(newFolderParent))”.")
        }
        .alert("Rename Folder", isPresented: $showRenamePrompt) {
            TextField("Name", text: $renameFolderName)
            Button("Rename") {
                let path = renamingFolderPath
                let name = renameFolderName
                Task { await model.renameFolder(at: path, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move “\(deletingFolderPath.lastComponent)” to Recently Deleted?",
            isPresented: $showDeletePrompt,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                let path = deletingFolderPath
                Task { await model.deleteItem(atRelativePath: path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder and everything inside it can be restored from Recently Deleted for 30 days.")
        }
    }

    // MARK: - Vault footer

    /// Bottom-of-sidebar vault switcher (Obsidian-style): shows the current
    /// vault's name and opens a menu to switch, create, or reveal vaults.
    private var vaultFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Menu {
                Button("Open Another Vault…") { model.chooseExistingVault() }
                Button("Create New Vault…") { model.createNewVault() }
                if let url = model.vaultURL {
                    Divider()
                    Button("Reveal Vault in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.secondary)
                    Text(model.vaultURL?.lastPathComponent ?? "No Vault")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Current vault: \(model.vaultURL?.path ?? "none"). Click to switch.")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Rows

    @ViewBuilder
    private func folderRow(_ node: FolderNode, isRoot: Bool) -> some View {
        Label(isRoot ? "Vault Root" : node.name, systemImage: isRoot ? "tray.full" : "folder")
            .dropDestination(for: String.self) { paths, _ in
                guard !paths.isEmpty else { return false }
                Task {
                    for path in paths {
                        await model.moveItem(atRelativePath: path, toFolder: node.relativePath)
                    }
                }
                return true
            }
            .contextMenu {
                Button("New Folder Inside…") { beginNewFolder(in: node.relativePath) }
                if !isRoot {
                    Button("Rename…") {
                        renameFolderName = node.name
                        renamingFolderPath = node.relativePath
                        showRenamePrompt = true
                    }
                }
                Button("Reveal in Finder") { model.revealInFinder(relativePath: node.relativePath) }
                if !isRoot {
                    Divider()
                    Button("Delete", role: .destructive) {
                        deletingFolderPath = node.relativePath
                        showDeletePrompt = true
                    }
                }
            }
    }

    // MARK: - Helpers

    private var currentFolderPath: RelativePath {
        if case .folder(let path)? = model.sidebarSelection { return path }
        return ""
    }

    private func folderDisplayName(_ relPath: RelativePath) -> String {
        relPath.isEmpty ? (model.vaultURL?.lastPathComponent ?? "Vault") : relPath.lastComponent
    }

    private func beginNewFolder(in parent: RelativePath) {
        newFolderName = ""
        newFolderParent = parent
        showNewFolderPrompt = true
    }
}
