import Foundation
import Testing

@Suite("Trash and restore")
struct TrashStoreTests {
    /// Builds a throwaway vault containing `Journal/transcride-…-test-note` with a transcript.
    private func makeVault() throws -> (root: URL, entryRelPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entryRelPath = "Journal/transcride-2026-07-01T10-00-00-test-note"
        let entryURL = root.appendingRelativePath(entryRelPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Test Note\"\n---\nBody.\n",
            to: entryURL.appending(path: "transcript.md")
        )
        return (root, entryRelPath)
    }

    @Test func trashMovesItemAndWritesSidecar() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        let trashedName = try store.trashItem(atRelativePath: entryRelPath)
        #expect(trashedName == "transcride-2026-07-01T10-00-00-test-note")
        #expect(!FileManager.default.fileExists(atPath: root.appendingRelativePath(entryRelPath).path))
        #expect(FileManager.default.fileExists(atPath: store.trashDirectory.appending(path: trashedName).path))

        let info = try #require(store.readInfo(forTrashedName: trashedName))
        #expect(info.originalPath == entryRelPath)

        let items = try store.items()
        #expect(items.count == 1)
        #expect(items[0].isEntry)
        #expect(items[0].originalPath == entryRelPath)
    }

    @Test func restoreReturnsItemToOriginalSubfolder() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        try store.trashItem(atRelativePath: entryRelPath)
        // Remove the now-empty parent so restore has to recreate it.
        try FileManager.default.removeItem(at: root.appending(path: "Journal"))

        let item = try #require(try store.items().first)
        let restoredPath = try store.restore(item)
        #expect(restoredPath == entryRelPath)
        let restoredURL = root.appendingRelativePath(entryRelPath)
        #expect(FileManager.default.fileExists(atPath: restoredURL.appending(path: "transcript.md").path))
        #expect(try store.items().isEmpty)
        // Sidecar cleaned up too.
        #expect(!FileManager.default.fileExists(atPath: store.sidecarURL(forTrashedName: item.trashedName).path))
    }

    @Test func trashNameCollisionGetsSuffix() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        try store.trashItem(atRelativePath: entryRelPath)

        // Same-named entry deleted again (e.g. restored copy or recreated externally).
        let entryURL = root.appendingRelativePath(entryRelPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let second = try store.trashItem(atRelativePath: entryRelPath)
        #expect(second == "transcride-2026-07-01T10-00-00-test-note-2")
        #expect(try store.items().count == 2)
    }

    @Test func restoreCollisionGetsSuffixedPath() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        try store.trashItem(atRelativePath: entryRelPath)
        // Something new now occupies the original path.
        try FileManager.default.createDirectory(
            at: root.appendingRelativePath(entryRelPath), withIntermediateDirectories: true
        )

        let item = try #require(try store.items().first)
        let restoredPath = try store.restore(item)
        #expect(restoredPath == entryRelPath + "-2")
        #expect(FileManager.default.fileExists(atPath: root.appendingRelativePath(restoredPath).path))
    }

    @Test func purgeRemovesOnlyExpiredItems() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        let now = Date()
        let old = now.addingTimeInterval(-31 * 24 * 3600)
        try store.trashItem(atRelativePath: entryRelPath, deletedAt: old)

        // A fresh item that must survive.
        let freshRelPath = "transcride-2026-07-02T09-00-00"
        try FileManager.default.createDirectory(
            at: root.appendingRelativePath(freshRelPath), withIntermediateDirectories: true
        )
        try store.trashItem(atRelativePath: freshRelPath, deletedAt: now)

        let purged = try store.purge(olderThanDays: 30, now: now)
        #expect(purged == 1)
        let remaining = try store.items()
        #expect(remaining.count == 1)
        #expect(remaining[0].trashedName == freshRelPath)
    }

    @Test func itemWithoutSidecarStillListsAndRestoresToRoot() throws {
        let (root, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        // Orphan folder dropped into .trash by hand.
        let orphan = store.trashDirectory.appending(path: "orphan-folder")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let items = try store.items()
        let item = try #require(items.first(where: { $0.trashedName == "orphan-folder" }))
        #expect(item.originalPath == "orphan-folder")

        let restored = try store.restore(item)
        #expect(restored == "orphan-folder")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "orphan-folder").path))
    }
}
