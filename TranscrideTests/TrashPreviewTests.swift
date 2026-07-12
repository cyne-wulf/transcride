import Foundation
import Testing

@Suite("Recently Deleted previews")
struct TrashPreviewTests {
    private func makeVault(
        transcriptData: Data? = Data("---\ntitle: Preview Note\ncreated: 2026-07-01T10:00:00Z\nduration: 4.0\n---\nDeleted body.\n".utf8)
    ) throws -> (root: URL, entryPath: RelativePath) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entryPath = "Journal/transcride-2026-07-01T10-00-00-preview-note"
        let entryURL = root.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        if let transcriptData {
            try transcriptData.write(to: entryURL.appending(path: "transcript.md"))
        }
        try Data("audio".utf8).write(to: entryURL.appending(path: "audio.m4a"))
        try WaveformData(duration: 4, peaks: [0.2, 0.8, 0.4])
            .write(to: WaveformData.url(inEntry: entryURL))
        return (root, entryPath)
    }

    @Test func completeDeletedEntryIncludesItsOwnTranscriptAndAudio() async throws {
        let (root, entryPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        try store.trashItem(atRelativePath: entryPath)
        let item = try #require(try store.items().first)

        let preview = await TrashPreviewResolver(vaultRoot: root).resolve(item)

        #expect(preview.kind == .entry)
        #expect(preview.title == "Preview Note")
        #expect(preview.document?.body.contains("Deleted body.") == true)
        #expect(preview.audioURL?.path.contains("/.trash/") == true)
        #expect(preview.waveform?.duration == 4)
    }

    @Test func deletedAudioIncludesNoLiveTranscript() async throws {
        let (root, entryPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        try store.trashEntryAudio(atEntryPath: entryPath)
        let item = try #require(try store.items().first)

        let preview = await TrashPreviewResolver(vaultRoot: root).resolve(item)

        #expect(preview.kind == .audio)
        #expect(preview.document == nil)
        #expect(preview.original == nil)
        #expect(preview.audioURL != nil)
        #expect(preview.waveform?.duration == 4)
    }

    @Test func everyPriorAudioVersionResolvesAsAudioOnly() async throws {
        for kind in [
            TrashItemKind.preTrimAudio,
            .preExtensionAudio,
            .preCompressionAudio,
            .preReplacementAudio,
        ] {
            let (root, entryPath) = try makeVault()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TrashStore(vaultRoot: root)
            switch kind {
            case .preTrimAudio:
                try store.trashPreTrimAudio(atEntryPath: entryPath)
            case .preExtensionAudio:
                try store.trashPreExtensionAudio(atEntryPath: entryPath)
            case .preCompressionAudio:
                try store.trashPreCompressionAudio(atEntryPath: entryPath)
            case .preReplacementAudio:
                try store.trashPreReplacementAudio(atEntryPath: entryPath)
            default:
                Issue.record("Unexpected test kind")
            }
            let item = try #require(try store.items().first)
            let preview = await TrashPreviewResolver(vaultRoot: root).resolve(item)
            #expect(preview.kind == .audio)
            #expect(preview.document == nil)
            #expect(preview.audioURL != nil)
        }
    }

    @Test func folderGetsSummaryInsteadOfClipControls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Old Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: folder.appending(path: "note.txt"))
        let store = TrashStore(vaultRoot: root)
        try store.trashItem(atRelativePath: "Old Folder")
        let item = try #require(try store.items().first)

        let preview = await TrashPreviewResolver(vaultRoot: root).resolve(item)

        #expect(preview.kind == .folder)
        #expect(preview.audioURL == nil)
        #expect(preview.summary?.contains("1 item") == true)
    }

    @Test func missingAndUnreadablePayloadsFailGracefully() async throws {
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        let (root, entryPath) = try makeVault(transcriptData: invalidUTF8)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        try store.trashItem(atRelativePath: entryPath)
        let item = try #require(try store.items().first)

        let unreadable = await TrashPreviewResolver(vaultRoot: root).resolve(item)
        #expect(unreadable.kind == .entry)
        #expect(unreadable.document == nil)
        #expect(unreadable.transcriptUnavailableReason != nil)

        try FileManager.default.removeItem(
            at: store.trashDirectory.appending(path: item.trashedName)
        )
        let missing = await TrashPreviewResolver(vaultRoot: root).resolve(item)
        #expect(missing.kind == .unavailable)
        #expect(missing.audioURL == nil)
    }
}
