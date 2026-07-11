import AVFoundation
import Foundation

enum AudioExtensionCompositionError: LocalizedError {
    case missingAudioTrack
    case exporterUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack: return "One of the files does not contain a readable audio track."
        case .exporterUnavailable: return "The combined audio could not be exported on this system."
        }
    }
}

enum AudioExtensionFailurePoint: String, Sendable {
    case beforeComposition
    case beforeSafeSwap
    case afterSafeSwap
}

enum AudioExtensionInjectedError: LocalizedError {
    case forced(AudioExtensionFailurePoint)

    var errorDescription: String? {
        switch self {
        case .forced(.beforeComposition):
            return "A test failure was forced before audio composition."
        case .forced(.beforeSafeSwap):
            return "A test failure was forced before the safe audio swap."
        case .forced(.afterSafeSwap):
            return "A test interruption was forced after the safe audio swap."
        }
    }
}

/// One-shot test seam used by the Debug Testing menu and focused tests. The
/// lock makes arming on the main actor and consuming on VaultService safe.
final class AudioExtensionFailureInjector: @unchecked Sendable {
    static let shared = AudioExtensionFailureInjector()

    private let lock = NSLock()
    private var nextPoint: AudioExtensionFailurePoint?

    func arm(_ point: AudioExtensionFailurePoint) {
        lock.lock()
        nextPoint = point
        lock.unlock()
    }

    func consume(_ point: AudioExtensionFailurePoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard nextPoint == point else { return false }
        nextPoint = nil
        return true
    }
}

/// Builds old audio + finalized extension segment into one hidden M4A. The
/// caller owns the later safe swap; this component never touches visible audio.
enum AudioExtensionComposer {
    static let minimumSegmentDuration = 0.15

    struct Output: Sendable {
        var url: URL
        var duration: Double
        var normalized: Bool
    }

    static func compose(sourceURL: URL, segmentURL: URL, outputURL: URL) async throws -> Output {
        let source = AVURLAsset(url: sourceURL)
        let segment = AVURLAsset(url: segmentURL)
        guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first,
              let segmentTrack = try await segment.loadTracks(withMediaType: .audio).first else {
            throw AudioExtensionCompositionError.missingAudioTrack
        }
        let sourceTime = try await source.load(.duration)
        let segmentTime = try await segment.load(.duration)
        let sourceDuration = sourceTime.seconds
        let segmentDuration = segmentTime.seconds
        guard segmentDuration >= minimumSegmentDuration else {
            throw RecordingExtensionError.segmentTooShort
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioExtensionCompositionError.missingAudioTrack
        }
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceTime), of: sourceTrack, at: .zero
        )
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: segmentTime), of: segmentTrack, at: sourceTime
        )

        try? FileManager.default.removeItem(at: outputURL)
        let bothM4A = AudioImportFormat.normalizedExtension(of: sourceURL.lastPathComponent) == "m4a"
            && AudioImportFormat.normalizedExtension(of: segmentURL.lastPathComponent) == "m4a"
        var normalized = !bothM4A
        if bothM4A {
            do {
                try await export(composition, preset: AVAssetExportPresetPassthrough, to: outputURL)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                normalized = true
                try await export(composition, preset: AVAssetExportPresetAppleM4A, to: outputURL)
            }
        } else {
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: outputURL)
        }

        let actual = try await AudioImportFormat.probeDuration(of: outputURL)
        let plan = RecordingExtensionDurationPlan(
            sourceDuration: sourceDuration, segmentDuration: segmentDuration
        )
        guard plan.accepts(actualDuration: actual) else {
            throw RecordingExtensionError.invalidCombinedDuration(
                expected: plan.expectedCombinedDuration, actual: actual
            )
        }
        return Output(url: outputURL, duration: actual, normalized: normalized)
    }

    private static func export(
        _ asset: AVAsset, preset: String, to outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AudioExtensionCompositionError.exporterUnavailable
        }
        try await session.export(to: outputURL, as: .m4a)
    }
}

/// Installs a validated combined audio file without mutating the source in
/// place. The pre-extension version and waveform are retained in Recently
/// Deleted, and the combined output is only made visible after that succeeds.
struct AudioExtensionApplier: Sendable {
    let vaultRoot: URL

    struct Outcome: Sendable {
        var trashedName: String
        var audioFileName: String
        var combinedDuration: Double
    }

    func apply(
        combinedFileAt combinedURL: URL,
        fileName: String,
        combinedDuration: Double,
        previousTranscriptDuration: Double,
        normalizedToM4A: Bool,
        expectedSourceFileName: String,
        toEntryAt relPath: RelativePath,
        date: Date = Date()
    ) throws -> Outcome {
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        let visibleNames = ((try? FileManager.default.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard VaultScanner.audioFile(in: visibleNames) == expectedSourceFileName else {
            throw RecordingExtensionError.sourceChanged
        }

        let trash = TrashStore(vaultRoot: vaultRoot)
        let trashedName = try trash.trashPreExtensionAudio(atEntryPath: relPath, deletedAt: date)
        do {
            try FileManager.default.moveItem(
                at: combinedURL, to: entryURL.appending(path: fileName)
            )
        } catch {
            // Best-effort rollback restores the known-good version. If this
            // itself is interrupted, the trash wrapper remains recoverable.
            if let item = try? trash.items().first(where: { $0.trashedName == trashedName }) {
                _ = try? trash.restore(item)
            }
            throw error
        }
        try? EntryMetadata.setDuration(combinedDuration, inEntry: entryURL)
        try ExtensionTranscriptState(
            knownTranscriptDuration: previousTranscriptDuration,
            combinedAudioDuration: combinedDuration,
            normalizedToM4A: normalizedToM4A
        ).write(to: entryURL)
        return Outcome(
            trashedName: trashedName,
            audioFileName: fileName,
            combinedDuration: combinedDuration
        )
    }
}
