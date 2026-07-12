import AVFoundation
import Foundation

/// A duration-preserving range in seconds from the start of an audio timeline.
/// Trim interprets it as the material to keep; Replace interprets it as the
/// material to substitute. Keeping the math here prevents the two tools from
/// developing subtly different clamping and precision behavior.
struct AudioRangeSelection: Equatable, Codable, Sendable {
    var start: Double
    var end: Double

    /// Anything shorter than this is a slip of the hand, not a memo.
    static let minimumKeptSeconds = 0.5
    /// Handles resting within this distance of an edge count as untouched.
    static let edgeTolerance = 0.05

    var length: Double { max(0, end - start) }

    static func normalized(_ first: Double, _ second: Double) -> Self {
        Self(start: min(first, second), end: max(first, second))
    }

    func clamped(toDuration duration: Double) -> AudioRangeSelection {
        let start = min(max(0, start), duration)
        return AudioRangeSelection(start: start, end: min(max(start, end), duration))
    }

    func isValidReplacement(ofDuration duration: Double) -> Bool {
        guard duration > 0 else { return false }
        let clamped = clamped(toDuration: duration)
        return clamped.length >= Self.minimumKeptSeconds
            && clamped.start >= 0
            && clamped.end <= duration
    }

    /// The initial Replace range must occupy enough horizontal waveform space
    /// for both handles to remain distinct. Five seconds is comfortable for
    /// ordinary memos; long recordings use 5% of their timeline instead.
    static func initialReplacementSelection(forDuration duration: Double) -> Self {
        guard duration > 0 else { return Self(start: 0, end: 0) }
        return Self(start: 0, end: min(duration, max(5, duration * 0.05)))
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

/// Pure pointer math for the shared Trim/Replace range selector. The SwiftUI
/// overlay creates one of these when a pointer sequence begins and keeps that
/// target for the entire gesture, so a handle cannot turn into a seek or a
/// region drag after crossing another hit area.
struct AudioRangeSelectionPointerInteraction: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case firstHandle
        case secondHandle
        case region
        case waveform
    }

    /// Allow ordinary click jitter without turning a seek into a range edit.
    /// Three points proved too sensitive with a mouse or trackpad and made the
    /// selected region appear to contain a large, intermittent dead zone.
    static let dragThreshold: Double = 6

    let target: Target
    let initialSelection: AudioRangeSelection
    let pointerDownX: Double
    let width: Double
    let duration: Double

    init(
        selection: AudioRangeSelection,
        duration: Double,
        width: Double,
        pointerDownX: Double,
        handleHitWidth: Double,
        isLocked: Bool
    ) {
        self.initialSelection = selection
        self.duration = duration
        self.width = width
        self.pointerDownX = pointerDownX

        guard !isLocked, duration > 0, width > 0 else {
            target = .waveform
            return
        }

        let startX = Self.x(forTime: selection.start, duration: duration, width: width)
        let endX = Self.x(forTime: selection.end, duration: duration, width: width)
        let hitsFirst = pointerDownX >= startX
            && pointerDownX <= startX + handleHitWidth
        let hitsSecond = pointerDownX >= endX - handleHitWidth
            && pointerDownX <= endX

        if hitsFirst && hitsSecond {
            target = abs(pointerDownX - startX) <= abs(pointerDownX - endX)
                ? .firstHandle : .secondHandle
        } else if hitsFirst {
            target = .firstHandle
        } else if hitsSecond {
            target = .secondHandle
        } else if pointerDownX >= startX && pointerDownX <= endX {
            target = .region
        } else {
            target = .waveform
        }
    }

    func isDrag(at currentX: Double) -> Bool {
        abs(currentX - pointerDownX) >= Self.dragThreshold
    }

    func selection(at currentX: Double) -> AudioRangeSelection {
        guard duration > 0, width > 0, isDrag(at: currentX) else {
            return initialSelection
        }
        let delta = (currentX - pointerDownX) / width * duration
        switch target {
        case .firstHandle:
            return AudioRangeSelection.normalized(
                min(duration, max(0, initialSelection.start + delta)),
                initialSelection.end
            ).clamped(toDuration: duration)
        case .secondHandle:
            return AudioRangeSelection.normalized(
                initialSelection.start,
                min(duration, max(0, initialSelection.end + delta))
            ).clamped(toDuration: duration)
        case .region:
            let length = initialSelection.length
            let nextStart = min(
                max(0, initialSelection.start + delta),
                max(0, duration - length)
            )
            return AudioRangeSelection(start: nextStart, end: nextStart + length)
        case .waveform:
            return initialSelection
        }
    }

    /// Background pointer movement scrubs continuously. A click anywhere seeks
    /// on mouse-up, including inside a handle's enlarged hit target; an actual
    /// handle or region drag edits the selection instead.
    func seekFraction(at currentX: Double) -> Double? {
        guard width > 0 else { return nil }
        switch target {
        case .waveform:
            return min(1, max(0, currentX / width))
        case .firstHandle where !isDrag(at: currentX):
            return min(1, max(0, currentX / width))
        case .secondHandle where !isDrag(at: currentX):
            return min(1, max(0, currentX / width))
        case .region where !isDrag(at: currentX):
            return min(1, max(0, currentX / width))
        case .firstHandle, .secondHandle, .region:
            return nil
        }
    }

    private static func x(forTime time: Double, duration: Double, width: Double) -> Double {
        min(1, max(0, time / duration)) * width
    }
}

/// Source compatibility for the established Trim API.
typealias TrimSelection = AudioRangeSelection

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

    /// Atomic, line-preserving per-entry silence selector update.
    static func setSilenceDetectionMode(
        _ mode: SilenceDetectionMode, inEntry entryURL: URL
    ) throws {
        let url = TranscriptFile.url(inEntry: entryURL)
            ?? entryURL.appending(path: TranscriptFile.defaultName)
        var doc: FrontmatterDocument
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            doc = FrontmatterDocument.parse(text)
        } else {
            doc = FrontmatterDocument(fields: [], body: "")
            doc.created = EntryFolderName(parsing: entryURL.lastPathComponent)?.date
        }
        doc.silenceDetectionMode = mode
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
        try? TranscriptAlignmentState.markStale(inEntry: entryURL)
        return Outcome(trashedName: trashedName, audioFileName: fileName, newDuration: newDuration)
    }
}
