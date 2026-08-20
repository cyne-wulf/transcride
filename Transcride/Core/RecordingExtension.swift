import AVFoundation
import Foundation

/// Stable identity captured when the user starts extending an entry. The
/// source file name is retained so a rename/replacement cannot silently make
/// the finalized segment target different audio.
struct RecordingExtensionTarget: Codable, Equatable, Sendable {
    var entryRelativePath: RelativePath
    var sourceAudioFileName: String
    var sourceDuration: Double
}

/// Pure state model for the append lifecycle. AppModel owns the live instance;
/// the same phases are persisted beside recovery artifacts on disk.
enum RecordingExtensionPhase: String, Codable, CaseIterable, Sendable {
    case capturing
    case paused
    case finalizingSegment
    case segmentReady
    case composing
    case combinedReady
    case swapping
    case retranscribing
    case completed
    case failed

    var locksEntryMutation: Bool { self != .completed && self != .failed }
}

struct RecordingExtensionSession: Codable, Equatable, Sendable {
    var id: UUID
    var target: RecordingExtensionTarget
    var phase: RecordingExtensionPhase
    var segmentDuration: Double
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        target: RecordingExtensionTarget,
        phase: RecordingExtensionPhase = .capturing,
        segmentDuration: Double = 0,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.target = target
        self.phase = phase
        self.segmentDuration = segmentDuration
        self.failureMessage = failureMessage
    }

    var futureCombinedDuration: Double {
        max(0, target.sourceDuration) + max(0, segmentDuration)
    }

    mutating func transition(to next: RecordingExtensionPhase) throws {
        guard Self.allowedTransitions[phase, default: []].contains(next) else {
            throw RecordingExtensionError.invalidTransition(from: phase, to: next)
        }
        phase = next
        if next != .failed { failureMessage = nil }
    }

    mutating func fail(_ message: String) {
        phase = .failed
        failureMessage = message
    }

    private static let allowedTransitions: [RecordingExtensionPhase: Set<RecordingExtensionPhase>] = [
        .capturing: [.paused, .finalizingSegment, .failed],
        .paused: [.capturing, .finalizingSegment, .failed],
        .finalizingSegment: [.segmentReady, .failed],
        .segmentReady: [.composing, .failed],
        .composing: [.combinedReady, .failed],
        .combinedReady: [.swapping, .failed],
        .swapping: [.retranscribing, .failed],
        .retranscribing: [.completed, .failed],
        .failed: [.composing, .swapping],
        .completed: [],
    ]
}

enum RecordingExtensionBlockReason: Equatable, Sendable {
    case noAudio
    case audioDeleted
    case recorderBusy
    case recoveryPending
    case entryBusy(String)
    case transcriptionBusy
    case unsupportedAudio

    var explanation: String {
        switch self {
        case .noAudio:
            return "This entry has no audio file."
        case .audioDeleted:
            return "Restore this entry's audio from Recently Deleted before extending it."
        case .recorderBusy:
            return "Stop the active recording before extending this entry."
        case .recoveryPending:
            return "Resolve the interrupted extension before recording another segment."
        case .entryBusy(let operation):
            return "Wait for \(operation) to finish before extending this entry."
        case .transcriptionBusy:
            return "Wait for this entry's transcription to finish before extending it."
        case .unsupportedAudio:
            return "This audio cannot be read or exported by AVFoundation."
        }
    }
}

enum RecordingExtensionArtifacts {
    static let manifestFileName = ".extension-state.json"
    static let partialFileName = ".extension-recording.caf"
    static let segmentM4AFileName = ".extension-segment.m4a"
    /// Encode destination used before a validated segment is promoted to the
    /// committed M4A name. Recovery never treats this file as a usable segment.
    static let stagedSegmentM4AFileName = ".extension-segment-finalizing.m4a"
    static let segmentCAFFileName = ".extension-segment.caf"
    /// Copy destination used before the lossless fallback is promoted to the
    /// committed CAF name, so an interrupted copy can never shadow the intact
    /// journal it was copied from. Never a recovery candidate.
    static let stagedSegmentCAFFileName = ".extension-segment-finalizing.caf"
    static let combinedFileName = ".extension-combined.m4a"

    /// Frame shortfall tolerated when a committed segment is compared with the
    /// journal it was derived from. Container/packet granularity makes exact
    /// equality unrealistic; ~93ms at 44.1kHz stays far below any interrupted
    /// copy while remaining inaudible.
    static let segmentFrameShortfallTolerance: Int64 = 4_096

    /// Committed recovery candidates, in preference order. A failed M4A
    /// encode may leave both its destination and the still-valid CAF journal;
    /// discovery must validate each file before honoring this priority.
    static let segmentCandidateFileNames = [
        segmentM4AFileName,
        segmentCAFFileName,
        partialFileName,
    ]

    /// Every hidden artifact that makes an entry relevant to recovery. The
    /// staging files are included so an interrupted encode or copy is
    /// surfaced, but they are deliberately absent from
    /// `segmentCandidateFileNames` because the recorder never validated and
    /// committed them.
    static let cleanupFileNames = [
        stagedSegmentM4AFileName,
        stagedSegmentCAFFileName,
        combinedFileName,
        segmentM4AFileName,
        segmentCAFFileName,
        partialFileName,
        // The manifest is the recovery marker and is intentionally last. A
        // crash during cleanup therefore remains discoverable and retryable.
        manifestFileName,
    ]
    static let recoveryFileNames = Set(cleanupFileNames)

    enum RecoveryPhase: Equatable, Sendable {
        case none
        case partialCapture
        case finalizedSegment
        case combinedAwaitingSwap
        case swapNeedsCleanup
        case abandonedOutput
    }

    static func classify(
        selectedSegmentFileName: String?,
        hasValidCombinedOutput: Bool,
        hasArtifacts: Bool,
        manifest: RecordingExtensionSession?
    ) -> RecoveryPhase {
        // Once the safe swap began, absence of a valid combined staging file
        // means the visible canonical audio may already be installed and only
        // idempotent cleanup remains. That path validates the visible audio and
        // its staged predecessor before it converges.
        if manifest?.phase == .swapping, !hasValidCombinedOutput {
            return .swapNeedsCleanup
        }

        // A combined output is only reconstructible/retryable while one of the
        // committed source segments remains valid. A lone combined/staging file
        // stays visible as abandoned metadata rather than being trusted.
        guard let selectedSegmentFileName else {
            return manifest != nil || hasArtifacts ? .abandonedOutput : .none
        }
        if hasValidCombinedOutput { return .combinedAwaitingSwap }

        switch selectedSegmentFileName {
        case segmentM4AFileName, segmentCAFFileName:
            return .finalizedSegment
        case partialFileName:
            return .partialCapture
        default:
            return .abandonedOutput
        }
    }

    /// A normal startup failure must leave the entry exactly as it was before
    /// the user asked to extend it. A process crash never reaches this method,
    /// so the provisional manifest and canonical CAF remain together for the
    /// existing extension-recovery scan to inspect.
    static func rollbackProvisionalStartup(
        in entryURL: URL,
        fileManager: FileManager = .default
    ) {
        for fileName in [manifestFileName, partialFileName] {
            try? fileManager.removeItem(at: entryURL.appending(path: fileName))
        }
    }
}

struct RecoverableRecordingExtension: Identifiable, Equatable, Sendable {
    var entryRelativePath: RelativePath
    var session: RecordingExtensionSession
    var phase: RecordingExtensionArtifacts.RecoveryPhase
    var segmentFileName: String?
    var microphoneObservation: RecoveredMicrophoneCaptureObservation?

    var id: String { "\(entryRelativePath)|\(session.id.uuidString)" }

    var phaseDescription: String {
        switch phase {
        case .partialCapture: return "Interrupted while recording"
        case .finalizedSegment: return "Recorded segment awaiting append"
        case .combinedAwaitingSwap: return "Combined audio awaiting safe installation"
        case .swapNeedsCleanup: return "Append installed; cleanup interrupted"
        case .abandonedOutput: return "Incomplete extension metadata"
        case .none: return "No recovery needed"
        }
    }
}

struct RecordingExtensionRecoveryDiscovery: Equatable, Sendable {
    var recoverable: [RecoverableRecordingExtension] = []
    var malformedEntryPaths: [RelativePath] = []

    /// Any recovery artifact for this entry must be resolved before a new
    /// extension may create the same manifest/journal names.
    func hasUnresolvedRecovery(for entryRelativePath: RelativePath) -> Bool {
        recoverable.contains { $0.entryRelativePath == entryRelativePath }
            || malformedEntryPaths.contains(entryRelativePath)
    }
}

enum RecordingExtensionRecovery {
    static func discover(inVault root: URL) -> RecordingExtensionRecoveryDiscovery {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return .init() }
        var discovery = RecordingExtensionRecoveryDiscovery()
        for case let entryURL as URL in enumerator {
            guard (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  EntryFolderName(parsing: entryURL.lastPathComponent) != nil else { continue }
            enumerator.skipDescendants()
            let names = Set((try? FileManager.default.contentsOfDirectory(
                atPath: entryURL.path
            )) ?? [])
            guard !names.isDisjoint(
                with: RecordingExtensionArtifacts.recoveryFileNames
            ) else { continue }
            let relPath = relativePath(of: entryURL, under: root)
            let manifestURL = entryURL.appending(
                path: RecordingExtensionArtifacts.manifestFileName
            )
            guard let data = try? Data(contentsOf: manifestURL),
                  let session = try? JSONDecoder().decode(
                    RecordingExtensionSession.self, from: data
                  ) else {
                discovery.malformedEntryPaths.append(relPath)
                continue
            }
            let selectedCandidate = selectValidSegmentCandidate(
                in: entryURL,
                fileNames: names,
                sessionID: session.id
            )
            let combinedURL = entryURL.appending(
                path: RecordingExtensionArtifacts.combinedFileName
            )
            let hasValidCombinedOutput = names.contains(
                RecordingExtensionArtifacts.combinedFileName
            ) && isReadableAudio(at: combinedURL)
            let phase = RecordingExtensionArtifacts.classify(
                selectedSegmentFileName: selectedCandidate?.fileName,
                hasValidCombinedOutput: hasValidCombinedOutput,
                hasArtifacts: !names.isDisjoint(
                    with: RecordingExtensionArtifacts.recoveryFileNames
                ),
                manifest: session
            )
            guard phase != .none else { continue }
            discovery.recoverable.append(.init(
                entryRelativePath: relPath,
                session: session,
                phase: phase,
                segmentFileName: selectedCandidate?.fileName,
                microphoneObservation: phase == .partialCapture
                    ? selectedCandidate?.microphoneObservation
                    : nil
            ))
        }
        discovery.recoverable.sort { $0.entryRelativePath < $1.entryRelativePath }
        discovery.malformedEntryPaths.sort()
        return discovery
    }

    static func removeArtifacts(in entryURL: URL) {
        for name in RecordingExtensionArtifacts.cleanupFileNames {
            try? FileManager.default.removeItem(at: entryURL.appending(path: name))
        }
    }

    private struct ValidSegmentCandidate {
        var fileName: String
        var microphoneObservation: RecoveredMicrophoneCaptureObservation?
    }

    private static func selectValidSegmentCandidate(
        in entryURL: URL,
        fileNames: Set<String>,
        sessionID: UUID
    ) -> ValidSegmentCandidate? {
        // While the journal that a committed segment was derived from is still
        // present, it is also the yardstick for that segment. A committed file
        // shorter than its own source is an interrupted copy or encode, and
        // must never shadow the intact journal.
        let journalFrames: Int64? = fileNames.contains(
            RecordingExtensionArtifacts.partialFileName
        ) ? readableFrameCount(
            at: entryURL.appending(path: RecordingExtensionArtifacts.partialFileName)
        ) : nil

        for fileName in RecordingExtensionArtifacts.segmentCandidateFileNames
        where fileNames.contains(fileName) {
            let url = entryURL.appending(path: fileName)
            if fileName == RecordingExtensionArtifacts.partialFileName {
                guard let inspection = try? MicrophoneJournalInspector.inspect(url) else {
                    continue
                }
                return .init(
                    fileName: fileName,
                    microphoneObservation: .init(
                        sessionID: sessionID,
                        inspection: inspection
                    )
                )
            }
            guard let frames = readableFrameCount(at: url) else { continue }
            if let journalFrames,
               frames + RecordingExtensionArtifacts.segmentFrameShortfallTolerance
                   < journalFrames {
                continue
            }
            return .init(fileName: fileName, microphoneObservation: nil)
        }
        return nil
    }

    private static func isReadableAudio(at url: URL) -> Bool {
        readableFrameCount(at: url) != nil
    }

    /// Synchronously checks a bounded prefix and suffix and reports the frame
    /// count of a file that passes. Opening alone is not sufficient for a
    /// truncated M4A whose header still advertises frames; reading the tail
    /// catches that case without decoding an hours-long clip during vault
    /// discovery.
    private static func readableFrameCount(at url: URL) -> Int64? {
        do {
            let input = try AVAudioFile(forReading: url)
            defer { input.close() }
            guard input.length > 0,
                  input.processingFormat.sampleRate.isFinite,
                  input.processingFormat.sampleRate > 0,
                  input.processingFormat.channelCount > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: 4_096
                  ) else { return nil }

            try input.read(into: buffer, frameCount: 4_096)
            guard buffer.frameLength > 0 else { return nil }

            if input.length > 4_096 {
                input.framePosition = max(0, input.length - 4_096)
                buffer.frameLength = 0
                try input.read(into: buffer, frameCount: 4_096)
                guard buffer.frameLength > 0 else { return nil }
            }
            return Int64(input.length)
        } catch {
            return nil
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> RelativePath {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count))
    }
}

struct RecordingExtensionDurationPlan: Equatable, Sendable {
    var sourceDuration: Double
    var segmentDuration: Double

    var expectedCombinedDuration: Double {
        max(0, sourceDuration) + max(0, segmentDuration)
    }

    /// AAC packet boundaries and priming make exact equality unrealistic.
    /// The relative allowance scales for long recordings while retaining a
    /// useful fixed floor for short clips.
    func accepts(actualDuration: Double, minimumTolerance: Double = 0.35) -> Bool {
        guard actualDuration.isFinite, actualDuration > 0 else { return false }
        let tolerance = max(minimumTolerance, expectedCombinedDuration * 0.01)
        return abs(actualDuration - expectedCombinedDuration) <= tolerance
    }
}

enum RecordingExtensionError: LocalizedError, Equatable {
    case invalidTransition(from: RecordingExtensionPhase, to: RecordingExtensionPhase)
    case segmentTooShort
    case sourceChanged
    case invalidCombinedDuration(expected: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "The extension cannot move from \(from.rawValue) to \(to.rawValue)."
        case .segmentTooShort:
            return "The added recording is too short to append."
        case .sourceChanged:
            return "The entry's audio changed while it was being extended."
        case .invalidCombinedDuration(let expected, let actual):
            return "The combined audio duration was invalid (expected about \(expected), got \(actual))."
        }
    }
}
