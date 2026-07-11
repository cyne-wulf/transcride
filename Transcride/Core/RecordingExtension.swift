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
    static let segmentCAFFileName = ".extension-segment.caf"
    static let combinedFileName = ".extension-combined.m4a"

    enum RecoveryPhase: Equatable, Sendable {
        case none
        case partialCapture
        case finalizedSegment
        case combinedAwaitingSwap
        case swapNeedsCleanup
        case abandonedOutput
    }

    static func classify(fileNames: Set<String>, manifest: RecordingExtensionSession?) -> RecoveryPhase {
        if fileNames.contains(combinedFileName) {
            return .combinedAwaitingSwap
        }
        if manifest?.phase == .swapping { return .swapNeedsCleanup }
        if fileNames.contains(segmentM4AFileName) || fileNames.contains(segmentCAFFileName) {
            return .finalizedSegment
        }
        if fileNames.contains(partialFileName) { return .partialCapture }
        if manifest != nil { return .abandonedOutput }
        return .none
    }
}

struct RecoverableRecordingExtension: Identifiable, Equatable, Sendable {
    var entryRelativePath: RelativePath
    var session: RecordingExtensionSession
    var phase: RecordingExtensionArtifacts.RecoveryPhase
    var segmentFileName: String?

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
            let artifactNames: Set<String> = [
                RecordingExtensionArtifacts.manifestFileName,
                RecordingExtensionArtifacts.partialFileName,
                RecordingExtensionArtifacts.segmentM4AFileName,
                RecordingExtensionArtifacts.segmentCAFFileName,
                RecordingExtensionArtifacts.combinedFileName,
            ]
            guard !names.isDisjoint(with: artifactNames) else { continue }
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
            let phase = RecordingExtensionArtifacts.classify(
                fileNames: names, manifest: session
            )
            guard phase != .none else { continue }
            let segmentName: String?
            if names.contains(RecordingExtensionArtifacts.segmentM4AFileName) {
                segmentName = RecordingExtensionArtifacts.segmentM4AFileName
            } else if names.contains(RecordingExtensionArtifacts.segmentCAFFileName) {
                segmentName = RecordingExtensionArtifacts.segmentCAFFileName
            } else if names.contains(RecordingExtensionArtifacts.partialFileName) {
                segmentName = RecordingExtensionArtifacts.partialFileName
            } else {
                segmentName = nil
            }
            discovery.recoverable.append(.init(
                entryRelativePath: relPath,
                session: session,
                phase: phase,
                segmentFileName: segmentName
            ))
        }
        discovery.recoverable.sort { $0.entryRelativePath < $1.entryRelativePath }
        discovery.malformedEntryPaths.sort()
        return discovery
    }

    static func removeArtifacts(in entryURL: URL) {
        for name in [
            RecordingExtensionArtifacts.manifestFileName,
            RecordingExtensionArtifacts.partialFileName,
            RecordingExtensionArtifacts.segmentM4AFileName,
            RecordingExtensionArtifacts.segmentCAFFileName,
            RecordingExtensionArtifacts.combinedFileName,
        ] {
            try? FileManager.default.removeItem(at: entryURL.appending(path: name))
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
