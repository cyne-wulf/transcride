import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case folder(RelativePath)
    case recentlyDeleted
}

/// Main-actor view model for the whole app. All file I/O is delegated to the
/// background `VaultService` actor; this type only holds published state.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case needsVault
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var vaultURL: URL?
    private(set) var snapshot: VaultSnapshot?
    private(set) var trashItems: [TrashItem] = []

    var sidebarSelection: SidebarSelection? = .folder("")
    var selectedEntryID: String?
    var errorMessage: String?

    private var service: VaultService?
    private var watcher: FSEventsWatcher?
    /// URL currently holding security-scoped access (stopAccessing on switch).
    private var scopedURL: URL?

    var selectedEntry: Entry? {
        guard let selectedEntryID else { return nil }
        return snapshot?.entry(withID: selectedEntryID)
    }

    var selectedFolder: FolderNode? {
        guard case .folder(let relPath)? = sidebarSelection else { return nil }
        return snapshot?.folder(at: relPath)
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .launching else { return }
        if let url = VaultBookmark.resolve() {
            await openVault(at: url, isSecurityScoped: true, saveBookmark: false)
        } else {
            phase = .needsVault
        }
    }

    /// Opens `url` as the vault, replacing any current vault.
    func openVault(at url: URL, isSecurityScoped: Bool, saveBookmark: Bool) async {
        watcher?.stop()
        watcher = nil
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }

        if isSecurityScoped, url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        if saveBookmark {
            do {
                try VaultBookmark.save(url)
            } catch {
                errorMessage = "Could not save vault access: \(error.localizedDescription)"
            }
        }

        vaultURL = url
        let service = VaultService(rootURL: url)
        self.service = service
        snapshot = nil
        trashItems = []
        sidebarSelection = .folder("")
        selectedEntryID = nil
        phase = .ready

        watcher = FSEventsWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }

        // 30-day purge on launch/open, then first scan.
        _ = try? await service.purgeTrash()
        await refresh()
    }

    func refresh() async {
        guard let service else { return }
        let snap = await service.snapshot()
        let trash = (try? await service.trashItems()) ?? []
        snapshot = snap
        trashItems = trash
        // Drop selections that no longer exist on disk.
        if case .folder(let relPath)? = sidebarSelection, snap.folder(at: relPath) == nil {
            sidebarSelection = .folder("")
        }
        if let selectedEntryID, snap.entry(withID: selectedEntryID) == nil {
            self.selectedEntryID = nil
        }
    }

    // MARK: - Vault selection panels

    func chooseExistingVault() {
        let panel = NSOpenPanel()
        panel.title = "Open Vault"
        panel.message = "Choose the folder that is (or will become) your transcride vault."
        panel.prompt = "Open Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openVault(at: url, isSecurityScoped: true, saveBookmark: true) }
    }

    func createNewVault() {
        let panel = NSSavePanel()
        panel.title = "Create New Vault"
        panel.message = "Choose a name and location for your new transcride vault."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Transcride Vault"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create vault: \(error.localizedDescription)"
            return
        }
        Task { await openVault(at: url, isSecurityScoped: true, saveBookmark: true) }
    }

    // MARK: - Intents (folders)

    func createFolder(named name: String, inFolder parent: RelativePath) async {
        await perform { service in
            _ = try await service.createFolder(named: name, inFolder: parent)
        }
    }

    func renameFolder(at relPath: RelativePath, to newName: String) async {
        await perform { service in
            let newPath = try await service.renameFolder(at: relPath, to: newName)
            await MainActor.run {
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(newPath)
                }
            }
        }
    }

    // MARK: - Intents (entries)

    func renameEntry(_ entry: Entry, toTitle title: String) async {
        await perform { service in
            let newPath = try await service.renameEntry(at: entry.relativePath, toTitle: title)
            await MainActor.run {
                if self.selectedEntryID == entry.relativePath {
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func moveItem(atRelativePath relPath: RelativePath, toFolder destFolder: RelativePath) async {
        await perform { service in
            let newPath = try await service.moveItem(at: relPath, toFolder: destFolder)
            await MainActor.run {
                if self.selectedEntryID == relPath {
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func deleteItem(atRelativePath relPath: RelativePath) async {
        await perform { service in
            try await service.trashItem(atRelativePath: relPath)
            await MainActor.run {
                if self.selectedEntryID == relPath { self.selectedEntryID = nil }
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(relPath.parentRelativePath)
                }
            }
        }
    }

    // MARK: - Intents (trash)

    func restoreTrashItem(_ item: TrashItem) async {
        await perform { service in
            _ = try await service.restore(item)
        }
    }

    func deleteTrashItemPermanently(_ item: TrashItem) async {
        await perform { service in
            try await service.deletePermanently(item)
        }
    }

    // MARK: - Misc

    func revealInFinder(relativePath: RelativePath) {
        guard let vaultURL else { return }
        let url = vaultURL.appendingRelativePath(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealTrashItemInFinder(_ item: TrashItem) {
        guard let vaultURL else { return }
        let url = vaultURL
            .appending(path: TrashStore.directoryName)
            .appending(path: item.trashedName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func readTranscript(for entry: Entry) async -> FrontmatterDocument? {
        await service?.readTranscript(atEntryPath: entry.relativePath)
    }

    private func perform(_ work: (VaultService) async throws -> Void) async {
        guard let service else { return }
        do {
            try await work(service)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}
