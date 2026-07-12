import Foundation
import Testing

@Suite("Audio trim (AUD-3)")
struct AudioTrimTests {
    /// Vault with one entry holding dummy audio bytes, a waveform cache
    /// (duration 10 s), and a transcript with matching frontmatter duration.
    private func makeVault() throws -> (root: URL, entryRelPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entryRelPath = "Journal/transcride-2026-07-01T10-00-00-test-note"
        let entryURL = root.appendingRelativePath(entryRelPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Test Note\"\nduration: 10.00\n---\nBody.\n",
            to: entryURL.appending(path: "transcript.md")
        )
        try AtomicFile.write("original audio bytes", to: entryURL.appending(path: "audio.m4a"))
        try WaveformData(duration: 10, peaks: [0.5, 0.4, 0.3])
            .write(to: WaveformData.url(inEntry: entryURL))
        return (root, entryRelPath)
    }

    private func makeTrimmedFile(named name: String = "audio.m4a") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-trimmed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try AtomicFile.write("trimmed audio bytes", to: url)
        return url
    }

    private func transcriptText(inEntry entryURL: URL) throws -> String {
        try String(contentsOf: entryURL.appending(path: "transcript.md"), encoding: .utf8)
    }

    // MARK: - Selection

    @Test func selectionClampsToDuration() {
        let selection = TrimSelection(start: -2, end: 14).clamped(toDuration: 10)
        #expect(selection == TrimSelection(start: 0, end: 10))
        let inverted = TrimSelection(start: 8, end: 4).clamped(toDuration: 10)
        #expect(inverted.length == 0)
    }

    @Test func selectionValidityRequiresARealCrop() {
        // Full range: nothing cropped.
        #expect(!TrimSelection(start: 0, end: 10).isValidCrop(ofDuration: 10))
        // Handle jitter within the edge tolerance is not a crop.
        #expect(!TrimSelection(start: 0.01, end: 9.99).isValidCrop(ofDuration: 10))
        // Too short to keep.
        #expect(!TrimSelection(start: 5, end: 5.2).isValidCrop(ofDuration: 10))
        // A middle selection is the canonical crop.
        #expect(TrimSelection(start: 2, end: 8).isValidCrop(ofDuration: 10))
        // Cropping one edge only is fine.
        #expect(TrimSelection(start: 0, end: 6).isValidCrop(ofDuration: 10))
        #expect(!TrimSelection(start: 1, end: 9).isValidCrop(ofDuration: 0))
    }

    @Test func trimmedFileNameKeepsM4aAndRewritesOtherFormats() {
        #expect(AudioTrimExport.trimmedFileName(forSource: "audio.m4a") == "audio.m4a")
        #expect(AudioTrimExport.trimmedFileName(forSource: "Interview.mp3") == "Interview.m4a")
        #expect(AudioTrimExport.trimmedFileName(forSource: "clip.mov") == "clip.m4a")
        #expect(AudioTrimExport.trimmedFileName(forSource: "voice memo.wav") == "voice memo.m4a")
    }

    // MARK: - Applier file dance

    @Test func applierStagesPreTrimAudioAndSwapsTrimmedIn() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        let outcome = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "audio.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath
        )

        // Trimmed file is the entry's audio now.
        #expect(outcome.audioFileName == "audio.m4a")
        let audioText = try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
        #expect(audioText == "trimmed audio bytes")
        // Stale waveform cache went with the original (regenerates on open).
        #expect(!FileManager.default.fileExists(atPath: WaveformData.url(inEntry: entryURL).path))

        // Pre-trim audio staged as one wrapper item of the right kind.
        let store = TrashStore(vaultRoot: root)
        let item = try #require(try store.items().first)
        #expect(item.trashedName == outcome.trashedName)
        #expect(item.kind == .preTrimAudio)
        #expect(item.originalPath == entryRelPath)
        #expect(item.displayName == "Original Audio — Test Note")
        let wrapper = store.trashDirectory.appending(path: item.trashedName)
        let staged = try String(contentsOf: wrapper.appending(path: "audio.m4a"), encoding: .utf8)
        #expect(staged == "original audio bytes")
        #expect(FileManager.default.fileExists(atPath: wrapper.appending(path: WaveformData.fileName).path))

        // Frontmatter: duration follows the trim; no audio_deleted flag.
        let text = try transcriptText(inEntry: entryURL)
        #expect(text.contains("duration: 4.50"))
        #expect(!text.contains("audio_deleted"))
    }

    @Test func applierWithoutAudioThrows() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        try FileManager.default.removeItem(at: entryURL.appending(path: "audio.m4a"))
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        #expect(throws: VaultError.self) {
            try TrimApplier(vaultRoot: root).apply(
                trimmedFileAt: trimmedURL, fileName: "audio.m4a",
                newDuration: 4.5, toEntryAt: entryRelPath
            )
        }
    }

    // MARK: - Restore (the retrigger flow's file side)

    @Test func restorePreTrimDiscardsReproducibleTrimmedAudio() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }
        let store = TrashStore(vaultRoot: root)

        _ = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "audio.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath
        )
        let preTrim = try #require(try store.items().first(where: { $0.kind == .preTrimAudio }))
        let restoredPath = try store.restore(preTrim)
        #expect(restoredPath == entryRelPath)

        // Original bytes and waveform are back; duration follows the cache.
        let audioText = try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
        #expect(audioText == "original audio bytes")
        #expect(WaveformData.load(from: WaveformData.url(inEntry: entryURL))?.duration == 10)
        let text = try transcriptText(inEntry: entryURL)
        #expect(text.contains("duration: 10.00"))
        #expect(!text.contains("audio_deleted"))

        // The reproducible trimmed derivative is discarded after the retained
        // original is safely restored; there is no reverse-restore row.
        #expect(try store.items().isEmpty)
    }

    @Test func restorePreTrimIntoAudioDeletedEntryClearsFlag() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }
        let store = TrashStore(vaultRoot: root)

        _ = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "audio.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath
        )
        // The user then deletes the (trimmed) audio entirely…
        try store.trashEntryAudio(atEntryPath: entryRelPath)
        #expect(try transcriptText(inEntry: entryURL).contains("audio_deleted: true"))

        // …and restores the pre-trim original: files back, flag gone.
        let preTrim = try #require(try store.items().first(where: { $0.kind == .preTrimAudio }))
        _ = try store.restore(preTrim)
        let audioText = try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
        #expect(audioText == "original audio bytes")
        #expect(!(try transcriptText(inEntry: entryURL).contains("audio_deleted")))
    }

    // MARK: - Export (real audio)

    @Test func exportCropsToSelection() async throws {
        let source = try TestAudio.makeWAV(seconds: 4, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let exported = try await AudioTrimExport.export(
            from: source, keeping: TrimSelection(start: 1, end: 3)
        )
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }

        #expect(exported.fileName == "test.m4a")
        let duration = try await AudioImportFormat.probeDuration(of: exported.url)
        // AAC priming/packet boundaries make the crop approximate.
        #expect(abs(duration - 2.0) < 0.3)
    }
}
