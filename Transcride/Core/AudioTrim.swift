import AVFoundation
import Foundation

/// The kept range of a trim (AUD-3), in seconds from the start of the audio.
struct TrimSelection: Equatable, Sendable {
    var start: Double
    var end: Double

    /// Anything shorter than this is a slip of the hand, not a memo.
    static let minimumKeptSeconds = 0.5
    /// Handles resting within this distance of an edge count as untouched.
    static let edgeTolerance = 0.05

    var length: Double { max(0, end - start) }

    func clamped(toDuration duration: Double) -> TrimSelection {
        let start = min(max(0, start), duration)
        return TrimSelection(start: start, end: min(max(start, end), duration))
    }

    /// A selection is worth applying only when it keeps a playable length and
    /// actually crops something off at least one edge.
    func isValidCrop(ofDuration duration: Double) -> Bool {
        guard duration > 0 else { return false }
        let clamped = clamped(toDuration: duration)
        guard clamped.length >= Self.minimumKeptSeconds else { return false }
        return clamped.start > Self.edgeTolerance
            || clamped.end < duration - Self.edgeTolerance
    }
}

enum AudioTrimError: LocalizedError {
    case exporterUnavailable

    var errorDescription: String? {
        switch self {
        case .exporterUnavailable:
            return "The audio could not be exported on this system."
        }
    }
}

/// Crops an audio file to a `TrimSelection` (AUD-3). m4a sources are trimmed
/// losslessly (passthrough keeps AAC/ALAC packets untouched); every other
/// format — and the audio track of imported videos — is re-encoded to AAC in
/// an m4a container, because AVFoundation cannot write mp3/flac/ogg.
enum AudioTrimExport {
    /// Name the trimmed copy gets inside the entry folder: the source name
    /// when the container survives, otherwise the base name with `.m4a`.
    static func trimmedFileName(forSource name: String) -> String {
        if AudioImportFormat.normalizedExtension(of: name) == "m4a" { return name }
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "audio" : base) + ".m4a"
    }

    /// Exports the kept range to a throwaway temp directory. The caller moves
    /// the result into place and removes the directory.
    static func export(
        from sourceURL: URL, keeping selection: TrimSelection
    ) async throws -> (url: URL, fileName: String) {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let clamped = selection.clamped(toDuration: duration)
        let range = CMTimeRange(
            start: CMTime(seconds: clamped.start, preferredTimescale: 600),
            end: CMTime(seconds: clamped.end, preferredTimescale: 600)
        )

        let fileName = trimmedFileName(forSource: sourceURL.lastPathComponent)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcride-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: fileName)

        if AudioImportFormat.normalizedExtension(of: sourceURL.lastPathComponent) == "m4a" {
            do {
                try await run(asset: asset, preset: AVAssetExportPresetPassthrough,
                              range: range, to: outputURL)
                return (outputURL, fileName)
            } catch {
                // Some codec/container combinations refuse passthrough;
                // fall through to the re-encode below.
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        try await run(asset: asset, preset: AVAssetExportPresetAppleM4A,
                      range: range, to: outputURL)
        return (outputURL, fileName)
    }

    private static func run(
        asset: AVURLAsset, preset: String, range: CMTimeRange, to url: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AudioTrimError.exporterUnavailable
        }
        session.timeRange = range
        try await session.export(to: url, as: .m4a)
    }
}

/// Frontmatter touch-ups shared by the trim paths.
enum EntryMetadata {
    /// Rewrites the entry's frontmatter `duration`, leaving everything else
    /// alone. A no-op when the entry has no transcript file.
    static func setDuration(_ duration: Double, inEntry entryURL: URL) throws {
        guard let url = TranscriptFile.url(inEntry: entryURL),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var doc = FrontmatterDocument.parse(text)
        doc.duration = duration
        try AtomicFile.write(doc.serialized(), to: url)
    }
}

/// The file dance after a successful trim export: pre-trim audio (and its
/// stale waveform cache) to Recently Deleted, trimmed file in, frontmatter
/// duration updated. Ordered so a crash at any point leaves the entry either
/// intact or as a plain note with the original audio restorable — never
/// without valid audio somewhere.
struct TrimApplier: Sendable {
    let vaultRoot: URL

    struct Outcome: Sendable {
        /// The pre-trim audio's wrapper name inside `.trash/`.
        var trashedName: String
        /// The trimmed file's name inside the entry folder.
        var audioFileName: String
        var newDuration: Double
    }

    func apply(
        trimmedFileAt trimmedURL: URL,
        fileName: String,
        newDuration: Double,
        toEntryAt relPath: RelativePath,
        date: Date = Date()
    ) throws -> Outcome {
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw VaultError.notFound(relPath)
        }
        let trash = TrashStore(vaultRoot: vaultRoot)
        let trashedName = try trash.trashPreTrimAudio(atEntryPath: relPath, deletedAt: date)
        try FileManager.default.moveItem(at: trimmedURL, to: entryURL.appending(path: fileName))
        // Stale metadata must not fail the trim — the files are already
        // consistent, and the next retranscription refreshes the note anyway.
        try? EntryMetadata.setDuration(newDuration, inEntry: entryURL)
        return Outcome(trashedName: trashedName, audioFileName: fileName, newDuration: newDuration)
    }
}
