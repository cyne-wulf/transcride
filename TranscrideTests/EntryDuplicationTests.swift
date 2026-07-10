import Foundation
import Testing

@Suite("Duplicate entry")
struct EntryDuplicationTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-dup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default

        let entry = root.appending(path: "Journal/transcride-2026-07-01T10-00-00-meeting-notes")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Meeting Notes\"\ncreated: 2026-07-01T10:00:00+00:00\nduration: 12.50\nfavorite: true\n---\nDiscussed the roadmap.\n",
            to: entry.appending(path: "Meeting Notes.md")
        )
        try AtomicFile.write(Data([0x01, 0x02]), to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("{}", to: entry.appending(path: "waveform.json"))
        try AtomicFile.write("{\"schema\": 1}", to: entry.appending(path: "transcript.original.json"))
        try AtomicFile.write("{\"schema\": 1}", to: entry.appending(path: "transcript.original.2026-07-01-090000.json"))
        // Hidden files must not travel with the copy.
        try AtomicFile.write("tmp", to: entry.appending(path: ".hidden-temp"))
        return root
    }

    @Test func duplicateCopiesEverythingUnderANewTimestampAndTitle() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)
        let sourcePath = "Journal/transcride-2026-07-01T10-00-00-meeting-notes"

        let date = Date(timeIntervalSince1970: 1_781_000_000) // 2026-06-09-ish
        let newPath = try ops.duplicateEntry(at: sourcePath, date: date)

        #expect(newPath != sourcePath)
        #expect(newPath.hasPrefix("Journal/transcride-"))
        #expect(newPath.hasSuffix("-meeting-notes-copy"))
        let folderName = try #require(EntryFolderName(parsing: newPath.lastComponent))
        #expect(folderName.timestamp == EntryFolderName.timestamp(from: date))

        let dest = root.appendingRelativePath(newPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        #expect(names == [
            "Meeting Notes copy.md",
            "audio.m4a",
            "transcript.original.2026-07-01-090000.json",
            "transcript.original.json",
            "waveform.json",
        ])

        let doc = FrontmatterDocument.parse(
            try String(contentsOf: dest.appending(path: "Meeting Notes copy.md"), encoding: .utf8)
        )
        #expect(doc.title == "Meeting Notes copy")
        #expect(doc.created == date)
        #expect(doc.duration == 12.5)
        #expect(doc.favorite == true)
        #expect(doc.body == "Discussed the roadmap.\n")
    }

    @Test func copyIsIndependentOfTheSource() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)
        let sourcePath = "Journal/transcride-2026-07-01T10-00-00-meeting-notes"
        let newPath = try ops.duplicateEntry(at: sourcePath)

        // Editing the copy's transcript leaves the source byte-identical.
        let sourceMD = root.appendingRelativePath(sourcePath).appending(path: "Meeting Notes.md")
        let before = try String(contentsOf: sourceMD, encoding: .utf8)
        let copyMD = root.appendingRelativePath(newPath).appending(path: "Meeting Notes copy.md")
        try AtomicFile.write("---\ntitle: \"Meeting Notes copy\"\n---\nRewritten.\n", to: copyMD)
        #expect(try String(contentsOf: sourceMD, encoding: .utf8) == before)
    }

    @Test func duplicatingTwiceInTheSameSecondAdvancesTheTimestamp() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)
        let sourcePath = "Journal/transcride-2026-07-01T10-00-00-meeting-notes"

        let date = Date(timeIntervalSince1970: 1_781_000_000)
        let first = try ops.duplicateEntry(at: sourcePath, date: date)
        let second = try ops.duplicateEntry(at: sourcePath, date: date)
        #expect(first != second)
    }

    @Test func untitledSourceStaysUntitled() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let entry = root.appending(path: "transcride-2026-07-02T08-00-00")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write("---\ncreated: 2026-07-02T08:00:00+00:00\n---\nBody only.\n",
                             to: entry.appending(path: "transcript.md"))

        let newPath = try VaultOperations(vaultRoot: root)
            .duplicateEntry(at: "transcride-2026-07-02T08-00-00")
        let folderName = try #require(EntryFolderName(parsing: newPath.lastComponent))
        #expect(folderName.slug == nil)
        let dest = root.appendingRelativePath(newPath)
        let doc = FrontmatterDocument.parse(
            try String(contentsOf: dest.appending(path: "transcript.md"), encoding: .utf8)
        )
        #expect(doc.title == nil)
        #expect(doc.body == "Body only.\n")
    }

    @Test func duplicatingAMissingEntryThrows() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: VaultError.self) {
            try VaultOperations(vaultRoot: root)
                .duplicateEntry(at: "transcride-2099-01-01T00-00-00")
        }
    }
}
