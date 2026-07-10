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

    // MARK: - Delete audio, keep transcript (AUD-1/AUD-2)

    /// Adds an audio file and waveform cache to the fixture entry.
    private func addAudio(toEntryAt entryRelPath: String, inVault root: URL) throws {
        let entryURL = root.appendingRelativePath(entryRelPath)
        try Data("fake-aac-bytes".utf8).write(to: entryURL.appending(path: "audio.m4a"))
        try Data("{\"version\":1}".utf8).write(to: entryURL.appending(path: "waveform.json"))
    }

    private func transcriptText(ofEntryAt entryRelPath: String, inVault root: URL) throws -> String {
        let url = try #require(TranscriptFile.url(inEntry: root.appendingRelativePath(entryRelPath)))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func deleteAudioMovesFilesWritesSidecarAndSetsFlag() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try addAudio(toEntryAt: entryRelPath, inVault: root)
        let store = TrashStore(vaultRoot: root)

        let trashedName = try store.trashEntryAudio(atEntryPath: entryRelPath)

        // Audio and waveform left the entry; the transcript stayed.
        let entryURL = root.appendingRelativePath(entryRelPath)
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(path: "audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(path: "waveform.json").path))
        #expect(FileManager.default.fileExists(atPath: entryURL.appending(path: "transcript.md").path))

        // Both files sit in one wrapper item in the trash.
        let wrapper = store.trashDirectory.appending(path: trashedName)
        #expect(FileManager.default.fileExists(atPath: wrapper.appending(path: "audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: wrapper.appending(path: "waveform.json").path))

        let info = try #require(store.readInfo(forTrashedName: trashedName))
        #expect(info.kind == .entryAudio)
        #expect(info.originalPath == entryRelPath)

        // Frontmatter records the state; the scanner reads it from here.
        let doc = FrontmatterDocument.parse(try transcriptText(ofEntryAt: entryRelPath, inVault: root))
        #expect(doc.audioDeleted)

        let item = try #require(try store.items().first)
        #expect(item.kind == .entryAudio)
        #expect(!item.isEntry)
        #expect(item.displayName == "Audio — Test Note")
    }

    @Test func restoreAudioFullyReversesTheDeletion() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try addAudio(toEntryAt: entryRelPath, inVault: root)
        let store = TrashStore(vaultRoot: root)

        try store.trashEntryAudio(atEntryPath: entryRelPath)
        let item = try #require(try store.items().first)
        let restoredPath = try store.restore(item)

        #expect(restoredPath == entryRelPath)
        let entryURL = root.appendingRelativePath(entryRelPath)
        #expect(FileManager.default.fileExists(atPath: entryURL.appending(path: "audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: entryURL.appending(path: "waveform.json").path))
        #expect(try store.items().isEmpty)

        // The flag is cleared by removing the key, not by writing `false`.
        let text = try transcriptText(ofEntryAt: entryRelPath, inVault: root)
        #expect(!text.contains("audio_deleted"))
        #expect(!FrontmatterDocument.parse(text).audioDeleted)
    }

    @Test func restoreAudioCollisionSuffixesAudioAndDropsStaleWaveform() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try addAudio(toEntryAt: entryRelPath, inVault: root)
        let store = TrashStore(vaultRoot: root)

        try store.trashEntryAudio(atEntryPath: entryRelPath)
        // The entry re-acquired audio (e.g. copied in externally) meanwhile.
        try addAudio(toEntryAt: entryRelPath, inVault: root)

        let item = try #require(try store.items().first)
        _ = try store.restore(item)

        let entryURL = root.appendingRelativePath(entryRelPath)
        #expect(FileManager.default.fileExists(atPath: entryURL.appending(path: "audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: entryURL.appending(path: "audio-2.m4a").path))
        // Exactly one waveform cache: the trashed copy was stale and dropped.
        let names = try FileManager.default.contentsOfDirectory(atPath: entryURL.path)
        #expect(names.filter { $0 == "waveform.json" }.count == 1)
        #expect(try store.items().isEmpty)
    }

    @Test func deleteAudioWithoutTranscriptCreatesFlaggedStub() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryRelPath = "transcride-2026-07-01T10-00-00"
        try FileManager.default.createDirectory(
            at: root.appendingRelativePath(entryRelPath), withIntermediateDirectories: true
        )
        try addAudio(toEntryAt: entryRelPath, inVault: root)
        let store = TrashStore(vaultRoot: root)

        try store.trashEntryAudio(atEntryPath: entryRelPath)

        let doc = FrontmatterDocument.parse(try transcriptText(ofEntryAt: entryRelPath, inVault: root))
        #expect(doc.audioDeleted)
        #expect(doc.created != nil)
    }

    @Test func deleteAudioWithNoAudioFileThrowsNotFound() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        #expect(throws: VaultError.self) {
            try store.trashEntryAudio(atEntryPath: entryRelPath)
        }
    }

    @Test func purgeCoversAudioOnlyItems() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try addAudio(toEntryAt: entryRelPath, inVault: root)
        let store = TrashStore(vaultRoot: root)

        let old = Date().addingTimeInterval(-31 * 24 * 3600)
        let trashedName = try store.trashEntryAudio(atEntryPath: entryRelPath, deletedAt: old)

        let purged = try store.purge(olderThanDays: 30, now: Date())
        #expect(purged == 1)
        #expect(try store.items().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: store.trashDirectory.appending(path: trashedName).path
        ))
    }

    @Test func legacySidecarWithoutKindListsAsPlainItem() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)

        let trashedName = try store.trashItem(atRelativePath: entryRelPath)
        // Rewrite the sidecar in the M1 shape (no `kind` key).
        let legacy = """
        {"deletedAt":"2026-07-01T10:00:00Z","originalPath":"\(entryRelPath)"}
        """
        try Data(legacy.utf8).write(to: store.sidecarURL(forTrashedName: trashedName))

        let item = try #require(try store.items().first)
        #expect(item.kind == .item)
        #expect(item.isEntry)
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
