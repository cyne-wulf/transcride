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
            "---\ntitle: \"Root Entry\"\nduration: 12.5\nsilence_detection: speech\n---\n# Heading\n\nHello from the root entry body.\n",
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
        #expect(snapshot.root.entries[0].silenceDetectionMode == .speech)
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

    @Test func renameEntryUpdatesFrontmatterFolderAndFileName() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let newPath = try ops.renameEntry(
            at: "transcride-2026-07-01T10-00-00",
            toTitle: "Renamed: The Sequel!"
        )
        #expect(newPath == "transcride-2026-07-01T10-00-00-renamed-the-sequel")

        // The transcript file itself is renamed to the (sanitized) title.
        let entryURL = root.appendingRelativePath(newPath)
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(path: "transcript.md").path))
        let text = try String(
            contentsOf: entryURL.appending(path: "Renamed- The Sequel!.md"),
            encoding: .utf8
        )
        let doc = FrontmatterDocument.parse(text)
        #expect(doc.title == "Renamed: The Sequel!")
        #expect(doc.silenceDetectionMode == .speech)
        #expect(doc.body.contains("Hello from the root entry body."))

        // A second rename finds the retitled file and renames it again.
        let finalPath = try ops.renameEntry(at: newPath, toTitle: "Third Name")
        let finalURL = root.appendingRelativePath(finalPath)
        let doc2 = FrontmatterDocument.parse(try String(
            contentsOf: finalURL.appending(path: "Third Name.md"), encoding: .utf8
        ))
        #expect(doc2.title == "Third Name")
        #expect(doc2.silenceDetectionMode == .speech)
        #expect(doc2.body.contains("Hello from the root entry body."))
    }

    @Test func scannerDiscoversCustomNamedTranscript() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appending(path: "transcride-2026-07-03T08-00-00")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Hand Named\"\n---\nBody here.\n",
            to: entry.appending(path: "My Own Name.md")
        )

        var scanner = VaultScanner()
        let snapshot = scanner.scan(root: root)
        let found = try #require(snapshot.root.entries.first {
            $0.relativePath == "transcride-2026-07-03T08-00-00"
        })
        #expect(found.title == "Hand Named")
        #expect(found.transcriptFileName == "My Own Name.md")
        #expect(found.snippet.contains("Body here."))
    }

    // MARK: - Speech availability caching

    private struct AvailabilityFixture {
        var root: URL
        var entry: URL
        var cache: URL
        var relativePath: RelativePath
    }

    /// One entry with word-timed original transcript and a duration, i.e. the
    /// only shape whose availability answer costs a JSON decode.
    private func makeAvailabilityVault(duration: Double? = 6.0) throws -> AvailabilityFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-avail-\(UUID().uuidString)", directoryHint: .isDirectory)
        let relativePath = "transcride-2026-07-05T12-00-00-speech"
        let entry = root.appendingRelativePath(relativePath)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let durationLine = duration.map { "duration: \($0)\n" } ?? ""
        try AtomicFile.write(
            "---\ntitle: \"Speech\"\n\(durationLine)---\nBody.\n",
            to: entry.appending(path: "transcript.md")
        )
        let words = (0..<5).map {
            TranscriptOriginal.Word(text: "word\($0)", start: Double($0), end: Double($0) + 0.5)
        }
        let transcript = TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: 0, end: 4.5, words: words)]
        )
        try transcript.write(to: TranscriptOriginal.url(inEntry: entry))
        return AvailabilityFixture(
            root: root,
            entry: entry,
            cache: root.appending(path: "cache/availability.json"),
            relativePath: relativePath
        )
    }

    private func availability(
        in fixture: AvailabilityFixture, cacheURL: URL? = nil
    ) -> SpeechTranscriptAvailability? {
        var scanner = VaultScanner(availabilityCacheURL: cacheURL ?? fixture.cache)
        return scanner.scan(root: fixture.root).allEntries
            .first { $0.relativePath == fixture.relativePath }?
            .speechTranscriptAvailability
    }

    /// A filesystem modification date is nanosecond-precise and does not
    /// survive a `Date` round trip, so identity-preserving edits pin both
    /// writes to the same coarse instant rather than restoring the old one.
    private static let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func pinTranscriptDate(in fixture: AvailabilityFixture) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Self.pinnedDate],
            ofItemAtPath: TranscriptOriginal.url(inEntry: fixture.entry).path
        )
    }

    /// Replaces the transcript's bytes while keeping the size and modification
    /// date the cache recorded, so a cache hit and a re-decode give visibly
    /// different answers. The transcript must have been pinned before scanning.
    private func corruptTranscriptPreservingIdentity(in fixture: AvailabilityFixture) throws {
        let url = TranscriptOriginal.url(inEntry: fixture.entry)
        let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try Data(repeating: 0x7A, count: size).write(to: url)
        try pinTranscriptDate(in: fixture)
    }

    @Test func speechAvailabilityIsReusedByALaterScannerInstance() throws {
        let f = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try pinTranscriptDate(in: f)
        #expect(availability(in: f) == .available)

        // A fresh scanner is what every launch starts with; the persisted
        // answer must survive it without re-reading the transcript.
        try corruptTranscriptPreservingIdentity(in: f)
        #expect(availability(in: f) == .available)

        // Touching the file invalidates the key and forces the real answer.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: TranscriptOriginal.url(inEntry: f.entry).path
        )
        #expect(availability(in: f) == .missing)
    }

    @Test func availabilityCacheInvalidatesOnSizeAndDurationChanges() throws {
        let f = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try pinTranscriptDate(in: f)
        #expect(availability(in: f) == .available)

        // Same modification date, different size.
        try Data(repeating: 0x7A, count: 11).write(to: TranscriptOriginal.url(inEntry: f.entry))
        try pinTranscriptDate(in: f)
        #expect(availability(in: f) == .missing)

        // A duration change alone must also re-decide: the words are validated
        // against it, so the same transcript can flip answers.
        let g = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: g.root) }
        #expect(availability(in: g) == .available)
        try AtomicFile.write(
            "---\ntitle: \"Speech\"\nduration: 0.5\n---\nBody.\n",
            to: g.entry.appending(path: "transcript.md")
        )
        #expect(availability(in: g) == .malformed)
    }

    @Test func unreadableAvailabilityCacheIsIgnoredAndRewritten() throws {
        let f = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(
            at: f.cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json at all".utf8).write(to: f.cache)

        #expect(availability(in: f) == .available)
        // The scan healed the file rather than leaving the garbage in place.
        #expect(availability(in: f) == .available)
        let rewritten = try #require(try? Data(contentsOf: f.cache))
        #expect(rewritten != Data("not json at all".utf8))
    }

    @Test func staleAlignmentAndAbsentTranscriptNeverDecode() throws {
        // A corrupt transcript that is never read still yields the metadata
        // answer, which is only possible if no decode was attempted.
        let stale = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: stale.root) }
        try Data(repeating: 0x7A, count: 64).write(to: TranscriptOriginal.url(inEntry: stale.entry))
        try TranscriptAlignmentState.markStale(inEntry: stale.entry)
        #expect(availability(in: stale) == .stale)

        let absent = try makeAvailabilityVault()
        defer { try? FileManager.default.removeItem(at: absent.root) }
        try FileManager.default.removeItem(at: TranscriptOriginal.url(inEntry: absent.entry))
        #expect(availability(in: absent) == .missing)
    }

    @Test func availabilityAnswersMatchAnUncachedScan() throws {
        // Every availability outcome, resolved with a cold cache and again
        // with a warm one; the cache must never change the answer.
        for duration in [6.0, 0.5] {
            let f = try makeAvailabilityVault(duration: duration)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let cold = availability(in: f, cacheURL: f.root.appending(path: "cold.json"))
            let warm = availability(in: f)
            let rewarm = availability(in: f)
            #expect(cold == warm)
            #expect(warm == rewarm)
        }
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
        #expect(snapshot.folder(at: "Archive")?.entries[0].silenceDetectionMode == .speech)
    }
}
