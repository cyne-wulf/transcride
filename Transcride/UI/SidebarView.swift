import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    @State private var newFolderParent: RelativePath?
    @State private var newFolderName = ""
    @State private var renamingFolderPath: RelativePath?
    @State private var renameFolderName = ""
    @State private var deletingFolderPath: RelativePath?

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
                Label("Recently Deleted", systemImage: "trash")
                    .badge(model.trashItems.count)
                    .tag(SidebarSelection.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
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
        .alert("New Folder", isPresented: newFolderPromptShown) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let parent = newFolderParent ?? ""
                let name = newFolderName
                Task { await model.createFolder(named: name, inFolder: parent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder inside “\(folderDisplayName(newFolderParent ?? ""))”.")
        }
        .alert("Rename Folder", isPresented: renamePromptShown) {
            TextField("Name", text: $renameFolderName)
            Button("Rename") {
                if let path = renamingFolderPath {
                    let name = renameFolderName
                    Task { await model.renameFolder(at: path, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move “\(deletingFolderPath?.lastComponent ?? "")” to Recently Deleted?",
            isPresented: deletePromptShown,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                if let path = deletingFolderPath {
                    Task { await model.deleteItem(atRelativePath: path) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder and everything inside it can be restored from Recently Deleted for 30 days.")
        }
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
                    }
                }
                Button("Reveal in Finder") { model.revealInFinder(relativePath: node.relativePath) }
                if !isRoot {
                    Divider()
                    Button("Delete", role: .destructive) { deletingFolderPath = node.relativePath }
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
    }

    private var newFolderPromptShown: Binding<Bool> {
        Binding(
            get: { newFolderParent != nil },
            set: { if !$0 { newFolderParent = nil } }
        )
    }

    private var renamePromptShown: Binding<Bool> {
        Binding(
            get: { renamingFolderPath != nil },
            set: { if !$0 { renamingFolderPath = nil } }
        )
    }

    private var deletePromptShown: Binding<Bool> {
        Binding(
            get: { deletingFolderPath != nil },
            set: { if !$0 { deletingFolderPath = nil } }
        )
    }
}
