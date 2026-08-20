import Foundation
import Testing

@Suite("Atomic file writes")
struct AtomicFileTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcride-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesNewFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        try AtomicFile.write("hello world", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
    }

    @Test func overwritesExistingFileAtomically() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        try AtomicFile.write("version 1", to: target)
        try AtomicFile.write("version 2 — much longer content than before", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "version 2 — much longer content than before")
    }

    @Test func leavesNoTempFilesBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        for i in 0..<10 {
            try AtomicFile.write("content \(i)", to: target)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["note.md"])
    }

    @Test func failsCleanlyWhenDirectoryMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "missing-subdir/note.md")
        #expect(throws: (any Error).self) {
            try AtomicFile.write("data", to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func binaryDataRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "blob.bin")
        let data = Data((0..<255).map { UInt8($0) })
        try AtomicFile.write(data, to: target)
        #expect(try Data(contentsOf: target) == data)
    }

    // MARK: - Durability (D9)

    @Test func fullDurabilityRoundTripsAndLeavesNoTemps() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        try AtomicFile.write("first", to: target, durability: .full)
        try AtomicFile.write("second, longer", to: target, durability: .full)
        #expect(try String(contentsOf: target, encoding: .utf8) == "second, longer")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["note.md"])
    }

    @Test func fullDurabilityFailsCleanlyWhenDirectoryMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "missing-subdir/note.md")
        #expect(throws: (any Error).self) {
            try AtomicFile.write("data", to: target, durability: .full)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    // MARK: - Publishing files produced elsewhere

    @Test func installReplacesAnExistingDestinationAndConsumesTheSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appending(path: ".audio.m4a.installing")
        let destination = dir.appending(path: "audio.m4a")
        try AtomicFile.write("new bytes", to: staged)
        try AtomicFile.write("old bytes", to: destination)

        try AtomicFile.install(fileAt: staged, to: destination, durability: .full)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new bytes")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func exchangeSwapsContentsOfBothPaths() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appending(path: ".audio.m4a.installing")
        let visible = dir.appending(path: "audio.m4a")
        try AtomicFile.write("new bytes", to: staged)
        try AtomicFile.write("old bytes", to: visible)

        // False would mean this file system has no RENAME_SWAP and the callers
        // fell back to the two-rename path; on APFS it must be available.
        #expect(try AtomicFile.exchange(staged, visible))
        #expect(try String(contentsOf: visible, encoding: .utf8) == "new bytes")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "old bytes")
    }

    @Test func exchangeThrowsWhenEitherPathIsMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appending(path: "audio.m4a")
        try AtomicFile.write("bytes", to: present)

        #expect(throws: (any Error).self) {
            _ = try AtomicFile.exchange(present, dir.appending(path: "missing.m4a"))
        }
        // The surviving file is untouched.
        #expect(try String(contentsOf: present, encoding: .utf8) == "bytes")
    }

    @Test func renameItemOverwritesWhereMoveItemWouldFail() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "source")
        let destination = dir.appending(path: "destination")
        try AtomicFile.write("source", to: source)
        try AtomicFile.write("destination", to: destination)

        #expect(throws: (any Error).self) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try AtomicFile.renameItem(source, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "source")
    }
}

/// The read-else-stub trap: a transcript that exists but cannot be read must
/// never be replaced by a fabricated one (D5).
@Suite("Entry frontmatter updates")
struct EntryFrontmatterTests {
    /// Bytes that are not valid UTF-8, so the file exists but cannot be read.
    private static let undecodableBytes = Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x0A])

    private func makeEntry(withTranscript contents: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcride-fm-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "transcride-2026-07-01T10-00-00-notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let contents {
            try AtomicFile.write(contents, to: url.appending(path: "transcript.md"))
        }
        return url
    }

    private func remove(_ entryURL: URL) {
        try? FileManager.default.removeItem(at: entryURL.deletingLastPathComponent())
    }

    @Test func readParsesAnExistingTranscript() throws {
        let entry = try makeEntry(withTranscript: "---\ntitle: \"Notes\"\n---\nBody.\n")
        defer { remove(entry) }

        let slot = try EntryFrontmatter.read(inEntry: entry)
        #expect(slot.url.lastPathComponent == "transcript.md")
        #expect(slot.document?.title == "Notes")
    }

    @Test func readReportsMissingWhenTheEntryHasNoMarkdown() throws {
        let entry = try makeEntry()
        defer { remove(entry) }

        let slot = try EntryFrontmatter.read(inEntry: entry)
        #expect(slot.document == nil)
        #expect(slot.url.lastPathComponent == "transcript.md")
    }

    @Test func readThrowsWhenTheEntryFolderIsGone() throws {
        let entry = try makeEntry()
        remove(entry)

        #expect(throws: VaultError.notFound("transcride-2026-07-01T10-00-00-notes")) {
            try EntryFrontmatter.read(inEntry: entry)
        }
    }

    @Test func readThrowsForAnUndecodableTranscript() throws {
        let entry = try makeEntry()
        defer { remove(entry) }
        try Self.undecodableBytes.write(to: entry.appending(path: "transcript.md"))

        #expect(throws: VaultError.unreadableTranscript("transcript.md")) {
            try EntryFrontmatter.read(inEntry: entry)
        }
    }

    /// The heart of D5: the toggle fails, the note survives byte-for-byte.
    @Test func updateNeverStubsOverAnUnreadableTranscript() throws {
        let entry = try makeEntry()
        defer { remove(entry) }
        let transcript = entry.appending(path: "transcript.md")
        try Self.undecodableBytes.write(to: transcript)

        #expect(throws: VaultError.unreadableTranscript("transcript.md")) {
            try EntryFrontmatter.update(inEntry: entry) { $0.favorite = true }
        }
        #expect(try Data(contentsOf: transcript) == Self.undecodableBytes)
    }

    @Test func updateCreatesASeededStubWhenTheTranscriptIsAbsent() throws {
        let entry = try makeEntry()
        defer { remove(entry) }

        let result = try EntryFrontmatter.update(inEntry: entry) { $0.favorite = true }
        #expect(result.wrote)
        #expect(result.document.favorite)
        // `created` is seeded from the entry folder's timestamp.
        #expect(result.document.created == EntryFolderName(
            parsing: "transcride-2026-07-01T10-00-00-notes"
        )?.date)
        let doc = FrontmatterDocument.parse(
            try String(contentsOf: entry.appending(path: "transcript.md"), encoding: .utf8)
        )
        #expect(doc.favorite)
    }

    @Test func updateWritesNothingWhenTheTranscriptIsAbsentAndCreationIsOff() throws {
        let entry = try makeEntry()
        defer { remove(entry) }

        let result = try EntryFrontmatter.update(inEntry: entry, createIfMissing: false) {
            $0.favorite = true
        }
        #expect(!result.wrote)
        #expect(try FileManager.default.contentsOfDirectory(atPath: entry.path).isEmpty)
    }

    @Test func updateSkipsTheWriteWhenNothingChanged() throws {
        let contents = "---\ntitle: \"Notes\"\nfavorite: true\n---\nBody.\n"
        let entry = try makeEntry(withTranscript: contents)
        defer { remove(entry) }
        let transcript = entry.appending(path: "transcript.md")
        let before = try FileManager.default.attributesOfItem(atPath: transcript.path)[.modificationDate] as? Date

        let result = try EntryFrontmatter.update(inEntry: entry) { $0.favorite = true }
        #expect(!result.wrote)
        #expect(result.document.favorite)
        #expect(try String(contentsOf: transcript, encoding: .utf8) == contents)
        let after = try FileManager.default.attributesOfItem(atPath: transcript.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func updatePreservesUnknownFieldsAndBody() throws {
        let entry = try makeEntry(
            withTranscript: "---\ntitle: \"Notes\"\nobsidian_tag: keep-me\n---\nBody text.\n"
        )
        defer { remove(entry) }

        try EntryFrontmatter.update(inEntry: entry) { $0.favorite = true }
        let text = try String(
            contentsOf: entry.appending(path: "transcript.md"), encoding: .utf8
        )
        #expect(text.contains("obsidian_tag: keep-me"))
        #expect(text.contains("Body text."))
        #expect(FrontmatterDocument.parse(text).favorite)
    }

    /// A metadata write that would rewrite the note is a caller bug, refused
    /// before it reaches the disk.
    @Test func updateRefusesToReplaceTheBody() throws {
        let contents = "---\ntitle: \"Notes\"\n---\nOriginal body.\n"
        let entry = try makeEntry(withTranscript: contents)
        defer { remove(entry) }

        #expect(throws: VaultError.metadataWriteWouldReplaceBody("transcript.md")) {
            try EntryFrontmatter.update(inEntry: entry) { doc in
                doc.favorite = true
                doc.body = "Clobbered."
            }
        }
        #expect(try String(
            contentsOf: entry.appending(path: "transcript.md"), encoding: .utf8
        ) == contents)
    }

    @Test func updateFindsARetitledTranscriptFile() throws {
        let entry = try makeEntry()
        defer { remove(entry) }
        try AtomicFile.write(
            "---\ntitle: \"Field Notes\"\n---\nBody.\n",
            to: entry.appending(path: "Field Notes.md")
        )

        let result = try EntryFrontmatter.update(inEntry: entry) { $0.favorite = true }
        #expect(result.url.lastPathComponent == "Field Notes.md")
        // No stub was created alongside it.
        #expect(!FileManager.default.fileExists(
            atPath: entry.appending(path: "transcript.md").path
        ))
    }
}
