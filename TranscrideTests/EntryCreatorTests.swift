import Foundation
import Testing

@Suite("Entry creation from record/import paths")
struct EntryCreatorTests {
    private func makeVaultRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-create-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let date = EntryFolderName.date(fromTimestamp: "2026-07-08T10-00-00")!

    @Test func recordingPathCreatesFolderAndStub() throws {
        let root = try makeVaultRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let creator = EntryCreator(vaultRoot: root)

        let relPath = try creator.createEntryFolder(inFolder: "", date: date)
        #expect(relPath == "transcride-2026-07-08T10-00-00")
        let entryURL = root.appendingRelativePath(relPath)
        try EntryCreator.writeRecordingStub(entryURL: entryURL, created: date, duration: 42.5)

        let text = try String(
            contentsOf: entryURL.appending(path: TranscriptFile.defaultName), encoding: .utf8
        )
        let doc = FrontmatterDocument.parse(text)
        #expect(doc.title == "New Recording")
        #expect(doc.created == date)
        #expect(doc.duration == 42.5)
        #expect(doc.source == "recorded")
        #expect(doc.body.isEmpty)
    }

    @Test func timestampCollisionAdvancesOneSecond() throws {
        let root = try makeVaultRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let creator = EntryCreator(vaultRoot: root)

        let first = try creator.createEntryFolder(inFolder: "Journal", date: date)
        let second = try creator.createEntryFolder(inFolder: "Journal", date: date)
        #expect(first == "Journal/transcride-2026-07-08T10-00-00")
        #expect(second == "Journal/transcride-2026-07-08T10-00-01")
    }

    @Test func importPathCopiesFileWritesStubAndScansBack() throws {
        let root = try makeVaultRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let creator = EntryCreator(vaultRoot: root)

        let sourceDir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceURL = sourceDir.appending(path: "My Meeting Notes.wav")
        let sourceBytes = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03])
        try sourceBytes.write(to: sourceURL)

        let relPath = try creator.importFile(
            from: sourceURL, toFolder: "", date: date, duration: 12.25
        )
        #expect(relPath == "transcride-2026-07-08T10-00-00-my-meeting-notes")

        // Original untouched, copy byte-identical with original name/extension.
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        let entryURL = root.appendingRelativePath(relPath)
        let copied = entryURL.appending(path: "My Meeting Notes.wav")
        #expect(try Data(contentsOf: copied) == sourceBytes)

        // Stub follows the titled-transcript contract: <Title>.md.
        let transcriptURL = entryURL.appending(path: "My Meeting Notes.md")
        let doc = FrontmatterDocument.parse(try String(contentsOf: transcriptURL, encoding: .utf8))
        #expect(doc.title == "My Meeting Notes")
        #expect(doc.duration == 12.25)
        #expect(doc.source == "imported")
        #expect(doc.body.isEmpty)

        // The scanner sees a complete entry.
        var scanner = VaultScanner()
        let snapshot = scanner.scan(root: root)
        let entry = try #require(snapshot.entry(withID: relPath))
        #expect(entry.title == "My Meeting Notes")
        #expect(entry.audioFileName == "My Meeting Notes.wav")
        #expect(entry.duration == 12.25)
    }

    @Test func scannerPrefersCanonicalAudioAndIgnoresHiddenFiles() throws {
        let root = try makeVaultRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // In-progress recording: only a hidden partial file → no audio yet.
        let recording = root.appending(path: "transcride-2026-07-08T11-00-00")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data([0x00]).write(to: recording.appending(path: ".recording.caf"))

        // Finalized entry with an extra audio file: audio.m4a wins.
        let finalized = root.appending(path: "transcride-2026-07-08T12-00-00")
        try FileManager.default.createDirectory(at: finalized, withIntermediateDirectories: true)
        try Data([0x00]).write(to: finalized.appending(path: "audio.m4a"))
        try Data([0x00]).write(to: finalized.appending(path: "ambient.mp3"))

        var scanner = VaultScanner()
        let snapshot = scanner.scan(root: root)
        let inProgress = try #require(snapshot.entry(withID: "transcride-2026-07-08T11-00-00"))
        #expect(!inProgress.hasAudio)
        let done = try #require(snapshot.entry(withID: "transcride-2026-07-08T12-00-00"))
        #expect(done.audioFileName == "audio.m4a")
    }
}
