import Foundation
import Testing

@Suite("Replace selected audio (RPL)")
struct AudioReplacementTests {
    @Test func injectedFailureMessagesIdentifyTheProtectedStage() {
        #expect(AudioReplacementInjectedError.forced(.beforeRender).errorDescription?
            .contains("before replacement rendering") == true)
        #expect(AudioReplacementInjectedError.forced(.beforeSafeSwap).errorDescription?
            .contains("before the replacement safe swap") == true)
    }

    @Test func sharedRangeClampsAndRequiresMeaningfulReplacement() {
        let selection = AudioRangeSelection(start: -2, end: 20).clamped(toDuration: 10)
        #expect(selection == AudioRangeSelection(start: 0, end: 10))
        #expect(selection.isValidReplacement(ofDuration: 10))
        #expect(!AudioRangeSelection(start: 2, end: 2.2).isValidReplacement(ofDuration: 10))
        #expect(AudioRangeSelection.normalized(8, 3)
            == AudioRangeSelection(start: 3, end: 8))
    }

    @Test func initialRangeKeepsHandlesSeparatedOnLongAudio() {
        #expect(AudioRangeSelection.initialReplacementSelection(forDuration: 35)
            == AudioRangeSelection(start: 0, end: 5))
        #expect(AudioRangeSelection.initialReplacementSelection(forDuration: 1_695)
            == AudioRangeSelection(start: 0, end: 84.75))
        #expect(AudioRangeSelection.initialReplacementSelection(forDuration: 3)
            == AudioRangeSelection(start: 0, end: 3))
    }

    @Test func regionUsesExactFrameCoordinates() {
        let region = ReplacementRegion(
            selection: AudioRangeSelection(start: 1.00001, end: 2.00001),
            timelineDuration: 5,
            sampleRate: 44_100
        )
        #expect(region.startFrame == 44_100)
        #expect(region.frameCount == 44_100)
    }

    @Test func takeEligibilityAllowsAtMostOneFrameDifference() {
        let region = ReplacementRegion(
            selection: AudioRangeSelection(start: 1, end: 2),
            timelineDuration: 5,
            sampleRate: 44_100
        )
        #expect(ReplacementTakeEligibility.classify(
            capturedFrames: 44_099, capturedSampleRate: 44_100, for: region
        ) == .eligible)
        #expect(ReplacementTakeEligibility.classify(
            capturedFrames: 44_098, capturedSampleRate: 44_100, for: region
        ) == .incomplete(missingFrames: 2))
        #expect(ReplacementTakeEligibility.classify(
            capturedFrames: 44_102, capturedSampleRate: 44_100, for: region
        ) == .tooLong(extraFrames: 2))
    }

    @Test func playableTimelineOverridesRoundedFrontmatterDuration() {
        let timeline = ReplacementTimeline(duration: 10.287641723356009)
        #expect(timeline.totalFrames == 453_685)
        #expect(timeline.duration == 10.287641723356009)
        #expect(timeline.matches(duration: 10.287641723356009))
        #expect(!timeline.matches(duration: 10.29))
        #expect(timeline.matches(
            duration: 10.29,
            toleranceFrames: ReplacementTimeline.roundedMetadataToleranceFrames(sampleRate: 44_100)
        ))
    }

    @Test func renderDurationValidationUsesIntegerFrames() {
        let plan = ReplacementRenderDurationPlan(
            expectedFrames: 453_685, sampleRate: 44_100
        )
        #expect(plan.accepts(actualDuration: 10.287641723356009))
        #expect(plan.accepts(actualDuration: Double(453_686) / 44_100))
        #expect(!plan.accepts(actualDuration: 10.29))
        #expect(!plan.accepts(actualDuration: .nan))
    }

    @Test func overlappingReplacementSplitsAndSupersedesOnlyOverlap() throws {
        var recipe = ReplacementRecipe.master(fileName: "master.m4a", duration: 10, sampleRate: 10)
        let first = ReplacementSource(id: UUID(), kind: .take, fileName: "take-1.m4a", frameCount: 30)
        recipe = recipe.replacing(
            region: ReplacementRegion(
                selection: AudioRangeSelection(start: 2, end: 5),
                timelineDuration: 10,
                sampleRate: 10
            ),
            with: first
        )
        let second = ReplacementSource(id: UUID(), kind: .take, fileName: "take-2.m4a", frameCount: 20)
        recipe = recipe.replacing(
            region: ReplacementRegion(
                selection: AudioRangeSelection(start: 4, end: 6),
                timelineDuration: 10,
                sampleRate: 10
            ),
            with: second
        )

        #expect(recipe.totalFrames == 100)
        #expect(recipe.isDurationPreserving)
        #expect(recipe.slices.map(\.frameCount) == [20, 20, 20, 40])
        #expect(recipe.slices[1].sourceID == first.id)
        #expect(recipe.slices[2].sourceID == second.id)
        let plan = try #require(ReplacementRenderPlan.make(recipe: recipe))
        #expect(plan.map(\.fileName) == ["master.m4a", "take-1.m4a", "take-2.m4a", "master.m4a"])
    }

    @Test func recoveryClassificationIsIdempotent() {
        #expect(ReplacementRecoveryClassification.classify(
            hasSession: true, hasPartial: true, completeTakeCount: 0,
            hasCandidate: false, canonicalMatchesCandidate: false
        ) == .partialTake)
        #expect(ReplacementRecoveryClassification.classify(
            hasSession: true, hasPartial: false, completeTakeCount: 1,
            hasCandidate: true, canonicalMatchesCandidate: true
        ) == .swapNeedsCleanup)
    }

    @Test func cancellationIntentAlwaysWinsOverTakeRecovery() {
        #expect(ReplacementSessionDisposition.classify(
            hasCancellationMarker: true
        ) == .discard)
        #expect(ReplacementSessionDisposition.classify(
            hasCancellationMarker: false
        ) == .recover)
    }

    @Test func rendererKeepsTimelineDurationToOneFrame() async throws {
        let masterURL = try TestAudio.makeWAV(seconds: 2, amplitude: 0.2)
        let takeURL = try TestAudio.makeWAV(seconds: 0.5, amplitude: 0.7)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "replacement-render-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: masterURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: takeURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.copyItem(at: masterURL, to: directory.appending(path: "master.wav"))
        try FileManager.default.copyItem(at: takeURL, to: directory.appending(path: "take.wav"))
        var recipe = ReplacementRecipe.master(fileName: "master.wav", duration: 2)
        let region = ReplacementRegion(
            selection: AudioRangeSelection(start: 0.75, end: 1.25),
            timelineDuration: 2,
            sampleRate: 44_100
        )
        recipe = recipe.replacing(
            region: region,
            with: ReplacementSource(
                id: UUID(), kind: .take, fileName: "take.wav", frameCount: region.frameCount
            )
        )
        let output = directory.appending(path: "candidate.m4a")
        let rendered = try await AudioReplacementRenderer.render(
            recipe: recipe, sourcesDirectory: directory, outputURL: output
        )
        #expect(abs(rendered.duration - 2) <= 1 / 44_100)
    }

    @Test func replacementRestoreKeepsMatchingHistoryWithEachVersion() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "replacement-restore-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let entryPath = "transcride-2026-07-11T20-00-00-replace"
        let entry = root.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.write("old", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("stale-waveform", to: entry.appending(path: "waveform.json"))
        try AtomicFile.write("---\nduration: 2.00\n---\nEdited\n", to: entry.appending(path: "transcript.md"))
        let history = entry.appending(
            path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try AtomicFile.write("old-history", to: history.appending(path: "marker"))
        let next = entry.appending(
            path: AudioReplacementArtifacts.nextDirectoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try AtomicFile.write("new-history", to: next.appending(path: "marker"))
        let rendered = entry.appending(path: AudioReplacementArtifacts.candidateFileName)
        try AtomicFile.write("new", to: rendered)

        _ = try AudioReplacementApplier(vaultRoot: root).apply(
            renderedFileAt: rendered,
            nextHistoryDirectory: next,
            expectedSourceFileName: "audio.m4a",
            duration: 2,
            toEntryAt: entryPath
        )
        #expect(try String(contentsOf: entry.appending(path: "audio.m4a"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: history.appending(path: "marker"), encoding: .utf8) == "new-history")
        // The old cache is versioned with the displaced audio. Until the
        // caller generates a cache from the committed file, the entry has no
        // waveform rather than displaying stale peaks for the new revision.
        #expect(!FileManager.default.fileExists(atPath: entry.appending(path: "waveform.json").path))

        let store = TrashStore(vaultRoot: root)
        let old = try #require(try store.items().first(where: { $0.kind == .preReplacementAudio }))
        _ = try store.restore(old)
        #expect(try String(contentsOf: entry.appending(path: "audio.m4a"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: history.appending(path: "marker"), encoding: .utf8) == "old-history")
        #expect(try String(
            contentsOf: entry.appending(path: "waveform.json"), encoding: .utf8
        ) == "stale-waveform")
        #expect(try store.items().contains(where: { $0.kind == .preReplacementAudio }))
    }

    @Test func failedReplacementDoesNotInvalidateCanonicalWaveform() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "replacement-waveform-failure-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let entryPath = "transcride-2026-07-11T20-00-01-replace"
        let entry = root.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.write("old", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("current-waveform", to: entry.appending(path: "waveform.json"))
        let next = entry.appending(
            path: AudioReplacementArtifacts.nextDirectoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let rendered = entry.appending(path: AudioReplacementArtifacts.candidateFileName)
        try AtomicFile.write("candidate", to: rendered)

        #expect(throws: AudioReplacementError.self) {
            _ = try AudioReplacementApplier(vaultRoot: root).apply(
                renderedFileAt: rendered,
                nextHistoryDirectory: next,
                expectedSourceFileName: "different.m4a",
                duration: 2,
                toEntryAt: entryPath
            )
        }
        #expect(try String(
            contentsOf: entry.appending(path: "waveform.json"), encoding: .utf8
        ) == "current-waveform")
    }

    @Test func oneHundredOverlappingBakesNeverDriftOrCapSlices() {
        var recipe = ReplacementRecipe.master(fileName: "master.m4a", duration: 60)
        for index in 0..<100 {
            let start = Double((index * 17) % 550) / 10
            let region = ReplacementRegion(
                selection: AudioRangeSelection(start: start, end: start + 2),
                timelineDuration: 60,
                sampleRate: 44_100
            )
            recipe = recipe.replacing(
                region: region,
                with: ReplacementSource(
                    id: UUID(), kind: .take,
                    fileName: "take-\(index).m4a", frameCount: region.frameCount
                )
            )
            #expect(recipe.totalFrames == 2_646_000)
            #expect(recipe.isDurationPreserving)
            #expect(ReplacementRenderPlan.make(recipe: recipe) != nil)
        }
    }
}
