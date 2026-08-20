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
}
