import Foundation
import Testing

@Suite("Vault scanning and operations")
struct VaultScannerTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default

        let entry1 = root.appending(path: "transcride-2026-07-01T10-00-00")
        try fm.createDirectory(at: entry1, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Root Entry\"\nduration: 12.5\n---\n# Heading\n\nHello from the root entry body.\n",
            to: entry1.appending(path: "transcript.md")
        )

        let entry2 = root.appending(path: "Journal/Ideas/transcride-2026-07-02T09-30-00-big-idea")
        try fm.createDirectory(at: entry2, withIntermediateDirectories: true)
        try AtomicFile.write("---\ntitle: \"Big Idea\"\n---\nNested entry body.\n",
                             to: entry2.appending(path: "transcript.md"))
        try AtomicFile.write(Data([0x00]), to: entry2.appending(path: "audio.m4a"))

        // Hidden folders and loose files must be ignored.
        try fm.createDirectory(at: root.appending(path: ".trash/whatever"), withIntermediateDirectories: true)
        try AtomicFile.write("term\n", to: root.appending(path: "vocabulary.txt"))
        return root
    }

    @Test func scanBuildsTreeAndEntries() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        var scanner = VaultScanner()
        let snapshot = scanner.scan(root: root)

        #expect(snapshot.root.entries.count == 1)
        #expect(snapshot.root.entries[0].title == "Root Entry")
        #expect(snapshot.root.entries[0].duration == 12.5)
        #expect(snapshot.root.entries[0].snippet.contains("Hello from the root entry body."))
        #expect(!snapshot.root.entries[0].hasAudio)

        let ideas = try #require(snapshot.folder(at: "Journal/Ideas"))
        #expect(ideas.entries.count == 1)
        #expect(ideas.entries[0].title == "Big Idea")
        #expect(ideas.entries[0].hasAudio)

        // .trash is not part of the tree.
        #expect(snapshot.folder(at: ".trash") == nil)
        #expect(snapshot.root.totalEntryCount == 2)
    }

    @Test func renameEntryUpdatesFrontmatterAndFolderName() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let newPath = try ops.renameEntry(
            at: "transcride-2026-07-01T10-00-00",
            toTitle: "Renamed: The Sequel!"
        )
        #expect(newPath == "transcride-2026-07-01T10-00-00-renamed-the-sequel")

        let text = try String(
            contentsOf: root.appendingRelativePath(newPath).appending(path: "transcript.md"),
            encoding: .utf8
        )
        let doc = FrontmatterDocument.parse(text)
        #expect(doc.title == "Renamed: The Sequel!")
        #expect(doc.body.contains("Hello from the root entry body."))
    }

    @Test func moveEntryBetweenFolders() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let created = try ops.createFolder(named: "Archive", inFolder: "")
        #expect(created == "Archive")

        let moved = try ops.moveItem(at: "transcride-2026-07-01T10-00-00", toFolder: "Archive")
        #expect(moved == "Archive/transcride-2026-07-01T10-00-00")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingRelativePath(moved).appending(path: "transcript.md").path
        ))

        var scanner = VaultScanner()
        let snapshot = scanner.scan(root: root)
        #expect(snapshot.root.entries.isEmpty)
        #expect(snapshot.folder(at: "Archive")?.entries.count == 1)
    }
}
