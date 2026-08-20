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
            "---\ntitle: \"Meeting Notes\"\ncreated: 2026-07-01T10:00:00+00:00\nduration: 12.50\nfavorite: true\nsilence_detection: speech\n---\nDiscussed the roadmap.\n",
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
        #expect(doc.silenceDetectionMode == .speech)
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

    @Test func duplicatePreservesSpeechPreferenceAndStaleAlignmentState() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = "Journal/transcride-2026-07-01T10-00-00-meeting-notes"
        let source = root.appendingRelativePath(sourcePath)
        try TranscriptAlignmentState.markStale(inEntry: source)
        let newPath = try VaultOperations(vaultRoot: root).duplicateEntry(at: sourcePath)
        let duplicate = root.appendingRelativePath(newPath)
        #expect(TranscriptAlignmentState.isStale(inEntry: duplicate))
        let url = try #require(TranscriptFile.url(inEntry: duplicate))
        let doc = FrontmatterDocument.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(doc.silenceDetectionMode == .speech)
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

    // MARK: - Staging (D11)

    @Test func duplicateLeavesNothingStagedOnSuccess() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try VaultOperations(vaultRoot: root)
            .duplicateEntry(at: "Journal/transcride-2026-07-01T10-00-00-meeting-notes")
        let staging = root.appending(path: EntryStaging.directoryName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// A copy that dies partway must not leave a phantom entry in the library.
    @Test(.enabled(if: geteuid() != 0))
    func duplicateLeavesNoEntryWhenACopyFails() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = "Journal/transcride-2026-07-01T10-00-00-meeting-notes"
        let unreadable = root.appendingRelativePath(sourcePath).appending(path: "audio.m4a")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: unreadable.path
            )
        }

        #expect(throws: (any Error).self) {
            try VaultOperations(vaultRoot: root).duplicateEntry(at: sourcePath)
        }
        // Only the source entry exists, and nothing is left staged.
        let journal = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "Journal").path
        )
        #expect(journal == [sourcePath.lastComponent])
        let staging = root.appending(path: EntryStaging.directoryName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// An unreadable transcript is still copied faithfully — the duplicate
    /// just cannot be retitled, and is never stubbed over.
    @Test func duplicateOfAnUnreadableTranscriptCopiesItVerbatim() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = "transcride-2026-07-02T08-00-00"
        let entry = root.appending(path: sourcePath)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let bytes = Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x0A])
        try bytes.write(to: entry.appending(path: "transcript.md"))

        let newPath = try VaultOperations(vaultRoot: root).duplicateEntry(at: sourcePath)
        let copied = root.appendingRelativePath(newPath).appending(path: "transcript.md")
        #expect(try Data(contentsOf: copied) == bytes)
    }
}
