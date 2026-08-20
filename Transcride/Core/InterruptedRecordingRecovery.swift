import AVFoundation
import Foundation

struct InterruptedRecordingRecoveryOutcome: Equatable, Sendable {
    var entryRelativePath: RelativePath
    var audioFileName: String
    var duration: Double
    /// Derived from decoded canonical samples, not merely from duration. A
    /// framed all-zero journal is recoverable evidence, but it is also a
    /// microphone-capture failure and must not be treated as transcribable.
    var microphoneHasSignal: Bool
    var microphoneFrames: Int64
    /// Usually identical to `microphoneHasSignal`. The only exception is a
    /// crash after a validated universal mix was installed: Mac audio may make
    /// the visible canonical file useful even though the mic itself failed.
    var canonicalHasSignal: Bool

    var shouldQueueTranscription: Bool { canonicalHasSignal }
}

struct InterruptedRecordingRecoveryFailure: Equatable, Sendable {
    var entryRelativePath: RelativePath
    var message: String
    /// Available when the partial is readable even though it is too short to
    /// recover. This closes the abrupt-crash window before the live watchdog
    /// or normal teardown could persist a zero/silent-mic event.
    var microphoneTerminalState: MicrophoneTerminalCaptureState? = nil
    var microphoneFrames: Int64 = 0
}

struct InterruptedRecordingRecoverySummary: Equatable, Sendable {
    var recovered: [InterruptedRecordingRecoveryOutcome] = []
    var failures: [InterruptedRecordingRecoveryFailure] = []
    var acknowledgedLegacyPaths: [RelativePath] = []
}

enum InterruptedRecordingRecoveryError: LocalizedError {
    case unreadablePartial
    case emptyPartial
    case visibleAudioConflict
    case exporterUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadablePartial:
            return "The interrupted recording is not readable yet."
        case .emptyPartial:
            return "The interrupted recording does not contain any audio."
        case .visibleAudioConflict:
            return "The entry already contains a different visible audio file."
        case .exporterUnavailable:
            return "The interrupted recording could not be converted to M4A."
        }
    }
}

/// Converges hidden `.recording.caf` files left by abrupt termination into
/// ordinary vault entries. Every destructive cleanup happens only after a
/// readable visible copy, waveform and stub metadata have been produced.
enum InterruptedRecordingRecovery {
    static let temporaryM4AFileName = ".recording-recovery.m4a"
    static let temporaryCAFFileName = ".recording-recovery.caf"
    static let minimumDuration = 0.05
    static let legacyMarkerFileName = ".recording-recovery-legacy.json"
    /// Frame shortfall tolerated when deciding whether an already-visible file
    /// is a completed install rather than a torn finalize copy. Container and
    /// packet granularity make exact equality unrealistic; ~93ms at 44.1kHz is
    /// far below any interrupted copy while remaining inaudible.
    static let adoptableFrameShortfall: Int64 = 4_096

    static func recoverAll(inVault vaultRoot: URL) async -> InterruptedRecordingRecoverySummary {
        var summary = InterruptedRecordingRecoverySummary()
        for entryURL in entryDirectoriesWithPartials(inVault: vaultRoot) {
            let relativePath = relativePath(of: entryURL, under: vaultRoot)
            do {
                let outcome = try await recover(entryURL: entryURL, relativePath: relativePath)
                summary.recovered.append(outcome)
            } catch {
                let partial = entryURL.appending(path: RecorderPartialFile.name)
                if isLegacyPacketizedCAF(partial) {
                    acknowledgeLegacyArtifact(in: entryURL, reason: error.localizedDescription)
                    summary.acknowledgedLegacyPaths.append(relativePath)
                } else {
                    let inspection = try? MicrophoneJournalInspector.inspect(partial)
                    summary.failures.append(.init(
                        entryRelativePath: relativePath,
                        message: error.localizedDescription,
                        microphoneTerminalState: inspection.map {
                            MicrophoneTerminalCaptureState.classify(
                                frames: $0.frames,
                                hasSignal: $0.hasSignal
                            )
                        },
                        microphoneFrames: inspection?.frames ?? 0
                    ))
                }
            }
        }
        return summary
    }

    static func recover(
        entryURL: URL, relativePath: RelativePath
    ) async throws -> InterruptedRecordingRecoveryOutcome {
        let fm = FileManager.default
        let partialURL = entryURL.appending(path: RecorderPartialFile.name)
        guard fm.fileExists(atPath: partialURL.path) else {
            throw InterruptedRecordingRecoveryError.unreadablePartial
        }

        let existingNames = ((try? fm.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        if let existingAudio = VaultScanner.audioFile(in: existingNames) {
            // A crash after the visible install but before hidden cleanup is
            // an idempotent recovery continuation, not a reason to duplicate.
            guard existingAudio == "audio.m4a" || existingAudio == "audio.caf" else {
                throw InterruptedRecordingRecoveryError.visibleAudioConflict
            }
            let audioURL = entryURL.appending(path: existingAudio)
            let microphoneInspection = try MicrophoneJournalInspector.inspect(partialURL)
            let visibleInspection = try? MicrophoneJournalInspector.inspect(audioURL)
            if await shouldRebuildTruncatedVisibleAudio(
                entryURL: entryURL,
                partialURL: partialURL,
                microphoneFrames: microphoneInspection.frames,
                visibleFrames: visibleInspection?.frames
            ) {
                // The visible file is a strict prefix of the retained journal,
                // so removing it loses nothing and the rebuild below restores
                // the missing tail.
                try fm.removeItem(at: audioURL)
            } else {
                let duration = try await validatedDuration(of: audioURL)
                let canonicalInspection = try visibleInspection
                    ?? MicrophoneJournalInspector.inspect(audioURL)
                try await finishMetadata(
                    entryURL: entryURL, audioURL: audioURL, duration: duration
                )
                // The partial is also the discovery/retry marker. Retire it
                // only after hidden continuation artifacts have been swept.
                cleanupTemporaryFiles(in: entryURL)
                try fm.removeItem(at: partialURL)
                return .init(
                    entryRelativePath: relativePath,
                    audioFileName: existingAudio,
                    duration: duration,
                    microphoneHasSignal: microphoneInspection.hasSignal,
                    microphoneFrames: microphoneInspection.frames,
                    canonicalHasSignal: canonicalInspection.hasSignal
                )
            }
        }

        let partialDuration = try await validatedDuration(of: partialURL)
        let microphoneInspection = try MicrophoneJournalInspector.inspect(partialURL)
        let temporaryM4A = entryURL.appending(path: temporaryM4AFileName)
        let temporaryCAF = entryURL.appending(path: temporaryCAFFileName)
        try cleanupRecoveryStagingFiles(in: entryURL)

        let stagedURL: URL
        let finalName: String
        do {
            let asset = AVURLAsset(url: partialURL)
            guard let exporter = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough
            ) else {
                throw InterruptedRecordingRecoveryError.exporterUnavailable
            }
            try await exporter.export(to: temporaryM4A, as: .m4a)
            _ = try await validatedDuration(of: temporaryM4A)
            stagedURL = temporaryM4A
            finalName = "audio.m4a"
        } catch {
            // Container conversion is optional for recovery. Preserve the
            // known-readable CAF bytes through a hidden staged copy.
            try fm.copyItem(at: partialURL, to: temporaryCAF)
            _ = try await validatedDuration(of: temporaryCAF)
            stagedURL = temporaryCAF
            finalName = "audio.caf"
        }

        let finalURL = entryURL.appending(path: finalName)
        let waveform = try await WaveformGenerator.generate(fromAudioAt: stagedURL)
        if TranscriptFile.url(inEntry: entryURL) == nil {
            let created = EntryFolderName(parsing: entryURL.lastPathComponent)?.date ?? .now
            try EntryCreator.writeRecordingStub(
                entryURL: entryURL, created: created, duration: partialDuration
            )
        } else {
            try EntryMetadata.setDuration(partialDuration, inEntry: entryURL)
        }
        try fm.moveItem(at: stagedURL, to: finalURL)
        try waveform.write(to: WaveformData.url(inEntry: entryURL))
        // Keep the authoritative microphone journal discoverable until the
        // visible copy, metadata, and all hidden artifacts are safe.
        cleanupTemporaryFiles(in: entryURL)
        try fm.removeItem(at: partialURL)

        return .init(
            entryRelativePath: relativePath,
            audioFileName: finalName,
            duration: partialDuration,
            microphoneHasSignal: microphoneInspection.hasSignal,
            microphoneFrames: microphoneInspection.frames,
            canonicalHasSignal: microphoneInspection.hasSignal
        )
    }

    /// A visible file that is strictly shorter than the retained microphone
    /// journal is a torn finalize copy, not a completed install: adopting it
    /// would publish a truncated recording and then delete the only complete
    /// audio. Rebuilding from the journal restores the missing tail.
    private static func shouldRebuildTruncatedVisibleAudio(
        entryURL: URL,
        partialURL: URL,
        microphoneFrames: Int64,
        visibleFrames: Int64?
    ) async -> Bool {
        // Only the unfinished-finalize window is eligible. Finalization writes
        // the transcript stub after the visible audio, so a torn copy never has
        // one — while a finished entry's audio may legitimately be shorter than
        // a stale journal (after a trim, for example) and must be left alone.
        guard TranscriptFile.url(inEntry: entryURL) == nil else { return false }
        if let visibleFrames,
           visibleFrames + adoptableFrameShortfall >= microphoneFrames {
            return false
        }
        // Never discard the only file that opens: a short visible copy beside
        // an unusable journal is still the best audio this entry has.
        guard microphoneFrames > 0,
              (try? await validatedDuration(of: partialURL)) != nil else { return false }
        return true
    }

    private static func validatedDuration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw InterruptedRecordingRecoveryError.unreadablePartial
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= minimumDuration else {
            throw InterruptedRecordingRecoveryError.emptyPartial
        }
        return duration
    }

    private static func finishMetadata(
        entryURL: URL, audioURL: URL, duration: Double
    ) async throws {
        let waveform = try await WaveformGenerator.generate(fromAudioAt: audioURL)
        if TranscriptFile.url(inEntry: entryURL) == nil {
            let created = EntryFolderName(parsing: entryURL.lastPathComponent)?.date ?? .now
            try EntryCreator.writeRecordingStub(
                entryURL: entryURL, created: created, duration: duration
            )
        } else {
            try EntryMetadata.setDuration(duration, inEntry: entryURL)
        }
        try waveform.write(to: WaveformData.url(inEntry: entryURL))
    }

    private static func entryDirectoriesWithPartials(inVault root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  EntryFolderName(parsing: url.lastPathComponent) != nil else { continue }
            enumerator.skipDescendants()
            if FileManager.default.fileExists(
                atPath: url.appending(path: RecorderPartialFile.name).path
            ), !FileManager.default.fileExists(
                atPath: url.appending(path: legacyMarkerFileName).path
            ) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func relativePath(of url: URL, under root: URL) -> RelativePath {
        let prefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    private static func cleanupRecoveryStagingFiles(in entryURL: URL) throws {
        try removeFilesIfPresent(
            named: [temporaryM4AFileName, temporaryCAFFileName],
            in: entryURL
        )
    }

    /// Terminal cleanup for every interrupted universal-recording
    /// continuation. Deliberately best-effort: by the time it runs, the visible
    /// audio and its metadata are already durable, so one undeletable hidden
    /// artifact must not abort recovery — that would leave `.recording.caf` in
    /// place and re-run the same failure on every launch, permanently. A
    /// stranded hidden artifact is inert (nothing discovers it once the journal
    /// is gone); an entry that can never finish recovering is not.
    private static func cleanupTemporaryFiles(in entryURL: URL) {
        let fileNames = [temporaryM4AFileName, temporaryCAFFileName]
            + UniversalRecordingArtifacts.interruptedRecoveryCleanupFileNames
        for fileName in fileNames {
            try? FileManager.default.removeItem(at: entryURL.appending(path: fileName))
        }
    }

    private static func removeFilesIfPresent(
        named fileNames: [String], in entryURL: URL
    ) throws {
        let fm = FileManager.default
        for fileName in fileNames {
            let url = entryURL.appending(path: fileName)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Another idempotent continuation may already have removed it.
            }
        }
    }

    /// Pre-fix builds journaled variable-packet AAC/ALAC. An abrupt exit
    /// omitted the packet table, so decoders cannot determine packet sizes
    /// even though encoded bytes remain. Recognize that exact legacy format
    /// from the CAF description chunk and acknowledge it once without
    /// deleting or renaming the original partial.
    private static func isLegacyPacketizedCAF(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32,
              String(data: data[0..<4], encoding: .ascii) == "caff",
              String(data: data[8..<12], encoding: .ascii) == "desc"
        else { return false }
        let format = String(data: data[28..<32], encoding: .ascii)
        return format == "alac" || format == "aac "
    }

    private static func acknowledgeLegacyArtifact(in entryURL: URL, reason: String) {
        let marker: [String: String] = [
            "status": "legacy_packet_table_missing",
            "reason": reason,
            "partial": RecorderPartialFile.name,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? AtomicFile.write(
                data, to: entryURL.appending(path: legacyMarkerFileName)
            )
        }
    }
}

/// Core cannot depend on the app-layer RecorderService, so the shared hidden
/// filename lives in this tiny contract.
enum RecorderPartialFile {
    static let name = ".recording.caf"
}

/// Shared hidden-file contract for the optional universal recording path.
/// Keeping these names in Core lets abrupt-crash recovery converge artifacts
/// created by the app layer without duplicating privacy-sensitive filenames.
enum UniversalRecordingArtifacts {
    static let systemAudioFileName = ".recording-system-audio.sparse"
    static let mixedJournalFileName = ".recording-mixed.caf"
    static let stagedCanonicalAudioFileName = ".audio-finalizing.m4a"
    /// Staging name for the lossless fallback. The visible `audio.caf` is only
    /// ever created by renaming this file, so an interrupted copy can never
    /// masquerade as installed canonical audio.
    static let stagedCanonicalCAFFileName = ".audio-finalizing.caf"

    static let interruptedRecoveryCleanupFileNames = [
        systemAudioFileName,
        mixedJournalFileName,
        stagedCanonicalAudioFileName,
        stagedCanonicalCAFFileName,
    ]
}
