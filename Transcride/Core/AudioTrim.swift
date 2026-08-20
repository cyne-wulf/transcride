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
    /// alone. A no-op when the entry has no transcript file. `editedAt` is
    /// passed by audio *edits* (trim, extend, replace, compress, restore) and
    /// stamps `audio_edited`; recording finalization/recovery leaves it nil.
    ///
    /// A duration refresh never creates a note, and an entry whose transcript
    /// is absent or unreadable is not a reason to fail an audio operation
    /// whose files are already consistent — nor, ever, a reason to fabricate a
    /// replacement note. Both cases return quietly; the next retranscription
    /// refreshes the metadata.
    static func setDuration(
        _ duration: Double, inEntry entryURL: URL, editedAt: Date? = nil
    ) throws {
        do {
            try EntryFrontmatter.update(inEntry: entryURL, createIfMissing: false) { doc in
                doc.duration = duration
                if let editedAt {
                    doc.audioEdited = editedAt
                }
            }
        } catch VaultError.unreadableTranscript, VaultError.notFound {
            return
        }
    }

    /// Atomic, line-preserving per-entry silence selector update.
    ///
    /// Goes through `EntryFrontmatter`, so a transcript that exists but cannot
    /// be read throws instead of being replaced by a stub: flipping a settings
    /// toggle must never be able to destroy a note.
    static func setSilenceDetectionMode(
        _ mode: SilenceDetectionMode, inEntry entryURL: URL
    ) throws {
        try EntryFrontmatter.update(inEntry: entryURL) { doc in
            doc.silenceDetectionMode = mode
        }
    }
}

/// Publishes an edited audio file into an entry folder.
///
/// Two invariants, both of which the earlier trash-then-move ordering broke:
///
/// - **Nothing partial is ever visible.** New bytes are staged under a hidden
///   name inside the *entry* — the same volume as the vault — so the copy that
///   `FileManager.moveItem` degrades to when the vault lives on another volume
///   can no longer leave a truncated `audio.m4a` behind. The staged file is
///   flushed to the device before it is published.
/// - **The entry always has audio.** The previous version is displaced by an
///   atomic exchange and only then handed to Recently Deleted, so no crash can
///   land in a window where the entry has no audio at all.
struct AudioVersionInstaller: Sendable {
    /// How the previous version was moved out of the way.
    enum Mode: Equatable, Sendable {
        /// `RENAME_SWAP`: the names traded contents in one uninterruptible step.
        case exchanged
        /// The fallback for volumes without `RENAME_SWAP`: two renames, with a
        /// brief window in which the visible audio name is absent.
        case renamedAside
        /// The new version has a different name, so it was published beside the
        /// old one and nothing had to move.
        case sideBySide
    }

    /// Where the previous version's bytes ended up, and what to call them.
    struct Displaced: Sendable {
        /// The file inside the entry that now holds the previous version.
        var fileName: String
        /// The name it carried while it was the entry's audio. Recently
        /// Deleted files it under this name so restore stays symmetric.
        var originalName: String
        var mode: Mode
    }

    let entryURL: URL
    /// The entry's current visible audio file.
    let sourceFileName: String
    /// The name the new version takes.
    let finalFileName: String

    var stagedFileName: String { ".\(finalFileName).installing" }
    private var displacedFileName: String { ".\(finalFileName).previous" }

    /// Moves freshly rendered audio into the entry under a hidden name.
    /// Nothing visible changes, so a failure here leaves the entry untouched.
    func stage(_ url: URL) throws -> URL {
        let fm = FileManager.default
        // Already staged: the extension composer and the replacement renderer
        // write straight into the entry under their own hidden names, which is
        // exactly what this would produce, minus a pointless copy.
        if url.deletingLastPathComponent().standardizedFileURL == entryURL.standardizedFileURL,
           url.lastPathComponent.hasPrefix(".") {
            return url
        }
        let staged = entryURL.appending(path: stagedFileName)
        try? fm.removeItem(at: staged)
        do {
            try fm.moveItem(at: url, to: staged)
        } catch {
            // A cross-volume move that fails partway leaves a partial file.
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Makes the staged version the entry's audio and reports where the
    /// previous version went. The caller trashes that file afterwards.
    func publish(stagedAt staged: URL) throws -> Displaced {
        let fm = FileManager.default
        let final = entryURL.appending(path: finalFileName)
        guard finalFileName == sourceFileName else {
            // Different names: publishing cannot touch the old file, so the new
            // version appears beside it. Both are complete for the couple of
            // syscalls until the old one is trashed.
            try AtomicFile.install(fileAt: staged, to: final, durability: .full)
            return Displaced(
                fileName: sourceFileName, originalName: sourceFileName, mode: .sideBySide
            )
        }
        // Same name: the two files must trade places, or the old bytes would be
        // overwritten before they ever reached Recently Deleted.
        try AtomicFile.flushFile(at: staged, durability: .full)
        if try AtomicFile.exchange(staged, final) {
            AtomicFile.syncDirectory(at: entryURL)
            return Displaced(
                fileName: staged.lastPathComponent, originalName: sourceFileName, mode: .exchanged
            )
        }
        // This volume has no atomic exchange. Move the old version aside and
        // publish over the name it vacated: two renames, with a window of a few
        // microseconds in which the entry has no visible audio. The displaced
        // copy is complete and next to it the whole time.
        let aside = entryURL.appending(path: displacedFileName)
        try? fm.removeItem(at: aside)
        try AtomicFile.renameItem(final, to: aside)
        do {
            try AtomicFile.install(fileAt: staged, to: final, durability: .full)
        } catch {
            try? AtomicFile.renameItem(aside, to: final)
            throw error
        }
        return Displaced(
            fileName: displacedFileName, originalName: sourceFileName, mode: .renamedAside
        )
    }

    /// Best-effort return to the pre-publish state, for a failure between the
    /// publish and the trash. The previous version goes back under its own
    /// name and the new version is dropped.
    func rollBack(_ displaced: Displaced) {
        let fm = FileManager.default
        let final = entryURL.appending(path: finalFileName)
        let displacedURL = entryURL.appending(path: displaced.fileName)
        switch displaced.mode {
        case .exchanged:
            if (try? AtomicFile.exchange(displacedURL, final)) == true {
                try? fm.removeItem(at: displacedURL)
            }
        case .renamedAside:
            try? fm.removeItem(at: final)
            try? AtomicFile.renameItem(displacedURL, to: final)
        case .sideBySide:
            try? fm.removeItem(at: final)
        }
    }

    /// Drops a staged file that never became visible.
    func discard(stagedAt staged: URL) {
        try? FileManager.default.removeItem(at: staged)
    }

    /// The entry's current visible audio, or nil when it has none.
    static func currentAudioFileName(inEntry entryURL: URL) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        return VaultScanner.audioFile(in: names)
    }
}

/// The file dance after a successful trim export: the trimmed file is staged
/// inside the entry, exchanged for the pre-trim audio, and only then is that
/// pre-trim version (with its stale waveform cache) handed to Recently Deleted
/// and the frontmatter duration updated. A crash at any point leaves the entry
/// holding one complete version of its audio.
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
        guard let sourceName = AudioVersionInstaller.currentAudioFileName(inEntry: entryURL) else {
            throw VaultError.notFound(relPath.appendingComponent("audio"))
        }
        let installer = AudioVersionInstaller(
            entryURL: entryURL, sourceFileName: sourceName, finalFileName: fileName
        )
        let staged = try installer.stage(trimmedURL)
        let displaced: AudioVersionInstaller.Displaced
        do {
            displaced = try installer.publish(stagedAt: staged)
        } catch {
            installer.discard(stagedAt: staged)
            throw error
        }
        let trash = TrashStore(vaultRoot: vaultRoot)
        let trashedName: String
        do {
            trashedName = try trash.trashPreTrimAudio(
                atEntryPath: relPath, deletedAt: date,
                sourceFileName: displaced.fileName, storedAs: displaced.originalName
            )
        } catch {
            installer.rollBack(displaced)
            throw error
        }
        // Stale metadata must not fail the trim — the files are already
        // consistent, and the next retranscription refreshes the note anyway.
        try? EntryMetadata.setDuration(newDuration, inEntry: entryURL, editedAt: date)
        try? TranscriptAlignmentState.markStale(inEntry: entryURL)
        return Outcome(trashedName: trashedName, audioFileName: fileName, newDuration: newDuration)
    }
}
