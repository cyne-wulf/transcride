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

    // MARK: - Generated waveform cache

    /// An entry holding real audio and *no* `waveform.json`, so previewing it
    /// has to decode the file.
    private func makeVaultNeedingWaveform(
        seconds: Double = 1.0, amplitude: Float = 0.5
    ) throws -> (root: URL, entryPath: RelativePath) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entryPath = "Journal/transcride-2026-07-01T10-00-00-preview-note"
        let entryURL = root.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try Data("---\ntitle: Preview Note\n---\nBody.\n".utf8)
            .write(to: entryURL.appending(path: "transcript.md"))
        let source = try TestAudio.makeWAV(seconds: seconds, amplitude: amplitude)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: source, to: entryURL.appending(path: "audio.wav"))
        return (root, entryPath)
    }

    @Test func generatedWaveformIsReusedForRepeatedSelections() async throws {
        let (root, entryPath) = try makeVaultNeedingWaveform()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        try store.trashItem(atRelativePath: entryPath)
        let item = try #require(try store.items().first)
        let cache = TrashWaveformCache()
        let resolver = TrashPreviewResolver(vaultRoot: root, waveformCache: cache)

        let first = await resolver.resolve(item)
        #expect(first.waveform != nil)
        #expect(await cache.count == 1)

        let second = await resolver.resolve(item)
        #expect(second.waveform == first.waveform)
        #expect(await cache.count == 1)

        // Prove the second pass really read the cache rather than decoding to
        // the same answer: a sentinel stored under the audio's key comes back.
        let trashedAudioURL = try #require(first.audioURL)
        let key = try #require(TrashWaveformCache.Key(audioAt: trashedAudioURL))
        await cache.store(WaveformData(duration: 99, peaks: [0.42]), for: key)
        let third = await resolver.resolve(item)
        #expect(third.waveform?.duration == 99)
        #expect(third.duration == 99)
    }

    @Test func changedAudioIsNotServedFromTheCache() async throws {
        let (root, entryPath) = try makeVaultNeedingWaveform(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrashStore(vaultRoot: root)
        try store.trashItem(atRelativePath: entryPath)
        let item = try #require(try store.items().first)
        let cache = TrashWaveformCache()
        let resolver = TrashPreviewResolver(vaultRoot: root, waveformCache: cache)

        let first = await resolver.resolve(item)
        #expect(first.waveform != nil)

        // A trashed name is reusable once its holder is restored or emptied,
        // so identity alone must not decide a cache hit.
        let replacement = try TestAudio.makeWAV(seconds: 2.0, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent()) }
        let audioURL = try #require(first.audioURL)
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.copyItem(at: replacement, to: audioURL)

        let second = await resolver.resolve(item)
        #expect(second.waveform != nil)
        #expect(second.waveform != first.waveform)
        #expect(await cache.count == 2)
    }

    @Test func cacheEvictsLeastRecentlyUsedBeyondItsEntryLimit() async {
        let cache = TrashWaveformCache(maxEntries: 2)
        let a = TrashWaveformCache.Key(path: "/a.wav", size: 1, modified: 1)
        let b = TrashWaveformCache.Key(path: "/b.wav", size: 1, modified: 1)
        let c = TrashWaveformCache.Key(path: "/c.wav", size: 1, modified: 1)
        await cache.store(WaveformData(duration: 1, peaks: [0.1]), for: a)
        await cache.store(WaveformData(duration: 2, peaks: [0.2]), for: b)

        // Re-reading `a` makes `b` the least recently used.
        #expect(await cache.value(for: a) != nil)
        await cache.store(WaveformData(duration: 3, peaks: [0.3]), for: c)

        #expect(await cache.count == 2)
        #expect(await cache.value(for: b) == nil)
        #expect(await cache.value(for: a)?.duration == 1)
        #expect(await cache.value(for: c)?.duration == 3)
    }

    @Test func cacheEvictsOnPeakBudgetAndAlwaysKeepsTheNewestEntry() async {
        let cache = TrashWaveformCache(maxEntries: 10, maxPeaks: 5)
        let small = TrashWaveformCache.Key(path: "/small.wav", size: 1, modified: 1)
        let huge = TrashWaveformCache.Key(path: "/huge.wav", size: 2, modified: 1)
        await cache.store(WaveformData(duration: 1, peaks: [0.1, 0.2, 0.3]), for: small)
        await cache.store(
            WaveformData(duration: 9, peaks: Array(repeating: 0.4, count: 40)), for: huge
        )

        // One waveform larger than the whole budget still stays resident, so
        // re-selecting a single very long recording never re-decodes.
        #expect(await cache.count == 1)
        #expect(await cache.value(for: small) == nil)
        #expect(await cache.value(for: huge)?.duration == 9)

        await cache.removeAll()
        #expect(await cache.count == 0)
        #expect(await cache.value(for: huge) == nil)
    }
}
