import SwiftUI

private enum VaultSwitcherAction: Hashable {
    case open, create, reveal
}

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
    @State private var showVaultSwitcher = false
    @State private var hoveredRecentVaultID: String?
    @State private var hoveredForgetVaultID: String?
    @State private var hoveredVaultAction: VaultSwitcherAction?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { model.requestSidebarSelection($0) }
        )) {
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
            .onTapGesture { showVaultSwitcher.toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showVaultSwitcher.toggle() }
            .help("Current vault: \(model.vaultURL?.path ?? "none"). Click to switch.")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .popover(isPresented: $showVaultSwitcher, arrowEdge: .bottom) {
                vaultSwitcherPopover
            }
        }
        .background(.bar)
    }

    private var vaultSwitcherPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.recentVaults.isEmpty {
                Text("Recent Vaults")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                // Persistence stays newest-first; rendering oldest-first puts
                // the current/most-recent vault next to the footer trigger.
                ForEach(model.recentVaults.reversed()) { recent in
                    let isCurrent = recent.url.standardizedFileURL == model.vaultURL?.standardizedFileURL
                    HStack(spacing: 6) {
                        Button {
                            showVaultSwitcher = false
                            if !isCurrent {
                                model.openRecentVault(recent)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "checkmark.circle.fill" : "externaldrive")
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recent.url.lastPathComponent)
                                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                    Text(recent.url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(
                                            isCurrent ? Color.secondary : Color.secondary.opacity(0.7)
                                        )
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(recentRowBackground(isCurrent: isCurrent, id: recent.id))
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .onHover { isInside in
                            updateHover(&hoveredRecentVaultID, id: recent.id, isInside: isInside)
                        }

                        Button {
                            model.forgetRecentVault(recent)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background {
                                    Circle()
                                        .fill(
                                            hoveredForgetVaultID == recent.id
                                                ? Color.primary.opacity(0.12)
                                                : Color.clear
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .accessibilityLabel("Forget \(recent.url.lastPathComponent)")
                        .help("Forget \(recent.url.lastPathComponent) (does not delete files)")
                        .onHover { isInside in
                            updateHover(&hoveredForgetVaultID, id: recent.id, isInside: isInside)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                Divider()
            }

            vaultActionButton(.open, title: "Open Another Vault…", systemImage: "folder") {
                showVaultSwitcher = false
                model.chooseExistingVault()
            }
            vaultActionButton(.create, title: "Create New Vault…", systemImage: "folder.badge.plus") {
                showVaultSwitcher = false
                model.createNewVault()
            }
            if let url = model.vaultURL {
                vaultActionButton(.reveal, title: "Reveal Vault in Finder", systemImage: "finder") {
                    showVaultSwitcher = false
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 300)
    }

    private func recentRowBackground(isCurrent: Bool, id: String) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if hoveredRecentVaultID == id { return Color.primary.opacity(0.07) }
        return .clear
    }

    private func updateHover(_ hoveredID: inout String?, id: String, isInside: Bool) {
        if isInside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    private func vaultActionButton(
        _ action: VaultSwitcherAction,
        title: String,
        systemImage: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        hoveredVaultAction == action
                            ? Color.primary.opacity(0.09)
                            : Color.clear
                    )
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onHover { isInside in
            if isInside {
                hoveredVaultAction = action
            } else if hoveredVaultAction == action {
                hoveredVaultAction = nil
            }
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
