import AVFoundation
import Foundation

struct InterruptedRecordingRecoveryOutcome: Equatable, Sendable {
    var entryRelativePath: RelativePath
    var audioFileName: String
    var duration: Double
}

struct InterruptedRecordingRecoveryFailure: Equatable, Sendable {
    var entryRelativePath: RelativePath
    var message: String
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
                    summary.failures.append(.init(
                        entryRelativePath: relativePath,
                        message: error.localizedDescription
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
            let duration = try await validatedDuration(of: audioURL)
            try await finishMetadata(
                entryURL: entryURL, audioURL: audioURL, duration: duration
            )
            try? fm.removeItem(at: partialURL)
            cleanupTemporaryFiles(in: entryURL)
            return .init(
                entryRelativePath: relativePath,
                audioFileName: existingAudio,
                duration: duration
            )
        }

        let partialDuration = try await validatedDuration(of: partialURL)
        let temporaryM4A = entryURL.appending(path: temporaryM4AFileName)
        let temporaryCAF = entryURL.appending(path: temporaryCAFFileName)
        cleanupTemporaryFiles(in: entryURL)

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
        try fm.removeItem(at: partialURL)
        cleanupTemporaryFiles(in: entryURL)

        return .init(
            entryRelativePath: relativePath,
            audioFileName: finalName,
            duration: partialDuration
        )
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

    private static func cleanupTemporaryFiles(in entryURL: URL) {
        try? FileManager.default.removeItem(at: entryURL.appending(path: temporaryM4AFileName))
        try? FileManager.default.removeItem(at: entryURL.appending(path: temporaryCAFFileName))
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
