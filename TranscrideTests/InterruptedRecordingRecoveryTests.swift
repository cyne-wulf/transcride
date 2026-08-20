import AVFoundation
import Foundation
import Testing

@Suite("Interrupted recording recovery")
struct InterruptedRecordingRecoveryTests {
    private func makeEntry() throws -> (root: URL, path: RelativePath, url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = "Journal/transcride-2026-07-11T10-30-00"
        let url = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (root, path, url)
    }

    private func seedUniversalArtifacts(in entryURL: URL) throws {
        for fileName in UniversalRecordingArtifacts.interruptedRecoveryCleanupFileNames {
            try AtomicFile.write(
                Data("private derived audio".utf8),
                to: entryURL.appending(path: fileName)
            )
        }
    }

    /// Writes a real Mac-audio sidecar carrying a loud block over
    /// `[startFrame, startFrame + frameCount)` on the microphone timeline.
    @discardableResult
    private func seedSystemAudioSidecar(
        in entryURL: URL, startFrame: Int64, frameCount: Int, amplitude: Float = 0.8
    ) throws -> URL {
        let url = entryURL.appending(
            path: UniversalRecordingArtifacts.systemAudioFileName
        )
        let journal = SparseSystemAudioJournal(
            url: url,
            configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try journal.append(
            samples: [Float](repeating: amplitude, count: frameCount),
            startFrame: startFrame,
            peak: amplitude
        )
        _ = journal.finish()
        return url
    }

    private func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(Float.zero) { max($0, abs($1)) }
    }

    private func backdate(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 24 * 3_600)],
            ofItemAtPath: url.path
        )
    }

    private func expectNoUniversalArtifacts(in entryURL: URL) {
        for fileName in UniversalRecordingArtifacts.interruptedRecoveryCleanupFileNames {
            #expect(!FileManager.default.fileExists(
                atPath: entryURL.appending(path: fileName).path
            ))
        }
    }

    @Test func relaunchPromotesValidPartialIntoCompleteEntry() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(recovered.entryRelativePath == fixture.path)
        #expect(abs(recovered.duration - 1.2) < 0.1)
        #expect(recovered.microphoneHasSignal)
        #expect(recovered.microphoneFrames > 0)
        #expect(recovered.shouldQueueTranscription)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: recovered.audioFileName).path
        ))
        #expect(WaveformData.load(from: WaveformData.url(inEntry: fixture.url)) != nil)

        let transcriptURL = try #require(TranscriptFile.url(inEntry: fixture.url))
        let document = FrontmatterDocument.parse(
            try String(contentsOf: transcriptURL, encoding: .utf8)
        )
        #expect(document.title == EntryCreator.recordingDefaultTitle)
        #expect(document.source == "recorded")
        #expect(abs((document.duration ?? 0) - 1.2) < 0.1)

        var scanner = VaultScanner()
        let entry = try #require(scanner.scan(root: fixture.root).entry(withID: fixture.path))
        #expect(entry.hasAudio)
        #expect(entry.hasTranscript)
    }

    /// Deleting the folder that contains a live recording drags the journal
    /// into `.trash`, which the ordinary scan skips as hidden. Rebuilding it
    /// there makes the audio restorable instead of purge-bait.
    @Test func journalTrashedWithItsFolderIsRebuiltInPlace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        // What a folder delete leaves behind: the whole folder, entry and all,
        // parked under `.trash`.
        let trashedPath = ".trash/Journal/transcride-2026-07-11T10-30-00"
        let trashedURL = root.appendingRelativePath(trashedPath)
        try FileManager.default.createDirectory(at: trashedURL, withIntermediateDirectories: true)
        let source = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source, to: trashedURL.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: root)

        // The rebuilt entry stays strictly in its own channel: nothing here may
        // be enqueued for transcription or handed to the search index.
        #expect(summary.recovered.isEmpty)
        #expect(summary.failures.isEmpty)
        let rebuilt = try #require(summary.recoveredInTrash.first)
        #expect(summary.recoveredInTrash.count == 1)
        #expect(rebuilt.entryRelativePath == trashedPath)
        #expect(abs(rebuilt.duration - 1.2) < 0.1)
        #expect(FileManager.default.fileExists(
            atPath: trashedURL.appending(path: rebuilt.audioFileName).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: trashedURL.appending(path: RecorderPartialFile.name).path
        ))
        // And the live vault is untouched: a trashed entry must never surface
        // in the library.
        var scanner = VaultScanner()
        #expect(scanner.scan(root: root).allEntries.isEmpty)
    }

    /// The trash pass must not disturb the ordinary one when both have work.
    @Test func trashAndLiveJournalsRecoverIntoSeparateChannels() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source, to: fixture.url.appending(path: RecorderPartialFile.name)
        )
        let trashedURL = fixture.root
            .appendingRelativePath(".trash/transcride-2026-07-11T09-00-00")
        try FileManager.default.createDirectory(at: trashedURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source, to: trashedURL.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)

        #expect(summary.recovered.map(\.entryRelativePath) == [fixture.path])
        #expect(summary.recoveredInTrash.map(\.entryRelativePath)
            == [".trash/transcride-2026-07-11T09-00-00"])
        #expect(summary.failures.isEmpty)
    }

    @Test func relaunchIdentifiesFramedDigitalSilenceWithoutDiscardingIt() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.5, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(!recovered.microphoneHasSignal)
        #expect(recovered.microphoneFrames > 0)
        #expect(!recovered.shouldQueueTranscription)
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: recovered.audioFileName).path
        ))
    }

    @Test func tooShortSilentCrashJournalStillCarriesFailureClassification() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.01, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let failure = try #require(summary.failures.first)
        #expect(summary.recovered.isEmpty)
        #expect(failure.microphoneFrames > 0)
        #expect(failure.microphoneTerminalState == .perfectlySilent)
    }

    @Test func emptyCrashJournalStillCarriesNoFramesClassification() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        let file = try AVAudioFile(
            forWriting: partial,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        file.close()

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let failure = try #require(summary.failures.first)
        #expect(summary.recovered.isEmpty)
        #expect(failure.microphoneFrames == 0)
        #expect(failure.microphoneTerminalState == .noFrames)
    }

    @Test func recoveryIsIdempotent() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.5, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let first = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(first.recovered.count == 1)
        #expect(second.recovered.isEmpty)
        #expect(second.failures.isEmpty)
        let visible = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
            .filter { $0 == "audio.m4a" || $0 == "audio.caf" }
        #expect(visible.count == 1)
    }

    @Test func micMasterRecoveryRemovesEveryUniversalArtifact() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.7, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try FileManager.default.copyItem(at: source, to: partial)
        try seedUniversalArtifacts(in: fixture.url)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        expectNoUniversalArtifacts(in: fixture.url)

        let canonical = fixture.url.appending(path: recovered.audioFileName)
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        #expect(try await AudioImportFormat.probeDuration(of: canonical) > 0.6)
    }

    @Test func corruptPartialIsRetainedForFutureRecovery() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try AtomicFile.write("not audio", to: partial)
        try seedUniversalArtifacts(in: fixture.url)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.recovered.isEmpty)
        #expect(summary.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(TranscriptFile.url(inEntry: fixture.url) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        #expect(VaultScanner.audioFile(in: names.filter { !$0.hasPrefix(".") }) == nil)
        for fileName in UniversalRecordingArtifacts.interruptedRecoveryCleanupFileNames {
            #expect(FileManager.default.fileExists(
                atPath: fixture.url.appending(path: fileName).path
            ))
        }
    }

    @Test func crashAfterVisibleInstallConvergesWithoutDuplication() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.6, amplitude: 0.4)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let visibleURL = fixture.url.appending(path: "audio.caf")
        try FileManager.default.copyItem(at: source, to: visibleURL)
        let visibleBytes = try Data(contentsOf: visibleURL)
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )
        try seedUniversalArtifacts(in: fixture.url)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        #expect(names.filter { $0 == "audio.m4a" || $0 == "audio.caf" }.count == 1)
        #expect(try Data(contentsOf: visibleURL) == visibleBytes)
        expectNoUniversalArtifacts(in: fixture.url)
    }

    @Test func installedMacAudioCanRemainTranscribableWhileSilentMicIsReported() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let silentMic = try TestAudio.makeWAV(seconds: 0.6, amplitude: 0)
        let audibleCanonical = try TestAudio.makeWAV(seconds: 0.6, amplitude: 0.3)
        defer {
            try? FileManager.default.removeItem(at: silentMic.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: audibleCanonical.deletingLastPathComponent())
        }
        try FileManager.default.copyItem(
            at: silentMic,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )
        try FileManager.default.copyItem(
            at: audibleCanonical,
            to: fixture.url.appending(path: "audio.caf")
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(!recovered.microphoneHasSignal)
        #expect(recovered.canonicalHasSignal)
        #expect(recovered.shouldQueueTranscription)
    }

    @Test func truncatedVisibleAudioIsRebuiltFromTheIntactJournal() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let complete = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        let torn = try TestAudio.makeWAV(seconds: 0.3, amplitude: 0.35)
        defer {
            try? FileManager.default.removeItem(at: complete.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: torn.deletingLastPathComponent())
        }
        let partialURL = fixture.url.appending(path: RecorderPartialFile.name)
        try FileManager.default.copyItem(at: complete, to: partialURL)
        // A finalize copy interrupted a quarter of the way through: readable,
        // shorter than its own source, and not yet accompanied by a transcript.
        try FileManager.default.copyItem(
            at: torn,
            to: fixture.url.appending(path: "audio.caf")
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(abs(recovered.duration - 1.2) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        #expect(names.filter { $0 == "audio.m4a" || $0 == "audio.caf" }.count == 1)
        let canonical = fixture.url.appending(path: recovered.audioFileName)
        #expect(try await AudioImportFormat.probeDuration(of: canonical) > 1.1)
    }

    @Test func shorterVisibleAudioOfAFinishedEntryIsNeverDiscarded() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        let trimmed = try TestAudio.makeWAV(seconds: 0.3, amplitude: 0.35)
        defer {
            try? FileManager.default.removeItem(at: journal.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: trimmed.deletingLastPathComponent())
        }
        try FileManager.default.copyItem(
            at: journal,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )
        let visibleURL = fixture.url.appending(path: "audio.caf")
        try FileManager.default.copyItem(at: trimmed, to: visibleURL)
        let trimmedBytes = try Data(contentsOf: visibleURL)
        // A finished entry always carries a transcript. Its audio may be
        // legitimately shorter than a stale journal — after a trim, say — and
        // recovery must converge onto it rather than "restore" the old tail.
        try EntryCreator.writeRecordingStub(
            entryURL: fixture.url, created: .now, duration: 0.3
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(recovered.audioFileName == "audio.caf")
        #expect(try Data(contentsOf: visibleURL) == trimmedBytes)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
    }

    @Test func unusableJournalNeverDiscardsTheOnlyReadableAudio() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let short = try TestAudio.makeWAV(seconds: 0.3, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: short.deletingLastPathComponent()) }
        // Nothing can be rebuilt from an unreadable journal, so a shorter but
        // readable visible file is still the best audio this entry has and must
        // survive untouched.
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try AtomicFile.write("not audio", to: partial)
        let visibleURL = fixture.url.appending(path: "audio.caf")
        try FileManager.default.copyItem(at: short, to: visibleURL)
        let visibleBytes = try Data(contentsOf: visibleURL)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.recovered.isEmpty)
        #expect(summary.failures.count == 1)
        #expect(try Data(contentsOf: visibleURL) == visibleBytes)
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func undeletableTemporaryArtifactStillCompletesRecovery() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.7, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try FileManager.default.copyItem(at: source, to: partial)
        try seedUniversalArtifacts(in: fixture.url)
        var lockedURL = fixture.url.appending(
            path: UniversalRecordingArtifacts.mixedJournalFileName
        )
        var locked = URLResourceValues()
        locked.isUserImmutable = true
        try lockedURL.setResourceValues(locked)
        defer {
            var unlocked = URLResourceValues()
            unlocked.isUserImmutable = false
            try? lockedURL.setResourceValues(unlocked)
        }

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        // The undeletable artifact is stranded, but the entry is fully
        // recovered and its journal is retired, so relaunching cannot repeat
        // this failure forever.
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: recovered.audioFileName).path
        ))
        #expect(TranscriptFile.url(inEntry: fixture.url) != nil)
        #expect(FileManager.default.fileExists(atPath: lockedURL.path))

        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(second == InterruptedRecordingRecoverySummary())
    }

    @Test func legacyPacketizedPartialIsAcknowledgedOnceWithoutDeletingBytes() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Minimal CAF header with a description chunk whose format id is
        // ALAC, matching the variable-packet journals written pre-fix.
        var bytes = Data("caff".utf8)
        bytes.append(contentsOf: [0, 1, 0, 0])
        bytes.append(Data("desc".utf8))
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
        bytes.append(contentsOf: [0x40, 0xe5, 0x88, 0x80, 0, 0, 0, 0])
        bytes.append(Data("alac".utf8))
        bytes.append(Data(repeating: 0, count: 128))
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try bytes.write(to: partial)

        let first = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(first.recovered.isEmpty)
        #expect(first.failures.isEmpty)
        #expect(first.acknowledgedLegacyPaths == [fixture.path])
        #expect(try Data(contentsOf: partial) == bytes)
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(
                path: InterruptedRecordingRecovery.legacyMarkerFileName
            ).path
        ))

        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(second == InterruptedRecordingRecoverySummary())
        #expect(try Data(contentsOf: partial) == bytes)
    }

    /// R1: a crashed meeting recording. The microphone journal and the sparse
    /// Mac-audio sidecar only ever coexist here, so recovery is the last moment
    /// the two halves can be joined. The microphone captured nothing, which
    /// makes the assertion unambiguous: signal in the recovered canonical file
    /// can only have come from the sidecar.
    @Test func crashedMeetingRecoveryMixesTheMacAudioSidecarIntoTheRecoveredEntry()
        async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 1.0, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try FileManager.default.copyItem(at: source, to: partial)
        try seedSystemAudioSidecar(in: fixture.url, startFrame: 10_000, frameCount: 20_000)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(recovered.mixedSystemAudio)
        // The microphone half is reported honestly; the canonical file is
        // useful anyway, so the entry is still worth transcribing.
        #expect(!recovered.microphoneHasSignal)
        #expect(recovered.canonicalHasSignal)
        #expect(recovered.shouldQueueTranscription)
        #expect(abs(recovered.duration - 1.0) < 0.05)

        let canonical = fixture.url.appending(path: recovered.audioFileName)
        let samples = try decode(canonical)
        // Frame-exact with the journal: the mix adds Mac audio at the same
        // frame indices, it never shifts the timeline.
        #expect(abs(samples.count - 44_100) <= 4_096)
        #expect(peak(samples[12_000..<28_000]) > 0.05)
        #expect(peak(samples[0..<9_000]) < 0.01)
        expectNoUniversalArtifacts(in: fixture.url)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(WaveformData.load(from: WaveformData.url(inEntry: fixture.url)) != nil)

        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(second == InterruptedRecordingRecoverySummary())
    }

    /// A mix that cannot be trusted must cost nothing: recovery falls back to
    /// the microphone journal exactly as it did before R1.
    @Test func unreadableSidecarFallsBackToTheMicrophoneOnlyRecovery() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.8, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try FileManager.default.copyItem(at: source, to: partial)
        try AtomicFile.write(
            Data("not a sparse journal".utf8),
            to: fixture.url.appending(
                path: UniversalRecordingArtifacts.systemAudioFileName
            )
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(!recovered.mixedSystemAudio)
        #expect(recovered.microphoneHasSignal)
        #expect(recovered.canonicalHasSignal)
        #expect(peak(try decode(
            fixture.url.appending(path: recovered.audioFileName)
        )[0..<10_000]) > 0.1)
        expectNoUniversalArtifacts(in: fixture.url)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    /// R4's other half: a sidecar preserved by a failed offline mix has no
    /// automatic consumer, so it is swept once the salvage window passes — but
    /// never while its microphone journal is still on disk, and never early.
    @Test func abandonedSidecarSurvivesTheSalvageWindowThenIsSwept() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recentURL = try seedSystemAudioSidecar(
            in: fixture.url, startFrame: 0, frameCount: 128
        )

        _ = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(FileManager.default.fileExists(atPath: recentURL.path))

        try backdate(recentURL, days: 8)
        _ = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(!FileManager.default.fileExists(atPath: recentURL.path))
    }

    @Test func sweepNeverTouchesASidecarWhoseJournalIsStillPresent() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // An unrecoverable partial: recovery fails and retains everything, so
        // the sidecar must survive the sweep despite being long expired.
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try AtomicFile.write("not audio", to: partial)
        let sidecarURL = try seedSystemAudioSidecar(
            in: fixture.url, startFrame: 0, frameCount: 128
        )
        try backdate(sidecarURL, days: 30)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: Unclosed journals — the true post-crash artifact

    /// Writes what a SIGKILL/power cut actually leaves behind: a journal from
    /// the production writer whose descriptor was severed without `close()`,
    /// so the data-chunk size on disk is still -1.
    private func seedUnclosedJournal(
        in entryURL: URL, seconds: Double, amplitude: Float
    ) throws -> URL {
        let url = entryURL.appending(path: RecorderPartialFile.name)
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        let frameCount = Int(seconds * 44_100)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                channel[index] = amplitude * Float(sin(Double(index) * 0.03))
            }
        }
        try writer.write(from: buffer)
        writer.closeDiscarding()
        return url
    }

    @Test func unclosedCrashJournalRecoversWithExactDuration() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try seedUnclosedJournal(in: fixture.url, seconds: 2.0, amplitude: 0.4)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(abs(recovered.duration - 2.0) < 0.05)
        #expect(recovered.microphoneHasSignal)
        #expect(recovered.shouldQueueTranscription)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: recovered.audioFileName).path
        ))
    }

    @Test func tailTruncatedUnclosedJournalRecoversWholeFrames() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try seedUnclosedJournal(in: fixture.url, seconds: 1.0, amplitude: 0.4)
        // Sever mid-sample, as an interrupted sector write would.
        let byteCount = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount - 4_411))
        try handle.close()

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(abs(recovered.duration - 0.95) < 0.05)
        #expect(recovered.microphoneHasSignal)
    }

    @Test func headerOnlyUnclosedJournalCarriesNoFramesClassification() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = fixture.url.appending(path: RecorderPartialFile.name)
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        writer.closeDiscarding()

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let failure = try #require(summary.failures.first)
        #expect(summary.recovered.isEmpty)
        #expect(failure.microphoneFrames == 0)
        #expect(failure.microphoneTerminalState == .noFrames)
    }

    @Test func unclosedJournalWithSidecarStillMixesMacAudio() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A silent mic beside an audible sidecar — the crashed-meeting shape.
        _ = try seedUnclosedJournal(in: fixture.url, seconds: 1.0, amplitude: 0)
        try seedSystemAudioSidecar(in: fixture.url, startFrame: 4_410, frameCount: 8_820)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(!recovered.microphoneHasSignal)
        #expect(recovered.mixedSystemAudio)
        #expect(recovered.shouldQueueTranscription)
        #expect(abs(recovered.duration - 1.0) < 0.05)
        expectNoUniversalArtifacts(in: fixture.url)
    }

    @Test func tornTailSidecarStillMixesTheIntactPrefix() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try seedUnclosedJournal(in: fixture.url, seconds: 1.0, amplitude: 0)
        let sidecarURL = fixture.url.appending(
            path: UniversalRecordingArtifacts.systemAudioFileName
        )
        let journal = SparseSystemAudioJournal(
            url: sidecarURL, configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try journal.append(
            samples: [Float](repeating: 0.6, count: 4_410), startFrame: 0, peak: 0.6
        )
        try journal.append(
            samples: [Float](repeating: 0.6, count: 4_410), startFrame: 8_820, peak: 0.6
        )
        _ = journal.finish()
        // Sever the second record mid-payload, as a power cut would.
        let byteCount = try #require(
            FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? Int
        )
        let handle = try FileHandle(forWritingTo: sidecarURL)
        try handle.truncate(atOffset: UInt64(byteCount - 100))
        try handle.close()

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(recovered.mixedSystemAudio)
        #expect(recovered.shouldQueueTranscription)
        expectNoUniversalArtifacts(in: fixture.url)
    }
}
