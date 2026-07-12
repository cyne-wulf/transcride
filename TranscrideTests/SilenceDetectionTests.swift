import Foundation
import Testing

@Suite("Per-entry silence detection")
struct SilenceDetectionTests {
    private func transcript(_ words: [(String, Double, Double)]) -> TranscriptOriginal {
        let mapped = words.map { TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2) }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(
                start: mapped.first?.start ?? 0,
                end: mapped.last?.end ?? 0,
                words: mapped
            )]
        )
    }

    @Test func routerUsesOnlySelectedModeAndSwitchesImmediately() {
        let waveform = [SilenceGap(start: 1, end: 2, previousWordIndex: 0, nextWordIndex: 0)]
        let speech = [SilenceGap(start: 3, end: 4, previousWordIndex: 0, nextWordIndex: 0)]
        var router = SilenceGapRouter()
        router.configure(entryID: "a", mode: .waveform)
        router.installSpeech(speech, forEntryID: "a")
        #expect(router.activeGaps.isEmpty) // no silent fallback to speech while waveform loads
        router.installWaveform(waveform, forEntryID: "a")
        #expect(router.activeGaps == waveform)
        router.configure(entryID: "a", mode: .speech)
        #expect(router.activeGaps == speech)
        router.configure(entryID: "a", mode: .waveform)
        #expect(router.activeGaps == waveform)
    }

    @Test func lateAsyncResultsCannotLeakAcrossEntries() {
        let old = [SilenceGap(start: 1, end: 2, previousWordIndex: 0, nextWordIndex: 0)]
        let current = [SilenceGap(start: 4, end: 5, previousWordIndex: 0, nextWordIndex: 0)]
        var router = SilenceGapRouter()
        router.configure(entryID: "old", mode: .speech)
        router.configure(entryID: "current", mode: .speech)
        let acceptedOldSpeech = router.installSpeech(old, forEntryID: "old")
        #expect(!acceptedOldSpeech)
        #expect(router.activeGaps.isEmpty)
        let acceptedCurrentSpeech = router.installSpeech(current, forEntryID: "current")
        #expect(acceptedCurrentSpeech)
        #expect(router.activeGaps == current)
        let acceptedOldWaveform = router.installWaveform(old, forEntryID: "old")
        #expect(!acceptedOldWaveform)
        #expect(router.activeGaps == current)
    }

    @Test func transcriptPlannerIncludesLeadingInternalTrailingWithSharedRules() throws {
        let plan = try SpeechSilencePlanner.makePlan(
            transcript: transcript([
                ("one", 2.0, 2.4),
                ("two", 4.0, 4.3), // 1.6 s internal gap qualifies
                ("three", 5.8, 6.1), // exactly 1.5 s does not
            ]),
            audioDuration: 8
        )
        #expect(plan.removedIntervals.count == 3)
        let expected = [(0.1, 1.9), (2.5, 3.9), (6.2, 7.9)]
        for (interval, pair) in zip(plan.removedIntervals, expected) {
            #expect(abs(interval.start - pair.0) < 0.000_001)
            #expect(abs(interval.end - pair.1) < 0.000_001)
        }
        #expect(AudioCompressionPlan.minimumSilenceDuration == SilenceGap.defaultThreshold)
        #expect(AudioCompressionPlan.boundaryPadding == SilenceGap.boundaryPadding)
    }

    @Test func noisyAudioHasNoWaveformSilenceButTranscriptStillFindsGap() async throws {
        let source = try TestAudio.makeWAV(seconds: 4, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let waveformPlan = try await AudioSilenceAnalyzer.analyze(source)
        let speechPlan = try SpeechSilencePlanner.makePlan(
            transcript: transcript([("hello", 0.2, 0.5), ("again", 3.0, 3.3)]),
            audioDuration: 4
        )
        #expect(waveformPlan.removedIntervals.isEmpty)
        #expect(speechPlan.removedIntervals == [.init(start: 0.6, end: 2.9)])
    }

    @Test func missingStaleAndMalformedSpeechBlockBeforeAudioMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-speech-block-\(UUID().uuidString)")
        let entry = root.appending(path: "transcride-2026-07-11T13-00-00-block")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = try TestAudio.makeWAV(seconds: 4, amplitude: 0.2)
        let audio = entry.appending(path: "audio.wav")
        try FileManager.default.copyItem(at: generated, to: audio)
        defer { try? FileManager.default.removeItem(at: generated.deletingLastPathComponent()) }
        let originalBytes = try Data(contentsOf: audio)

        await #expect(throws: AudioCompressionError.self) {
            _ = try await AudioCompressionPlanner.makePlan(
                mode: .speech, audioURL: audio, entryURL: entry
            )
        }
        #expect(try Data(contentsOf: audio) == originalBytes)

        try transcript([("one", 0.2, 0.5), ("two", 3, 3.3)])
            .write(to: TranscriptOriginal.url(inEntry: entry))
        try TranscriptAlignmentState.markStale(inEntry: entry)
        await #expect(throws: AudioCompressionError.self) {
            _ = try await AudioCompressionPlanner.makePlan(
                mode: .speech, audioURL: audio, entryURL: entry
            )
        }
        #expect(try Data(contentsOf: audio) == originalBytes)

        TranscriptAlignmentState.markAligned(inEntry: entry)
        try transcript([("bad", 2, 1)])
            .write(to: TranscriptOriginal.url(inEntry: entry))
        await #expect(throws: AudioCompressionError.self) {
            _ = try await AudioCompressionPlanner.makePlan(
                mode: .speech, audioURL: audio, entryURL: entry
            )
        }
        #expect(try Data(contentsOf: audio) == originalBytes)
    }

    @Test func preflightBlocksEveryUnavailableSpeechStateIncludingRegeneration() {
        for availability in [
            SpeechTranscriptAvailability.missing,
            .stale,
            .malformed,
            .regenerating,
        ] {
            #expect(throws: AudioCompressionError.self) {
                try AudioCompressionPreflight.validate(
                    mode: .speech, speechAvailability: availability
                )
            }
        }
        #expect(throws: Never.self) {
            try AudioCompressionPreflight.validate(
                mode: .waveform, speechAvailability: .regenerating
            )
        }
    }

    @Test func alignmentMarkerClearsOnlyWhenAuthoritativeTranscriptLands() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-alignment-\(UUID().uuidString)")
        let path = "transcride-2026-07-11T14-00-00-alignment"
        let entry = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = "---\ntitle: Alignment\n---\nHand edited.\n"
        let markdownURL = entry.appending(path: "transcript.md")
        try AtomicFile.write(markdown, to: markdownURL)
        try TranscriptAlignmentState.markStale(inEntry: entry)
        #expect(TranscriptAlignmentState.isStale(inEntry: entry))

        let applier = TranscriptionApplier(vaultRoot: root)
        _ = try applier.apply(
            segments: transcript([("fresh", 0.1, 0.4)]).segments,
            toEntryAt: path,
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            engineFrontmatterID: "test",
            vocabularyTerms: [],
            date: Date()
        )
        #expect(!TranscriptAlignmentState.isStale(inEntry: entry))
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == markdown)
    }
}
