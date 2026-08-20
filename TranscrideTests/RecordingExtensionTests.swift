import AVFoundation
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
            selectedSegmentFileName: RecordingExtensionArtifacts.partialFileName,
            hasValidCombinedOutput: false,
            hasArtifacts: true,
            manifest: nil
        ) == .partialCapture)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.segmentM4AFileName,
            hasValidCombinedOutput: false,
            hasArtifacts: true,
            manifest: nil
        ) == .finalizedSegment)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.segmentM4AFileName,
            hasValidCombinedOutput: true,
            hasArtifacts: true,
            manifest: nil
        ) == .combinedAwaitingSwap)
        let swapping = RecordingExtensionSession(target: target, phase: .swapping)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.segmentM4AFileName,
            hasValidCombinedOutput: false,
            hasArtifacts: true,
            manifest: swapping
        ) == .swapNeedsCleanup)
    }

    @Test func provisionalManifestAndPartialClassifyAsRecoverableCapture() {
        let provisional = RecordingExtensionSession(target: target)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.partialFileName,
            hasValidCombinedOutput: false,
            hasArtifacts: true,
            manifest: provisional
        ) == .partialCapture)
    }

    @Test func ordinaryStartupRollbackRemovesOnlyProvisionalArtifacts() throws {
        let entry = FileManager.default.temporaryDirectory.appending(
            path: "extension-startup-rollback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: entry) }
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let manifestURL = entry.appending(path: RecordingExtensionArtifacts.manifestFileName)
        let partialURL = entry.appending(path: RecordingExtensionArtifacts.partialFileName)
        let sourceURL = entry.appending(path: target.sourceAudioFileName)
        try Data("manifest".utf8).write(to: manifestURL)
        try Data("partial".utf8).write(to: partialURL)
        try Data("source".utf8).write(to: sourceURL)

        RecordingExtensionArtifacts.rollbackProvisionalStartup(in: entry)

        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(try Data(contentsOf: sourceURL) == Data("source".utf8))
    }

    @Test func availabilityReasonsAreSpecific() {
        #expect(RecordingExtensionBlockReason.noAudio.explanation.contains("no audio"))
        #expect(RecordingExtensionBlockReason.transcriptionBusy.explanation.contains("transcription"))
        #expect(RecordingExtensionBlockReason.entryBusy("trimming").explanation.contains("trimming"))
        #expect(RecordingExtensionBlockReason.recoveryPending.explanation.contains("interrupted"))

        let malformed = RecordingExtensionRecoveryDiscovery(
            malformedEntryPaths: [target.entryRelativePath]
        )
        #expect(malformed.hasUnresolvedRecovery(for: target.entryRelativePath))
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
                try writeValidAudio(to: entry.appending(path: artifact))
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

    @Test func discoveryClassifiesSilentPartialFromHardCrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "extension-silent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryName = "transcride-2026-07-11T04-00-00"
        let entry = root.appending(path: entryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let session = RecordingExtensionSession(target: .init(
            entryRelativePath: entryName,
            sourceAudioFileName: "audio.m4a",
            sourceDuration: 10
        ))
        try JSONEncoder().encode(session).write(
            to: entry.appending(path: RecordingExtensionArtifacts.manifestFileName)
        )
        let silent = try TestAudio.makeWAV(seconds: 0.2, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: silent.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: silent,
            to: entry.appending(path: RecordingExtensionArtifacts.partialFileName)
        )

        let discovery = RecordingExtensionRecovery.discover(inVault: root)
        let recovered = try #require(discovery.recoverable.first)
        let observation = try #require(recovered.microphoneObservation)
        #expect(observation.sessionID == session.id)
        #expect(observation.inspection.frames > 0)
        #expect(observation.inspection.terminalState == .perfectlySilent)
    }

    @Test func discoveryClassifiesZeroFramePartialFromHardCrash() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T04-30-00",
            phase: .capturing
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let partialURL = fixture.entry.appending(
            path: RecordingExtensionArtifacts.partialFileName
        )
        let emptyJournal = try AVAudioFile(
            forWriting: partialURL,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        emptyJournal.close()

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        let observation = try #require(recovered.microphoneObservation)
        #expect(recovered.phase == .partialCapture)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.partialFileName)
        #expect(observation.inspection.terminalState == .noFrames)
    }

    @Test func swappingWithCombinedOutputIsNotMisclassifiedAsCompletedSwap() {
        let session = RecordingExtensionSession(target: target, phase: .swapping)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.segmentM4AFileName,
            hasValidCombinedOutput: true,
            hasArtifacts: true,
            manifest: session
        ) == .combinedAwaitingSwap)
        #expect(RecordingExtensionArtifacts.classify(
            selectedSegmentFileName: RecordingExtensionArtifacts.segmentM4AFileName,
            hasValidCombinedOutput: false,
            hasArtifacts: true,
            manifest: session
        ) == .swapNeedsCleanup)
    }

    @Test func corruptM4ADoesNotShadowValidCAF() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T05-00-00",
            phase: .segmentReady
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeTruncatedM4A(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.segmentM4AFileName
            )
        )
        try writeValidAudio(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.segmentCAFFileName
            )
        )

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .finalizedSegment)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.segmentCAFFileName)
        #expect(recovered.microphoneObservation == nil)
    }

    @Test func validM4AWinsOverValidCAFAndPartial() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T05-30-00",
            phase: .segmentReady
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in RecordingExtensionArtifacts.segmentCandidateFileNames {
            try writeValidAudio(to: fixture.entry.appending(path: name))
        }

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .finalizedSegment)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.segmentM4AFileName)
        #expect(recovered.microphoneObservation == nil)
    }

    @Test func corruptM4ADoesNotShadowValidPartialOrItsMicObservation() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T06-00-00",
            phase: .finalizingSegment
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeTruncatedM4A(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.segmentM4AFileName
            )
        )
        try writeValidAudio(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.partialFileName
            ),
            amplitude: 0
        )

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        let observation = try #require(recovered.microphoneObservation)
        #expect(recovered.phase == .partialCapture)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.partialFileName)
        #expect(observation.sessionID == recovered.session.id)
        #expect(observation.inspection.terminalState == .perfectlySilent)
    }

    @Test func truncatedCommittedSegmentDoesNotShadowIntactPartial() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T06-30-00",
            phase: .finalizingSegment
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A committed CAF copy interrupted a third of the way through: readable
        // end to end, but shorter than the journal it was copied from.
        try writeValidAudio(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.segmentCAFFileName
            ),
            seconds: 0.3
        )
        try writeValidAudio(
            to: fixture.entry.appending(
                path: RecordingExtensionArtifacts.partialFileName
            ),
            seconds: 1.0
        )

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .partialCapture)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.partialFileName)
        #expect(recovered.microphoneObservation != nil)
    }

    @Test func committedSegmentIsStillSelectedWhenItMatchesTheJournal() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T06-45-00",
            phase: .segmentReady
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let segmentURL = fixture.entry.appending(
            path: RecordingExtensionArtifacts.segmentM4AFileName
        )
        let partialURL = fixture.entry.appending(
            path: RecordingExtensionArtifacts.partialFileName
        )
        for url in [segmentURL, partialURL] {
            try writeValidAudio(to: url, seconds: 1.0)
        }
        // The shortfall tolerance exists for container/packet granularity, but
        // the AAC round-trip is in fact frame-exact — which is what production
        // finalization validates. Pin that so a future encoder change cannot
        // quietly start eating into the tolerance.
        let segmentFrames = try AVAudioFile(forReading: segmentURL).length
        let journalFrames = try AVAudioFile(forReading: partialURL).length
        #expect(segmentFrames == journalFrames)

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .finalizedSegment)
        #expect(recovered.segmentFileName == RecordingExtensionArtifacts.segmentM4AFileName)
    }

    @Test func stagedSegmentCAFIsNeverACandidateButIsAlwaysCleanedUp() throws {
        #expect(!RecordingExtensionArtifacts.segmentCandidateFileNames.contains(
            RecordingExtensionArtifacts.stagedSegmentCAFFileName
        ))
        #expect(RecordingExtensionArtifacts.cleanupFileNames.contains(
            RecordingExtensionArtifacts.stagedSegmentCAFFileName
        ))
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T08-30-00",
            phase: .finalizingSegment
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stagedURL = fixture.entry.appending(
            path: RecordingExtensionArtifacts.stagedSegmentCAFFileName
        )
        try writeValidAudio(to: stagedURL)

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .abandonedOutput)
        #expect(recovered.segmentFileName == nil)

        RecordingExtensionRecovery.removeArtifacts(in: fixture.entry)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test func corruptOnlyArtifactsRemainSurfacedAsAbandoned() throws {
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T07-00-00",
            phase: .segmentReady
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in [
            RecordingExtensionArtifacts.segmentM4AFileName,
            RecordingExtensionArtifacts.segmentCAFFileName,
            RecordingExtensionArtifacts.partialFileName,
            RecordingExtensionArtifacts.combinedFileName,
            RecordingExtensionArtifacts.stagedSegmentM4AFileName,
        ] {
            try Data("corrupt \(name)".utf8).write(
                to: fixture.entry.appending(path: name)
            )
        }

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .abandonedOutput)
        #expect(recovered.segmentFileName == nil)
        #expect(recovered.microphoneObservation == nil)
        #expect(discovery.malformedEntryPaths.isEmpty)
        #expect(discovery.hasUnresolvedRecovery(for: recovered.entryRelativePath))
    }

    @Test func stagingArtifactIsNeverSelectedAndCleanupIsIdempotent() throws {
        #expect(
            RecordingExtensionArtifacts.cleanupFileNames.last
                == RecordingExtensionArtifacts.manifestFileName
        )
        let fixture = try makeRecoveryEntry(
            timestamp: "2026-07-11T08-00-00",
            phase: .finalizingSegment
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stagedURL = fixture.entry.appending(
            path: RecordingExtensionArtifacts.stagedSegmentM4AFileName
        )
        try writeValidAudio(to: stagedURL)
        let sourceURL = fixture.entry.appending(path: "audio.m4a")
        try Data("canonical".utf8).write(to: sourceURL)

        let discovery = RecordingExtensionRecovery.discover(inVault: fixture.root)
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.phase == .abandonedOutput)
        #expect(recovered.segmentFileName == nil)

        RecordingExtensionRecovery.removeArtifacts(in: fixture.entry)
        RecordingExtensionRecovery.removeArtifacts(in: fixture.entry)

        for name in RecordingExtensionArtifacts.recoveryFileNames {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.entry.appending(path: name).path
            ))
        }
        #expect(try Data(contentsOf: sourceURL) == Data("canonical".utf8))
    }

    private func makeRecoveryEntry(
        timestamp: String,
        phase: RecordingExtensionPhase
    ) throws -> (root: URL, entry: URL) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "extension-candidate-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let entry = root.appending(
            path: "transcride-\(timestamp)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let session = RecordingExtensionSession(
            target: .init(
                entryRelativePath: entry.lastPathComponent,
                sourceAudioFileName: "audio.m4a",
                sourceDuration: 10
            ),
            phase: phase,
            segmentDuration: 2
        )
        try JSONEncoder().encode(session).write(
            to: entry.appending(path: RecordingExtensionArtifacts.manifestFileName)
        )
        return (root, entry)
    }

    private func writeValidAudio(
        to destination: URL,
        amplitude: Float = 0.25,
        seconds: Double = 0.2
    ) throws {
        let source = try TestAudio.makeWAV(seconds: seconds, amplitude: amplitude)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        if destination.pathExtension.lowercased() == "m4a" {
            try CrashTolerantAudioJournal.encodeM4A(
                from: source,
                to: destination,
                encoding: .aac
            )
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func writeTruncatedM4A(to destination: URL) throws {
        let completeURL = destination.deletingLastPathComponent().appending(
            path: ".complete-segment-\(UUID().uuidString).m4a"
        )
        defer { try? FileManager.default.removeItem(at: completeURL) }
        try writeValidAudio(to: completeURL)
        let complete = try Data(contentsOf: completeURL)
        let truncatedCount = max(1, complete.count / 2)
        try Data(complete.prefix(truncatedCount)).write(to: destination)
    }
}
