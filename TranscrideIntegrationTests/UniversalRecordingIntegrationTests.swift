import AVFoundation
import Foundation
import Testing
@testable import Transcride

@Suite("Universal recording app integration", .serialized)
struct UniversalRecordingIntegrationTests {
    private enum InjectedFinalizationFailure: Error {
        case afterVisibleInstall
        case derivedCleanup
        case extensionPromotion
        case cafStaging
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "transcride-universal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJournal(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(samples.count)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = capacity
        let channel = try #require(buffer.floatChannelData?[0])
        for index in samples.indices { channel[index] = samples[index] }
        try file.write(from: buffer)
        file.close()
    }

    private func readJournal(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ))
        try file.read(into: buffer, frameCount: capacity)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        file.close()
        return samples
    }

    private func transcript() -> TranscriptOriginal {
        TranscriptOriginal(
            engine: .init(
                engine: "test",
                model: "test",
                options: [:],
                created: "",
                appVersion: ""
            ),
            segments: [.init(start: 0.4, end: 2.5, words: [
                .init(text: "before", start: 0.4, end: 0.7),
                .init(text: "remote", start: 1.2, end: 1.5),
                .init(text: "after", start: 2.2, end: 2.5),
            ])]
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        ).intValue
    }

    @Test func timelineRejectsPauseAndUntimestampedMicGapsWithoutShiftingResume() throws {
        let rate = 44_100.0
        let baseSeconds = 1_000.0
        let base = AVAudioTime.hostTime(forSeconds: baseSeconds)
        let timeline = UniversalRecordingTimeline(sampleRate: rate)
        timeline.beginSegment(atFrame: 0)
        timeline.observeMicrophoneBuffer(startFrame: 0, frameCount: 4_410, hostTime: base)
        timeline.observeMicrophoneBuffer(
            startFrame: 4_410,
            frameCount: 4_410,
            hostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 0.1)
        )
        timeline.endSegment(atFrame: 8_820)

        #expect(timeline.placement(
            forHostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 0.5),
            sourceFrameCount: 441
        ) == nil)

        timeline.beginSegment(atFrame: 8_820)
        timeline.observeMicrophoneBuffer(
            startFrame: 8_820,
            frameCount: 4_410,
            hostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 5)
        )
        let resumed = try #require(timeline.placement(
            forHostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 5.05),
            sourceFrameCount: 441
        ))
        #expect(abs(resumed.startFrame - 11_025) <= 1)

        let discontinuous = UniversalRecordingTimeline(sampleRate: rate)
        discontinuous.beginSegment(atFrame: 0)
        discontinuous.observeMicrophoneBuffer(
            startFrame: 0, frameCount: 4_410, hostTime: base
        )
        discontinuous.observeMicrophoneBuffer(
            startFrame: 4_410,
            frameCount: 4_410,
            hostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 1)
        )
        #expect(discontinuous.placement(
            forHostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 0.5),
            sourceFrameCount: 441
        ) == nil)
        #expect(discontinuous.placement(
            forHostTime: AVAudioTime.hostTime(forSeconds: baseSeconds + 1),
            sourceFrameCount: 441
        )?.startFrame == 4_410)
    }

    @Test func silenceCreatesNoSidecarAndOversizedPreRollIsTrimmed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silentURL = directory.appending(path: "silent.sparse")
        let silent = SparseSystemAudioJournal(
            url: silentURL,
            configuration: .init(
                meaningfulSignalThreshold: 0.001,
                preRollFrames: 100,
                releaseFrames: 100
            )
        )
        try silent.append(samples: [Float](repeating: 0, count: 10_000), startFrame: 0, peak: 0)
        #expect(silent.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: silentURL.path))

        let boundedURL = directory.appending(path: "bounded.sparse")
        let bounded = SparseSystemAudioJournal(
            url: boundedURL,
            configuration: .init(
                meaningfulSignalThreshold: 0.001,
                preRollFrames: 100,
                releaseFrames: 100
            )
        )
        try bounded.append(samples: [Float](repeating: 0, count: 10_000), startFrame: 0, peak: 0)
        try bounded.append(samples: [Float](repeating: 0.5, count: 10), startFrame: 10_000, peak: 0.5)
        let artifact = try #require(bounded.finish())
        let size = try fileSize(artifact)
        // 8-byte magic + at most 100 pre-roll samples and 10 signal samples,
        // with one 12-byte header per retained chunk.
        #expect(size <= 8 + 12 + 100 * 4 + 12 + 10 * 4)
    }

    @Test func journalReleaseNeverExceedsConfiguredFramesIncludingZero() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for releaseFrames in [100, 0] {
            let url = directory.appending(path: "release-\(releaseFrames).sparse")
            let journal = SparseSystemAudioJournal(
                url: url,
                configuration: .init(
                    meaningfulSignalThreshold: 0.001,
                    preRollFrames: 0,
                    releaseFrames: releaseFrames
                )
            )
            try journal.append(
                samples: [Float](repeating: 0.5, count: 10),
                startFrame: 0,
                peak: 0.5
            )
            try journal.append(
                samples: [Float](repeating: 0, count: 10_000),
                startFrame: 10,
                peak: 0
            )
            let artifact = try #require(journal.finish())
            let expected = 8 + 12 + 10 * 4
                + (releaseFrames == 0 ? 0 : 12 + releaseFrames * 4)
            #expect(try fileSize(artifact) == expected)
        }
    }

    @Test func fileRendererMatchesCoreOracleAcrossBlockBoundaryAndUsesPreRoll() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appending(path: ".recording.caf")
        let sidecarURL = directory.appending(path: "system.sparse")
        let stagedURL = directory.appending(path: ".mixed.caf")
        let microphone = [Float](repeating: 0.25, count: 50_000)
        try writeJournal(microphone, to: microphoneURL)

        let preRoll = [Float](repeating: 0.000_5, count: 100)
        let signal = [Float](repeating: 0.8, count: 500)
        let release = [Float](repeating: 0, count: 100)
        let journal = SparseSystemAudioJournal(
            url: sidecarURL,
            configuration: .init(
                meaningfulSignalThreshold: 0.001,
                preRollFrames: 100,
                releaseFrames: 100
            )
        )
        try journal.append(samples: preRoll, startFrame: 16_200, peak: 0.000_5)
        try journal.append(samples: signal, startFrame: 16_300, peak: 0.8)
        try journal.append(samples: release, startFrame: 16_800, peak: 0)
        let artifact = try #require(journal.finish())

        let fileResult = try UniversalRecordingFileMixer.render(
            microphoneURL: microphoneURL,
            systemJournalURL: artifact,
            stagedURL: stagedURL
        )
        let fileSamples = try readJournal(stagedURL)
        let coreResult = UniversalRecordingMixer().render(
            microphone: microphone,
            systemAudio: .captured(chunks: [
                .init(startFrame: 16_200, samples: preRoll),
                .init(startFrame: 16_300, samples: signal),
                .init(startFrame: 16_800, samples: release),
            ], degradation: nil)
        )

        #expect(fileResult.frames == 50_000)
        #expect(fileResult.firstSystemFrame == 16_300)
        #expect(coreResult.status == .mixed(
            firstMeaningfulSystemFrame: 16_300,
            degradation: nil
        ))
        #expect(fileSamples.count == coreResult.samples.count)
        #expect(zip(fileSamples, coreResult.samples).allSatisfy {
            abs($0.0 - $0.1) < 0.000_061_1
        })
        #expect(fileSamples[16_250] != microphone[16_250])
        #expect(fileSamples[17_027].bitPattern == microphone[17_027].bitPattern)
    }

    @Test func overlappingJournalRecordsAreRejectedBeforeStreamingCanDiverge() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecarURL = directory.appending(path: "overlap.sparse")
        let journal = SparseSystemAudioJournal(
            url: sidecarURL,
            configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try journal.append(
            samples: [Float](repeating: 0.2, count: 17_000),
            startFrame: 0,
            peak: 0.2
        )
        var rejected = false
        do {
            try journal.append(samples: [0.4], startFrame: 1, peak: 0.4)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test func laterMacAudioKeepsCanonicalFramesHeadroomAndKaraokeSeekTimes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appending(path: ".recording.caf")
        let sidecarURL = directory.appending(path: "system.sparse")
        let stagedURL = directory.appending(path: ".mixed.caf")
        let frameCount = 44_100 * 3
        try writeJournal([Float](repeating: 0.25, count: frameCount), to: microphoneURL)

        let sparse = SparseSystemAudioJournal(
            url: sidecarURL,
            configuration: .init(
                meaningfulSignalThreshold: 0.001,
                preRollFrames: 100,
                releaseFrames: 20_000
            )
        )
        try sparse.append(
            samples: [Float](repeating: 0, count: 100),
            startFrame: 44_000,
            peak: 0
        )
        try sparse.append(
            samples: [Float](repeating: 0.8, count: 1_000),
            startFrame: 44_100,
            peak: 0.8
        )
        try sparse.append(
            samples: [Float](repeating: 0, count: 10_000),
            startFrame: 45_100,
            peak: 0
        )
        let artifact = try #require(sparse.finish())
        let selection = UniversalRecordingFileResolver.renderOrUseMicrophone(
            microphoneURL: microphoneURL,
            microphoneFrames: Int64(frameCount),
            microphonePeaks: [0.25],
            systemJournalURL: artifact,
            stagedURL: stagedURL
        )
        #expect(selection.fallbackReason == nil)
        #expect(selection.firstSystemFrame == 44_100)
        #expect(selection.journalURL == stagedURL)
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        let microphone = try readJournal(microphoneURL)
        let mixed = try readJournal(stagedURL)
        #expect(mixed.count == microphone.count)
        // Qualified pre-roll is intentionally audible before the first frame
        // that crossed the meaningful threshold.
        #expect(mixed[44_099].bitPattern != microphone[44_099].bitPattern)
        #expect(abs(mixed[44_300] - 0.3475) < 0.000_061_1)
        #expect(mixed[55_228].bitPattern == microphone[55_228].bitPattern)
        #expect(mixed.allSatisfy { $0.isFinite && abs($0) < 1 })

        // Playback and karaoke consume seconds on the canonical mic timeline.
        // Mac audio begins at 1.0 s, but transcript highlights and seek frames
        // before/inside/after that region remain unchanged.
        let wordMap = TranscriptWordMap(transcript: transcript(), duration: 3)
        #expect(wordMap.wordIndex(atTime: 0.5) == 0)
        #expect(wordMap.wordIndex(atTime: 1.3) == 1)
        #expect(wordMap.wordIndex(atTime: 2.3) == 2)
        #expect(Int64((1.3 * 44_100).rounded()) == 57_330)
        #expect(mixed.count == 132_300)
    }

    @Test func corruptMixFallsBackToUntouchedMicAndSameKaraokeTimeline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appending(path: ".recording.caf")
        let corruptURL = directory.appending(path: "corrupt.sparse")
        let stagedURL = directory.appending(path: ".mixed.caf")
        try writeJournal([Float](repeating: 0.2, count: 100_000), to: microphoneURL)
        let micBefore = try Data(contentsOf: microphoneURL)
        let sparse = SparseSystemAudioJournal(
            url: corruptURL,
            configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try sparse.append(samples: [Float](repeating: 0.3, count: 100), startFrame: 0, peak: 0.3)
        try sparse.append(
            samples: [Float](repeating: 0.3, count: 100), startFrame: 40_000, peak: 0.3
        )
        try sparse.append(
            samples: [Float](repeating: 0.3, count: 100), startFrame: 80_000, peak: 0.3
        )
        _ = try #require(sparse.finish())
        var truncated = try Data(contentsOf: corruptURL)
        truncated.removeLast()
        try truncated.write(to: corruptURL)

        let selection = UniversalRecordingFileResolver.renderOrUseMicrophone(
            microphoneURL: microphoneURL,
            microphoneFrames: 100_000,
            microphonePeaks: [0.2],
            systemJournalURL: corruptURL,
            stagedURL: stagedURL
        )
        #expect(selection.journalURL == microphoneURL)
        #expect(selection.fallbackReason == .mixFailed)
        #expect(try Data(contentsOf: microphoneURL) == micBefore)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))

        let map = TranscriptWordMap(transcript: transcript(), duration: 3)
        #expect(map.wordIndex(atTime: 1.3) == 1)
    }

    @Test func corruptSparseRecordBeyondMicrophoneEOFStillFallsBack() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphoneURL = directory.appending(path: ".recording.caf")
        let corruptURL = directory.appending(path: "trailing-corrupt.sparse")
        let stagedURL = directory.appending(path: ".mixed.caf")
        try writeJournal([Float](repeating: 0.2, count: 128), to: microphoneURL)
        let micBefore = try Data(contentsOf: microphoneURL)

        let sparse = SparseSystemAudioJournal(
            url: corruptURL,
            configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try sparse.append(
            samples: [Float](repeating: 0.3, count: 16), startFrame: 0, peak: 0.3
        )
        try sparse.append(
            samples: [Float](repeating: 0.3, count: 16), startFrame: 256, peak: 0.3
        )
        _ = try #require(sparse.finish())
        let handle = try FileHandle(forWritingTo: corruptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01]))
        try handle.close()

        let selection = UniversalRecordingFileResolver.renderOrUseMicrophone(
            microphoneURL: microphoneURL,
            microphoneFrames: 128,
            microphonePeaks: [0.2],
            systemJournalURL: corruptURL,
            stagedURL: stagedURL
        )
        #expect(selection.journalURL == microphoneURL)
        #expect(selection.fallbackReason == .mixFailed)
        #expect(try Data(contentsOf: microphoneURL) == micBefore)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test @MainActor
    func stopCoordinatorOrdersCanonicalInstallBeforeBatchAndSuppressesFailureHandoff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonicalURL = directory.appending(path: "audio.caf")
        var events: [String] = []

        let success = await RecordingStopCoordinator.run(
            clearLiveDisplay: { events.append("liveCleared") },
            finalizeAndInstall: {
                try? Data("canonical".utf8).write(to: canonicalURL, options: .atomic)
                events.append("visibleAudioInstalled")
                return true
            },
            isReadyForHandoff: { $0 },
            handoffFinalized: { _ in
                #expect(FileManager.default.fileExists(atPath: canonicalURL.path))
                events.append("batchQueued")
                return true
            }
        )
        if case .handedOff(let handedOff) = success {
            #expect(handedOff)
        } else {
            Issue.record("A verified canonical install must reach batch handoff")
        }
        #expect(events == ["liveCleared", "visibleAudioInstalled", "batchQueued"])

        events.removeAll()
        let failure = await RecordingStopCoordinator.run(
            clearLiveDisplay: { events.append("liveCleared") },
            finalizeAndInstall: {
                events.append("canonicalInstallFailed")
                return false
            },
            isReadyForHandoff: { $0 },
            handoffFinalized: { _ in
                events.append("batchQueued")
            }
        )
        if case .notReady(let ready) = failure {
            #expect(!ready)
        } else {
            Issue.record("A failed canonical install must not reach handoff")
        }
        #expect(events == ["liveCleared", "canonicalInstallFailed"])
    }

    @Test @MainActor
    func suspendedOptionalStartNeverBlocksMicrophoneFinalizationPath() async {
        let suspendedStart = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation only releases the deterministic test task. The
                // production scheduler is also safe if a framework await does
                // not cooperate and remains suspended.
            }
        }
        var cleanupFinished = false
        let cleanup = OptionalCaptureCleanupScheduler.schedule(
            prior: nil,
            suspendedStart: suspendedStart,
            cleanup: { cleanupFinished = true },
            completion: {}
        )

        // Scheduling returned synchronously while optional startup is still
        // suspended; canonical microphone installation can continue now.
        #expect(!cleanupFinished)
        suspendedStart.cancel()
        await cleanup.value
        #expect(cleanupFinished)
    }

    @Test func meaningfulSystemAudioPromotesSilentMicButMixFailureDoesNot() {
        #expect(RecorderService.classifyCaptureResult(
            frames: 44_100,
            microphoneHasSignal: false,
            firstMeaningfulSystemFrame: 22_050
        ) == .captured)
        #expect(RecorderService.classifyCaptureResult(
            frames: 44_100,
            microphoneHasSignal: false,
            firstMeaningfulSystemFrame: nil
        ) == .noSignal)
        #expect(RecorderService.classifyCaptureResult(
            frames: 0,
            microphoneHasSignal: true,
            firstMeaningfulSystemFrame: 0
        ) == .noFrames)
    }

    @Test func metadataFailureAfterM4AInstallRecoversWithoutChangingAudioOrKaraokeTiming() async throws {
        let vaultRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let entryPath = "Journal/transcride-2026-08-13T12-00-00"
        let entryURL = vaultRoot.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        try writeJournal([Float](repeating: 0.2, count: 44_100), to: microphoneURL)

        await #expect(throws: InjectedFinalizationFailure.self) {
            try await RecorderService.finalize(
                entryURL: entryURL,
                created: Date(timeIntervalSince1970: 1_700_000_000),
                frames: 44_100,
                duration: 1,
                peaks: [0.2],
                quality: .lossless,
                journalURL: microphoneURL,
                microphoneJournalURL: microphoneURL,
                afterVisibleAudioInstalled: { installedURL in
                    guard installedURL.lastPathComponent == "audio.m4a" else {
                        throw InjectedFinalizationFailure.afterVisibleInstall
                    }
                    throw InjectedFinalizationFailure.afterVisibleInstall
                }
            )
        }

        let canonicalURL = entryURL.appending(path: "audio.m4a")
        #expect(FileManager.default.fileExists(atPath: canonicalURL.path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(path: "audio.caf").path))
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(WaveformData.load(from: WaveformData.url(inEntry: entryURL)) == nil)
        #expect(TranscriptFile.url(inEntry: entryURL) == nil)
        let canonicalBytes = try Data(contentsOf: canonicalURL)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: vaultRoot)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(recovered.entryRelativePath == entryPath)
        #expect(recovered.audioFileName == "audio.m4a")
        #expect(recovered.shouldQueueTranscription)
        #expect(try Data(contentsOf: canonicalURL) == canonicalBytes)
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(WaveformData.load(from: WaveformData.url(inEntry: entryURL)) != nil)

        let stubURL = try #require(TranscriptFile.url(inEntry: entryURL))
        let stub = FrontmatterDocument.parse(try String(contentsOf: stubURL, encoding: .utf8))
        #expect(abs((stub.duration ?? 0) - 1) < 0.01)

        // Recovery's positive signal classification is the transcription
        // admission gate. Applying a deterministic timed result proves the
        // recovered canonical timeline remains usable by karaoke highlighting.
        let applied = try TranscriptionApplier(vaultRoot: vaultRoot).apply(
            segments: [.init(start: 0.1, end: 0.8, words: [
                .init(text: "hello", start: 0.1, end: 0.35),
                .init(text: "recovery", start: 0.5, end: 0.8),
            ])],
            toEntryAt: entryPath,
            engine: .init(
                engine: "test", model: "deterministic", options: [:],
                created: "2026-08-13T12:00:01Z", appVersion: "test"
            ),
            engineFrontmatterID: "test",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let appliedEntryURL = vaultRoot.appendingRelativePath(applied.entryRelativePath)
        let original = try #require(TranscriptOriginal.load(
            from: TranscriptOriginal.url(inEntry: appliedEntryURL)
        ))
        let karaokeMap = TranscriptWordMap(transcript: original, duration: recovered.duration)
        #expect(karaokeMap.wordIndex(atTime: 0.2) == 0)
        #expect(karaokeMap.wordIndex(atTime: 0.6) == 1)
        #expect(try Data(
            contentsOf: appliedEntryURL.appending(path: recovered.audioFileName)
        ) == canonicalBytes)
    }

    @Test func cafFallbackCopiesJournalAndRecoveryMarkerUntilMetadataSucceeds() async throws {
        let vaultRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let entryPath = "Journal/transcride-2026-08-13T12-01-00"
        let entryURL = vaultRoot.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        try writeJournal([Float](repeating: 0.25, count: 22_050), to: microphoneURL)
        let microphoneBytes = try Data(contentsOf: microphoneURL)

        // An impossible expected frame count deterministically rejects the
        // encoded stage and selects the lossless CAF fallback.
        await #expect(throws: InjectedFinalizationFailure.self) {
            try await RecorderService.finalize(
                entryURL: entryURL,
                created: Date(timeIntervalSince1970: 1_700_000_000),
                frames: 1,
                duration: 0.5,
                peaks: [0.25],
                quality: .lossless,
                journalURL: microphoneURL,
                microphoneJournalURL: microphoneURL,
                afterVisibleAudioInstalled: { _ in
                    throw InjectedFinalizationFailure.afterVisibleInstall
                }
            )
        }

        let canonicalURL = entryURL.appending(path: "audio.caf")
        #expect(try Data(contentsOf: canonicalURL) == microphoneBytes)
        #expect(try Data(contentsOf: microphoneURL) == microphoneBytes)
        #expect(TranscriptFile.url(inEntry: entryURL) == nil)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: vaultRoot)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(try Data(contentsOf: canonicalURL) == microphoneBytes)
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(TranscriptFile.url(inEntry: entryURL) != nil)
        #expect(WaveformData.load(from: WaveformData.url(inEntry: entryURL)) != nil)
    }

    @Test func derivedCleanupFailureNeverAttemptsMicrophoneRecoveryMarker() throws {
        let entryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: entryURL) }
        let stagedURL = entryURL.appending(
            path: UniversalRecordingArtifacts.stagedCanonicalAudioFileName
        )
        let mixedURL = entryURL.appending(path: UniversalRecordingArtifacts.mixedJournalFileName)
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        for url in [stagedURL, mixedURL, microphoneURL] {
            try Data("journal".utf8).write(to: url)
        }
        var attempted: [String] = []

        #expect(throws: InjectedFinalizationFailure.self) {
            try RecorderService.cleanupFinalizationJournals(
                journalURL: mixedURL,
                microphoneJournalURL: microphoneURL,
                stagedM4AURL: stagedURL
            ) { url in
                attempted.append(url.lastPathComponent)
                if url == mixedURL {
                    throw InjectedFinalizationFailure.derivedCleanup
                }
                try FileManager.default.removeItem(at: url)
            }
        }

        #expect(attempted == [stagedURL.lastPathComponent, mixedURL.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(FileManager.default.fileExists(atPath: mixedURL.path))
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    @Test(arguments: [RecordingQuality.compressed, .lossless])
    func extensionFinalizationPromotesValidatedStageBeforeDeletingPartial(
        quality: RecordingQuality
    ) async throws {
        let entryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: entryURL) }
        let frames: Int64 = 22_050
        let partialURL = entryURL.appending(
            path: RecordingExtensionArtifacts.partialFileName
        )
        try writeJournal([Float](repeating: 0.2, count: Int(frames)), to: partialURL)

        let segmentURL = try await RecorderService.finalizeExtensionSegment(
            entryURL: entryURL,
            frames: frames,
            duration: 0.5,
            quality: quality
        )

        #expect(segmentURL.lastPathComponent == RecordingExtensionArtifacts.segmentM4AFileName)
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(
            path: RecordingExtensionArtifacts.stagedSegmentM4AFileName
        ).path))
        let validation = try AVAudioFile(forReading: segmentURL)
        #expect(Int64(validation.length) == frames)
        validation.close()
    }

    @Test func extensionPromotionFailureCopiesValidPartialToCommittedCAF() async throws {
        let entryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: entryURL) }
        let frames: Int64 = 22_050
        let partialURL = entryURL.appending(
            path: RecordingExtensionArtifacts.partialFileName
        )
        try writeJournal([Float](repeating: 0.3, count: Int(frames)), to: partialURL)
        let partialBytes = try Data(contentsOf: partialURL)

        let segmentURL = try await RecorderService.finalizeExtensionSegment(
            entryURL: entryURL,
            frames: frames,
            duration: 0.5,
            quality: .lossless,
            afterStagedM4AValidated: { _ in
                throw InjectedFinalizationFailure.extensionPromotion
            }
        )

        #expect(segmentURL.lastPathComponent == RecordingExtensionArtifacts.segmentCAFFileName)
        #expect(try Data(contentsOf: segmentURL) == partialBytes)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(
            path: RecordingExtensionArtifacts.stagedSegmentM4AFileName
        ).path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(
            path: RecordingExtensionArtifacts.segmentM4AFileName
        ).path))
    }

    @Test func finalizationReturnsOnlyAfterCanonicalAudioIsInstalled() async throws {
        let entryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: entryURL) }
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        try writeJournal([Float](repeating: 0.2, count: 44_100), to: microphoneURL)

        try await RecorderService.finalize(
            entryURL: entryURL,
            created: Date(timeIntervalSince1970: 1_700_000_000),
            frames: 44_100,
            duration: 1,
            peaks: [0.2],
            quality: .lossless,
            journalURL: microphoneURL,
            microphoneJournalURL: microphoneURL
        )

        let canonicalURL = entryURL.appending(path: "audio.m4a")
        #expect(FileManager.default.fileExists(atPath: canonicalURL.path))
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: entryURL.appending(path: ".audio-finalizing.m4a").path
        ))
        let canonical = try AVAudioFile(forReading: canonicalURL)
        #expect(canonical.length == 44_100)
        canonical.close()
        #expect(TranscriptFile.url(inEntry: entryURL) != nil)
    }

    @Test func interruptedCAFFallbackNeverPublishesTruncatedCanonicalAudio() async throws {
        let vaultRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let entryPath = "Journal/transcride-2026-08-20T09-15-00"
        let entryURL = vaultRoot.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        try writeJournal([Float](repeating: 0.25, count: 44_100), to: microphoneURL)
        let microphoneBytes = try Data(contentsOf: microphoneURL)

        // `frames: 1` rejects the encoded stage and selects the lossless
        // fallback; the injected failure then stands in for a crash between the
        // staged copy and its promotion.
        await #expect(throws: InjectedFinalizationFailure.self) {
            try await RecorderService.finalize(
                entryURL: entryURL,
                created: Date(timeIntervalSince1970: 1_700_000_000),
                frames: 1,
                duration: 1,
                peaks: [0.25],
                quality: .lossless,
                journalURL: microphoneURL,
                microphoneJournalURL: microphoneURL,
                afterStagedCAFCopied: { _ in
                    throw InjectedFinalizationFailure.cafStaging
                }
            )
        }

        // Nothing visible was published, and the journal is untouched.
        #expect(!FileManager.default.fileExists(
            atPath: entryURL.appending(path: "audio.caf").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: entryURL.appending(path: "audio.m4a").path
        ))
        #expect(try Data(contentsOf: microphoneURL) == microphoneBytes)

        // Startup recovery therefore rebuilds the complete recording and sweeps
        // the staged copy instead of adopting a truncated one.
        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: vaultRoot)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.failures.isEmpty)
        #expect(abs(recovered.duration - 1) < 0.05)
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: entryURL.appending(
                path: UniversalRecordingArtifacts.stagedCanonicalCAFFileName
            ).path
        ))
        let canonical = try AVAudioFile(
            forReading: entryURL.appending(path: recovered.audioFileName)
        )
        #expect(canonical.length == 44_100)
        canonical.close()
    }

    @Test func successfulCAFFallbackLeavesNoStagedCopyBehind() async throws {
        let entryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: entryURL) }
        let microphoneURL = entryURL.appending(path: RecorderService.partialFileName)
        try writeJournal([Float](repeating: 0.25, count: 22_050), to: microphoneURL)
        let microphoneBytes = try Data(contentsOf: microphoneURL)

        try await RecorderService.finalize(
            entryURL: entryURL,
            created: Date(timeIntervalSince1970: 1_700_000_000),
            frames: 1,
            duration: 0.5,
            peaks: [0.25],
            quality: .lossless,
            journalURL: microphoneURL,
            microphoneJournalURL: microphoneURL
        )

        #expect(try Data(contentsOf: entryURL.appending(path: "audio.caf")) == microphoneBytes)
        #expect(!FileManager.default.fileExists(
            atPath: entryURL.appending(
                path: UniversalRecordingArtifacts.stagedCanonicalCAFFileName
            ).path
        ))
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    @Test func interruptedSegmentCAFFallbackNeverShadowsTheIntactPartial() async throws {
        let vaultRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let entryURL = vaultRoot.appending(
            path: "transcride-2026-08-20T09-45-00", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let frames: Int64 = 22_050
        let partialURL = entryURL.appending(
            path: RecordingExtensionArtifacts.partialFileName
        )
        try writeJournal([Float](repeating: 0.3, count: Int(frames)), to: partialURL)
        let partialBytes = try Data(contentsOf: partialURL)
        let session = RecordingExtensionSession(
            target: .init(
                entryRelativePath: entryURL.lastPathComponent,
                sourceAudioFileName: "audio.m4a",
                sourceDuration: 10
            ),
            phase: .finalizingSegment
        )
        try JSONEncoder().encode(session).write(
            to: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
        )

        await #expect(throws: InjectedFinalizationFailure.self) {
            _ = try await RecorderService.finalizeExtensionSegment(
                entryURL: entryURL,
                frames: frames,
                duration: 0.5,
                quality: .lossless,
                afterStagedM4AValidated: { _ in
                    throw InjectedFinalizationFailure.extensionPromotion
                },
                afterStagedCAFCopied: { _ in
                    throw InjectedFinalizationFailure.cafStaging
                }
            )
        }

        // No committed candidate was published, and the journal is intact, so
        // discovery still offers the full segment for recovery.
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(
            path: RecordingExtensionArtifacts.segmentCAFFileName
        ).path))
        #expect(!FileManager.default.fileExists(atPath: entryURL.appending(
            path: RecordingExtensionArtifacts.stagedSegmentCAFFileName
        ).path))
        #expect(try Data(contentsOf: partialURL) == partialBytes)

        let discovery = RecordingExtensionRecovery.discover(inVault: vaultRoot)
        let recoverable = try #require(discovery.recoverable.first)
        #expect(recoverable.phase == .partialCapture)
        #expect(recoverable.segmentFileName == RecordingExtensionArtifacts.partialFileName)
    }

    @Test func aMixedPrefixNeverUpgradesADegradedSystemAudioStatus() {
        // A stall, invalid timing, or a sidecar-write failure stops the stream
        // but keeps the chunks already qualified, so the offline render still
        // succeeds over a prefix. That must not be reported as full capture.
        for reason in [
            OptionalSystemAudioFallbackReason.stalled,
            .invalidTiming,
            .sidecarWriteFailed,
        ] {
            #expect(
                RecorderService.systemAudioStatusAfterSuccessfulMix(
                    .microphoneOnly(reason)
                ) == .microphoneOnly(reason)
            )
        }
        for status in [
            OptionalSystemAudioCaptureStatus.capturing,
            .captured,
            .notRequested,
            .starting,
        ] {
            #expect(
                RecorderService.systemAudioStatusAfterSuccessfulMix(status) == .captured
            )
        }
    }
}
