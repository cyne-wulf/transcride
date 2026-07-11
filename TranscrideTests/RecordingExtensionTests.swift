import Foundation
import Testing

@Suite("Extend a Recording (EXT)")
struct RecordingExtensionTests {
    private let target = RecordingExtensionTarget(
        entryRelativePath: "transcride-2026-07-11T12-00-00-test",
        sourceAudioFileName: "audio.m4a",
        sourceDuration: 10
    )

    @Test func stateMachineAcceptsTheHappyPath() throws {
        var session = RecordingExtensionSession(target: target)
        try session.transition(to: .paused)
        try session.transition(to: .capturing)
        try session.transition(to: .finalizingSegment)
        try session.transition(to: .segmentReady)
        try session.transition(to: .composing)
        try session.transition(to: .combinedReady)
        try session.transition(to: .swapping)
        try session.transition(to: .retranscribing)
        try session.transition(to: .completed)
        #expect(session.phase == .completed)
        #expect(!session.phase.locksEntryMutation)
    }

    @Test func stateMachineRejectsUnsafeJump() {
        var session = RecordingExtensionSession(target: target)
        #expect(throws: RecordingExtensionError.self) {
            try session.transition(to: .swapping)
        }
        #expect(session.phase == .capturing)
    }

    @Test func failedJoinCanRetryWithoutRecapturing() throws {
        var session = RecordingExtensionSession(target: target, phase: .segmentReady)
        session.fail("Exporter unavailable")
        try session.transition(to: .composing)
        #expect(session.phase == .composing)
        #expect(session.failureMessage == nil)
    }

    @Test func futureDurationAndTolerance() {
        var session = RecordingExtensionSession(target: target)
        session.segmentDuration = 2.25
        #expect(session.futureCombinedDuration == 12.25)

        let plan = RecordingExtensionDurationPlan(sourceDuration: 10, segmentDuration: 2.25)
        #expect(plan.accepts(actualDuration: 12.45))
        #expect(!plan.accepts(actualDuration: 9.9))
        #expect(!plan.accepts(actualDuration: .nan))
    }

    @Test func recoveryClassificationUsesMostAdvancedArtifact() {
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.partialFileName], manifest: nil
        ) == .partialCapture)
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.partialFileName,
                        RecordingExtensionArtifacts.segmentM4AFileName], manifest: nil
        ) == .finalizedSegment)
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.segmentM4AFileName,
                        RecordingExtensionArtifacts.combinedFileName], manifest: nil
        ) == .combinedAwaitingSwap)
        let swapping = RecordingExtensionSession(target: target, phase: .swapping)
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.segmentM4AFileName], manifest: swapping
        ) == .swapNeedsCleanup)
    }

    @Test func availabilityReasonsAreSpecific() {
        #expect(RecordingExtensionBlockReason.noAudio.explanation.contains("no audio"))
        #expect(RecordingExtensionBlockReason.transcriptionBusy.explanation.contains("transcription"))
        #expect(RecordingExtensionBlockReason.entryBusy("trimming").explanation.contains("trimming"))
    }

    @Test func discoveryFindsEachRecoverablePhaseAndSkipsTrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "extension-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeEntry(_ timestamp: String, phase: RecordingExtensionPhase, artifacts: [String]) throws {
            let entry = root.appending(path: "transcride-\(timestamp)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            let session = RecordingExtensionSession(target: .init(
                entryRelativePath: entry.lastPathComponent,
                sourceAudioFileName: "audio.m4a",
                sourceDuration: 10
            ), phase: phase, segmentDuration: 2)
            let encoder = JSONEncoder()
            try encoder.encode(session).write(
                to: entry.appending(path: RecordingExtensionArtifacts.manifestFileName)
            )
            for artifact in artifacts {
                try Data("audio".utf8).write(to: entry.appending(path: artifact))
            }
        }

        try makeEntry(
            "2026-07-11T01-00-00", phase: .capturing,
            artifacts: [RecordingExtensionArtifacts.partialFileName]
        )
        try makeEntry(
            "2026-07-11T02-00-00", phase: .segmentReady,
            artifacts: [RecordingExtensionArtifacts.segmentM4AFileName]
        )
        try makeEntry(
            "2026-07-11T03-00-00", phase: .combinedReady,
            artifacts: [RecordingExtensionArtifacts.segmentM4AFileName,
                        RecordingExtensionArtifacts.combinedFileName]
        )

        let discovery = RecordingExtensionRecovery.discover(inVault: root)
        #expect(discovery.recoverable.map(\.phase) == [
            .partialCapture, .finalizedSegment, .combinedAwaitingSwap,
        ])
        #expect(discovery.malformedEntryPaths.isEmpty)
    }

    @Test func swappingWithCombinedOutputIsNotMisclassifiedAsCompletedSwap() {
        let session = RecordingExtensionSession(target: target, phase: .swapping)
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.combinedFileName,
                        RecordingExtensionArtifacts.segmentM4AFileName],
            manifest: session
        ) == .combinedAwaitingSwap)
        #expect(RecordingExtensionArtifacts.classify(
            fileNames: [RecordingExtensionArtifacts.segmentM4AFileName],
            manifest: session
        ) == .swapNeedsCleanup)
    }
}
