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

    @Test func selectorPointerHitPriorityAndLocking() {
        let selection = AudioRangeSelection(start: 2, end: 8)
        func interaction(at x: Double, locked: Bool = false) -> AudioRangeSelectionPointerInteraction {
            AudioRangeSelectionPointerInteraction(
                selection: selection, duration: 10, width: 100,
                pointerDownX: x, handleHitWidth: 28, isLocked: locked
            )
        }

        #expect(interaction(at: 21).target == .firstHandle)
        #expect(interaction(at: 79).target == .secondHandle)
        #expect(interaction(at: 50).target == .region)
        #expect(interaction(at: 5).target == .waveform)
        #expect(interaction(at: 21, locked: true).target == .waveform)

        // When short ranges make handle hit areas overlap, the closer boundary wins.
        let narrow = AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: 4, end: 5),
            duration: 10, width: 100, pointerDownX: 48,
            handleHitWidth: 28, isLocked: false
        )
        #expect(narrow.target == .secondHandle)
    }

    @Test func selectorHandleCrossingNormalizesOnCommit() {
        let interaction = AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: 2, end: 8),
            duration: 10, width: 100, pointerDownX: 20,
            handleHitWidth: 28, isLocked: false
        )
        #expect(interaction.selection(at: 90) == AudioRangeSelection(start: 8, end: 9))
        #expect(interaction.seekFraction(at: 90) == nil)
    }

    @Test func selectorHandleClickSeeksButHandleDragDoesNot() {
        let interaction = AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: 2, end: 8),
            duration: 10, width: 100, pointerDownX: 75,
            handleHitWidth: 28, isLocked: false
        )
        #expect(interaction.target == .secondHandle)
        #expect(interaction.seekFraction(at: 75) == 0.75)
        #expect(interaction.seekFraction(at: 80.99) == 0.8099)
        #expect(interaction.seekFraction(at: 81) == nil)
    }

    @Test func selectorRegionUsesClickThresholdAndClampsAtEdges() {
        let interaction = AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: 2, end: 5),
            duration: 10, width: 100, pointerDownX: 35,
            handleHitWidth: 12, isLocked: false
        )
        #expect(interaction.target == .region)
        #expect(!interaction.isDrag(at: 40.99))
        #expect(interaction.selection(at: 40.99) == AudioRangeSelection(start: 2, end: 5))
        #expect(abs((interaction.seekFraction(at: 40.99) ?? 0) - 0.4099) < 0.000_001)
        #expect(interaction.isDrag(at: 41))
        let moved = interaction.selection(at: 41)
        #expect(abs(moved.start - 2.6) < 0.000_001)
        #expect(abs(moved.end - 5.6) < 0.000_001)
        #expect(interaction.seekFraction(at: 41) == nil)
        #expect(interaction.selection(at: -100) == AudioRangeSelection(start: 0, end: 3))
        #expect(interaction.selection(at: 200) == AudioRangeSelection(start: 7, end: 10))
    }

    @Test func selectorWaveformClickAndDragSeek() {
        let interaction = AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: 2, end: 8),
            duration: 10, width: 100, pointerDownX: 5,
            handleHitWidth: 28, isLocked: false
        )
        #expect(interaction.target == .waveform)
        #expect(interaction.seekFraction(at: 75) == 0.75)
        #expect(interaction.seekFraction(at: -20) == 0)
        #expect(interaction.seekFraction(at: 120) == 1)
    }

    @Test func selectorRepeatedDragsAlwaysUseLatestCommittedRange() {
        var selection = AudioRangeSelection(start: 3, end: 6)
        for iteration in 0..<50 {
            let midpointX = ((selection.start + selection.end) / 2) * 10
            let interaction = AudioRangeSelectionPointerInteraction(
                selection: selection, duration: 10, width: 100,
                pointerDownX: midpointX, handleHitWidth: 10, isLocked: false
            )
            #expect(interaction.target == .region)
            let delta = iteration.isMultiple(of: 2) ? 5.0 : -5.0
            selection = interaction.selection(at: midpointX + delta)
        }
        #expect(selection == AudioRangeSelection(start: 3, end: 6))

        let nextInteraction = AudioRangeSelectionPointerInteraction(
            selection: selection, duration: 10, width: 100,
            pointerDownX: 30, handleHitWidth: 28, isLocked: false
        )
        #expect(nextInteraction.selection(at: 40) == AudioRangeSelection(start: 4, end: 6))
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
        let replacementHistory = entryURL.appending(
            path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: replacementHistory, withIntermediateDirectories: true
        )
        try AtomicFile.write("matching-original", to: replacementHistory.appending(path: "marker"))
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
        #expect(try String(
            contentsOf: wrapper.appending(path: AudioReplacementArtifacts.directoryName)
                .appending(path: "marker"), encoding: .utf8
        ) == "matching-original")
        #expect(!FileManager.default.fileExists(atPath: replacementHistory.path))
    }

    @Test func applierStampsAudioEditedDateAndPlainSetDurationDoesNot() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        // Finalization-style duration updates (no editedAt) never add the key.
        try EntryMetadata.setDuration(9.5, inEntry: entryURL)
        #expect(!(try transcriptText(inEntry: entryURL).contains("audio_edited")))

        let editDate = FrontmatterDate.parse("2026-08-20T12:34:56-07:00")!
        _ = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "audio.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath, date: editDate
        )

        // The raw scalar is written in the local zone, so compare instants.
        let doc = FrontmatterDocument.parse(try transcriptText(inEntry: entryURL))
        #expect(doc.audioEdited == editDate)
        #expect(doc.value(for: "audio_edited") != nil)
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

    @Test func restorePreTrimKeepsTrimmedAudioForRedo() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let replacementHistory = entryURL.appending(
            path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: replacementHistory, withIntermediateDirectories: true
        )
        try AtomicFile.write("matching-original", to: replacementHistory.appending(path: "marker"))
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
        #expect(try String(
            contentsOf: replacementHistory.appending(path: "marker"), encoding: .utf8
        ) == "matching-original")

        // The displaced trim remains a complete reverse-swap target for Redo.
        let redo = try #require(try store.items().first(where: { $0.kind == .preTrimAudio }))
        let redoAudio = store.trashDirectory.appending(path: redo.trashedName)
            .appending(path: "audio.m4a")
        #expect(try String(contentsOf: redoAudio, encoding: .utf8) == "trimmed audio bytes")

        _ = try store.restore(redo)
        #expect(try String(
            contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8
        ) == "trimmed audio bytes")
        #expect(!FileManager.default.fileExists(atPath: replacementHistory.path))
        #expect(try store.items().contains(where: { $0.kind == .preTrimAudio }))
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

    // MARK: - Installer (staging, exchange, rollback)

    /// Non-dot entries: what the library and the trash can actually see.
    private func visibleNames(inEntry entryURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: entryURL.path)
            .filter { !$0.hasPrefix(".") }
    }

    private func hiddenNames(inEntry entryURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: entryURL.path)
            .filter { $0.hasPrefix(".") }
    }

    /// Half-published audio: what a crash between staging and trashing would
    /// leave, and what a completed edit must never leave.
    private func stagingLeftovers(inEntry entryURL: URL) throws -> [String] {
        try hiddenNames(inEntry: entryURL).filter {
            $0.hasSuffix(".installing") || $0.hasSuffix(".previous")
        }
    }

    @Test func stagingLandsInsideTheEntryUnderAnInvisibleName() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        let installer = AudioVersionInstaller(
            entryURL: entryURL, sourceFileName: "audio.m4a", finalFileName: "audio.m4a"
        )
        let staged = try installer.stage(trimmedURL)

        // The cross-volume copy lands on a hidden, non-audio name, so nothing
        // that reads the entry can mistake a partial file for its audio.
        #expect(staged.lastPathComponent.hasPrefix("."))
        #expect(staged.deletingLastPathComponent().standardizedFileURL == entryURL.standardizedFileURL)
        #expect(try visibleNames(inEntry: entryURL).sorted()
            == ["audio.m4a", "transcript.md", "waveform.json"])
        #expect(VaultScanner.audioFile(in: try visibleNames(inEntry: entryURL)) == "audio.m4a")
        #expect(try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
            == "original audio bytes")
        #expect(!FileManager.default.fileExists(atPath: trimmedURL.path))
    }

    @Test func stagingLeavesAnAlreadyHiddenInEntryFileWhereItIs() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let composed = entryURL.appending(path: ".extension-combined.m4a")
        try AtomicFile.write("combined", to: composed)

        let installer = AudioVersionInstaller(
            entryURL: entryURL, sourceFileName: "audio.m4a", finalFileName: "audio.m4a"
        )
        #expect(try installer.stage(composed) == composed)
        #expect(try String(contentsOf: composed, encoding: .utf8) == "combined")
    }

    @Test func publishExchangesSoTheEntryIsNeverWithoutAudio() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        let installer = AudioVersionInstaller(
            entryURL: entryURL, sourceFileName: "audio.m4a", finalFileName: "audio.m4a"
        )
        let staged = try installer.stage(trimmedURL)
        let displaced = try installer.publish(stagedAt: staged)

        // On APFS this is the atomic exchange, not the two-rename fallback.
        #expect(displaced.mode == .exchanged)
        #expect(displaced.originalName == "audio.m4a")
        #expect(try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
            == "trimmed audio bytes")
        // The previous version is intact, waiting to be trashed.
        #expect(try String(
            contentsOf: entryURL.appending(path: displaced.fileName), encoding: .utf8
        ) == "original audio bytes")

        installer.rollBack(displaced)
        #expect(try String(contentsOf: entryURL.appending(path: "audio.m4a"), encoding: .utf8)
            == "original audio bytes")
        #expect(try hiddenNames(inEntry: entryURL).isEmpty)
    }

    @Test func applierLeavesNoStagingArtifactsBehind() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let trimmedURL = try makeTrimmedFile()
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        _ = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "audio.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath
        )

        #expect(try stagingLeftovers(inEntry: entryURL).isEmpty)
        #expect(try visibleNames(inEntry: entryURL).sorted() == ["audio.m4a", "transcript.md"])
    }

    @Test func trimToADifferentContainerKeepsBothVersionsComplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryRelPath = "transcride-2026-07-01T10-00-00-voice"
        let entryURL = root.appendingRelativePath(entryRelPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try AtomicFile.write("original wav bytes", to: entryURL.appending(path: "voice.wav"))
        let trimmedURL = try makeTrimmedFile(named: "voice.m4a")
        defer { try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent()) }

        let outcome = try TrimApplier(vaultRoot: root).apply(
            trimmedFileAt: trimmedURL, fileName: "voice.m4a",
            newDuration: 4.5, toEntryAt: entryRelPath
        )

        // Re-encoding renames the file, so the old one is trashed by name
        // rather than exchanged — and is filed under the name it had.
        #expect(try visibleNames(inEntry: entryURL) == ["voice.m4a"])
        #expect(try String(contentsOf: entryURL.appending(path: "voice.m4a"), encoding: .utf8)
            == "trimmed audio bytes")
        #expect(try stagingLeftovers(inEntry: entryURL).isEmpty)
        let wrapper = TrashStore(vaultRoot: root).trashDirectory
            .appending(path: outcome.trashedName)
        #expect(try String(contentsOf: wrapper.appending(path: "voice.wav"), encoding: .utf8)
            == "original wav bytes")
    }

    @Test func failureBeforeAnythingIsPublishedLeavesTheEntryUntouched() throws {
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
        // Refused before staging: no hidden leftovers, nothing in the trash.
        #expect(try hiddenNames(inEntry: entryURL).isEmpty)
        #expect(try TrashStore(vaultRoot: root).items().isEmpty)
    }

    // MARK: - Frontmatter helpers

    /// An entry whose markdown exists but cannot be decoded as UTF-8 — the
    /// case that used to be indistinguishable from "there is no transcript".
    private func makeEntryWithUnreadableTranscript() throws -> (root: URL, entryURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-unreadable-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entryURL = root.appending(path: "transcride-2026-07-01T10-00-00-note")
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFF, 0x00, 0x9C])
            .write(to: entryURL.appending(path: "transcript.md"))
        return (root, entryURL)
    }

    @Test func silenceModeRefusesToStubOverAnUnreadableTranscript() throws {
        let (root, entryURL) = try makeEntryWithUnreadableTranscript()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = entryURL.appending(path: "transcript.md")
        let before = try Data(contentsOf: url)

        #expect(throws: VaultError.self) {
            try EntryMetadata.setSilenceDetectionMode(.speech, inEntry: entryURL)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func silenceModeStubsOnlyWhenTheEntryTrulyHasNoTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-nomd-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appending(path: "transcride-2026-07-01T10-00-00-note")
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)

        try EntryMetadata.setSilenceDetectionMode(.speech, inEntry: entryURL)

        let text = try String(
            contentsOf: entryURL.appending(path: "transcript.md"), encoding: .utf8
        )
        #expect(FrontmatterDocument.parse(text).silenceDetectionMode == .speech)
        // Seeded from the folder timestamp, as the old stub did.
        #expect(FrontmatterDocument.parse(text).created != nil)
    }

    @Test func durationUpdateLeavesAnUnreadableTranscriptAloneWithoutThrowing() throws {
        let (root, entryURL) = try makeEntryWithUnreadableTranscript()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = entryURL.appending(path: "transcript.md")
        let before = try Data(contentsOf: url)

        // Audio operations must neither fail nor fabricate a note over this.
        try EntryMetadata.setDuration(4.5, inEntry: entryURL, editedAt: Date())
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func durationUpdateOnAMissingEntryIsSilent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try EntryMetadata.setDuration(4.5, inEntry: root.appending(path: "not-there"))
    }

    @Test func repeatedDurationWriteDoesNotTouchTheFile() throws {
        let (root, entryRelPath) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryURL = root.appendingRelativePath(entryRelPath)
        let url = entryURL.appending(path: "transcript.md")

        try EntryMetadata.setDuration(7.25, inEntry: entryURL)
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        // Writing the same value again would otherwise bump the modification
        // date and reshuffle the "Recently Edited" sort for no reason.
        try EntryMetadata.setDuration(7.25, inEntry: entryURL)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        #expect(after as? Date == stamp)
    }
}
