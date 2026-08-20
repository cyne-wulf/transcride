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
    /// crash after a validated universal mix was installed, or one this
    /// recovery rendered itself: Mac audio may make the visible canonical file
    /// useful even though the mic itself failed.
    var canonicalHasSignal: Bool
    /// True when this recovery rendered the retained Mac-audio sidecar into the
    /// canonical file it published, rather than recovering the microphone
    /// journal alone.
    var mixedSystemAudio: Bool = false

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
    /// Journals rebuilt inside `.trash`, kept in a separate channel from
    /// `recovered` on purpose: these entries are deleted, so they must never be
    /// enqueued for transcription or fed to the search index. They surface only
    /// as a notice telling the user the audio is restorable from Recently
    /// Deleted. Paths are `.trash`-relative to the vault root.
    var recoveredInTrash: [InterruptedRecordingRecoveryOutcome] = []
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
    /// How long an abandoned Mac-audio sidecar is kept once its microphone
    /// journal is gone. Nothing consumes it automatically — its chunks are
    /// positioned by frame index on a journal that no longer exists — but
    /// destroying it the moment an offline mix fails turns one transient error
    /// into permanent loss of half a meeting. The bytes are kept for a salvage
    /// window and then swept so they cannot accumulate.
    static let abandonedSystemAudioSalvageAge: TimeInterval = 7 * 24 * 3_600

    static func recoverAll(inVault vaultRoot: URL) async -> InterruptedRecordingRecoverySummary {
        var summary = InterruptedRecordingRecoverySummary()
        // Safety net for a live recording whose entry — or whose ancestor
        // folder — was deleted mid-capture. The journal rode along into
        // `.trash`, which the ordinary scan skips as a hidden directory, and
        // Empty Trash would then destroy the only copy of the audio. Rebuilding
        // it in place makes the recording restorable from Recently Deleted.
        for entryURL in scanEntryDirectories(
            inVault: vaultRoot.appending(
                path: TrashStore.directoryName, directoryHint: .isDirectory
            )
        ).withPartials {
            let relativePath = relativePath(of: entryURL, under: vaultRoot)
            guard let outcome = try? await recover(
                entryURL: entryURL, relativePath: relativePath
            ) else { continue }
            summary.recoveredInTrash.append(outcome)
        }
        let scan = scanEntryDirectories(inVault: vaultRoot)
        // Sidecars kept by a failed offline mix (their microphone journal is
        // long retired) are swept once the salvage window has passed. Trashed
        // entries are deliberately left alone: they are restorable as a unit,
        // and Empty Trash removes the whole folder anyway.
        for sidecarURL in scan.abandonedSystemAudio {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        for entryURL in scan.withPartials {
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
        // A power cut during close()'s size patch leaves a bogus positive
        // data-chunk size that AVFoundation trusts over physical EOF. Restore
        // the crash sentinel before any consumer below opens the journal.
        DurableAudioJournalWriter.repairDataChunkSize(at: partialURL)

        let existingNames = ((try? fm.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        if let existingAudio = VaultScanner.audioFile(in: existingNames) {
            // A crash after the visible install but before hidden cleanup is
            // an idempotent recovery continuation, not a reason to duplicate.
            guard existingAudio == "audio.m4a" || existingAudio == "audio.caf" else {
                throw InterruptedRecordingRecoveryError.visibleAudioConflict
            }
            let audioURL = entryURL.appending(path: existingAudio)
            if existingAudio == "audio.caf" {
                // The CAF fallback is a byte copy of a journal, so it can carry
                // the same torn size patch. A no-op for any other CAF.
                DurableAudioJournalWriter.repairDataChunkSize(at: audioURL)
            }
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

        // A crashed meeting recording is the only moment the microphone journal
        // and the sparse Mac-audio sidecar still coexist: the sidecar positions
        // its chunks by frame index on that journal's timeline, and the journal
        // is retired at the end of this function. A mix not performed here can
        // never be performed at all.
        let mixed = await mixSystemAudioSidecar(
            entryURL: entryURL,
            microphoneURL: partialURL,
            microphoneFrames: microphoneInspection.frames
        )
        let sourceURL = mixed?.url ?? partialURL

        let stagedURL: URL
        let finalName: String
        do {
            let asset = AVURLAsset(url: sourceURL)
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
            //
            // A mixed render is itself derived and recreatable from the journal
            // that is still on disk, so it is renamed rather than copied: a
            // second full-length copy would hold four copies of a long meeting
            // at once for no durability gain.
            if mixed != nil {
                try fm.moveItem(at: sourceURL, to: temporaryCAF)
            } else {
                try fm.copyItem(at: sourceURL, to: temporaryCAF)
            }
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
            canonicalHasSignal: mixed?.hasSignal ?? microphoneInspection.hasSignal,
            mixedSystemAudio: mixed != nil
        )
    }

    private struct RecoveredSystemAudioMix: Sendable {
        var url: URL
        var hasSignal: Bool
    }

    /// Renders the retained Mac-audio sidecar onto the microphone journal so a
    /// crashed meeting recovers with both halves instead of the microphone
    /// alone.
    ///
    /// Returns nil whenever anything is absent, unreadable, or fails
    /// validation; the caller then recovers the microphone journal exactly as
    /// it always has, byte for byte. The renderer refuses to emit anything it
    /// has not proved — its output length is driven solely by the microphone
    /// file, it drains and validates the whole sparse stream, and it reopens
    /// and re-validates the staged result — so a failed mix costs launch time,
    /// never audio. The mix is frame-exact with the journal, so duration,
    /// waveform and transcript alignment are unaffected: it adds Mac audio at
    /// the same frame indices, it never shifts the timeline.
    private static func mixSystemAudioSidecar(
        entryURL: URL,
        microphoneURL: URL,
        microphoneFrames: Int64
    ) async -> RecoveredSystemAudioMix? {
        let fm = FileManager.default
        let sidecarURL = entryURL.appending(
            path: UniversalRecordingArtifacts.systemAudioFileName
        )
        guard microphoneFrames > 0, fm.fileExists(atPath: sidecarURL.path) else { return nil }
        let stagedURL = entryURL.appending(
            path: UniversalRecordingArtifacts.mixedJournalFileName
        )
        do {
            let result = try await Task.detached {
                // Recovery reads what a crash or power cut left: a final
                // sidecar record severed at EOF is expected there and must not
                // forfeit the earlier, intact Mac audio.
                try UniversalRecordingFileMixer.render(
                    microphoneURL: microphoneURL,
                    systemJournalURL: sidecarURL,
                    stagedURL: stagedURL,
                    tailPolicy: .tolerateTruncatedTail
                )
            }.value
            // The renderer already validated the staged file's own length and
            // format. This ties it to the journal this recovery is actually
            // publishing, and reports whether the canonical result is
            // transcribable even when the microphone itself captured nothing.
            guard result.frames == microphoneFrames else {
                throw UniversalRecordingFileMixError.invalidOutput
            }
            let inspection = try MicrophoneJournalInspector.inspect(stagedURL)
            guard inspection.frames == microphoneFrames else {
                throw UniversalRecordingFileMixError.invalidOutput
            }
            return .init(url: stagedURL, hasSignal: inspection.hasSignal)
        } catch {
            try? fm.removeItem(at: stagedURL)
            return nil
        }
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

    /// One walk, two answers. `abandonedSystemAudio` holds Mac-audio sidecars
    /// whose microphone journal is gone *and* whose bytes have outlived the
    /// salvage window. Both conditions matter: a live capture always has its
    /// `.recording.caf` in place (the sink journal is created at start, the
    /// sidecar lazily at the first meaningful signal, strictly later), and the
    /// age gate means even that ordering does not have to be trusted.
    private static func scanEntryDirectories(
        inVault root: URL
    ) -> (withPartials: [URL], abandonedSystemAudio: [URL]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }
        var results: [URL] = []
        var abandoned: [URL] = []
        let cutoff = Date().addingTimeInterval(-abandonedSystemAudioSalvageAge)
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  EntryFolderName(parsing: url.lastPathComponent) != nil else { continue }
            enumerator.skipDescendants()
            let hasPartial = fm.fileExists(
                atPath: url.appending(path: RecorderPartialFile.name).path
            )
            if hasPartial, !fm.fileExists(
                atPath: url.appending(path: legacyMarkerFileName).path
            ) {
                results.append(url)
            }
            guard !hasPartial else { continue }
            let sidecarURL = url.appending(
                path: UniversalRecordingArtifacts.systemAudioFileName
            )
            let modified = (try? sidecarURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            if let modified, modified < cutoff { abandoned.append(sidecarURL) }
        }
        return (results.sorted { $0.path < $1.path }, abandoned.sorted { $0.path < $1.path })
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
