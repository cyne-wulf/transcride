import Foundation

/// Background actor owning all vault file I/O so the main thread never touches
/// the disk. Wraps the scanner (with its cache), mutation operations, and trash.
actor VaultService {
    let rootURL: URL
    private var scanner = VaultScanner()
    private let operations: VaultOperations
    private let trash: TrashStore

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.operations = VaultOperations(vaultRoot: rootURL)
        self.trash = TrashStore(vaultRoot: rootURL)
    }

    // MARK: - Reading

    func snapshot() -> VaultSnapshot {
        scanner.scan(root: rootURL)
    }

    func readTranscript(atEntryPath relPath: RelativePath) -> FrontmatterDocument? {
        let url = rootURL.appendingRelativePath(relPath)
            .appending(path: VaultScanner.transcriptFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FrontmatterDocument.parse(text)
    }

    // MARK: - Folder / entry mutations

    func createFolder(named name: String, inFolder parent: RelativePath) throws -> RelativePath {
        try operations.createFolder(named: name, inFolder: parent)
    }

    func renameFolder(at relPath: RelativePath, to newName: String) throws -> RelativePath {
        try operations.renameFolder(at: relPath, to: newName)
    }

    func renameEntry(at relPath: RelativePath, toTitle title: String) throws -> RelativePath {
        try operations.renameEntry(at: relPath, toTitle: title)
    }

    func moveItem(at relPath: RelativePath, toFolder destFolder: RelativePath) throws -> RelativePath {
        try operations.moveItem(at: relPath, toFolder: destFolder)
    }

    // MARK: - Trash

    func trashItem(atRelativePath relPath: RelativePath) throws {
        try trash.trashItem(atRelativePath: relPath)
    }

    func trashItems() throws -> [TrashItem] {
        try trash.items()
    }

    func restore(_ item: TrashItem) throws -> RelativePath {
        try trash.restore(item)
    }

    func deletePermanently(_ item: TrashItem) throws {
        try trash.deletePermanently(item)
    }

    func purgeTrash() throws -> Int {
        try trash.purge()
    }
}
