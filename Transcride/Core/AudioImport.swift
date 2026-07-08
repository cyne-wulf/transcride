import AVFoundation
import Foundation

enum AudioImportError: LocalizedError {
    case unsupportedType(fileName: String)
    case unreadable(fileName: String)
    case noAudioTrack(fileName: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "\(name): file type is not supported."
        case .unreadable(let name):
            return "\(name): the file could not be read as audio (corrupt or misnamed?)."
        case .noAudioTrack(let name):
            return "\(name): the video has no audio track."
        }
    }
}

/// Accepted import formats (PRD-2): m4a/aac, mp3, wav, flac, ogg/opus, aiff,
/// plus the audio track of mp4/mov videos. Detection is by file extension;
/// actual readability is verified by `probeDuration` before an entry is created.
enum AudioImportFormat {
    static let audioExtensions: Set<String> = [
        "m4a", "aac", "mp3", "wav", "flac", "ogg", "opus", "aiff", "aif",
    ]
    static let videoExtensions: Set<String> = ["mp4", "mov"]
    static var supportedExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    static func isSupported(fileName: String) -> Bool {
        supportedExtensions.contains(normalizedExtension(of: fileName))
    }

    static func isVideo(fileName: String) -> Bool {
        videoExtensions.contains(normalizedExtension(of: fileName))
    }

    static func normalizedExtension(of fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }

    /// File name the imported copy gets inside the entry folder: the original
    /// name with characters unsafe for the vault stripped (never hidden, no
    /// path separators or colons), original extension preserved.
    static func importedFileName(forSourceName sourceName: String) -> String {
        var name = sourceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "audio" }
        return name
    }

    /// Default entry title for an import: the source file name without extension.
    static func title(forSourceName sourceName: String) -> String {
        let base = (sourceName as NSString).deletingPathExtension
        return base.isEmpty ? sourceName : base
    }

    /// Verifies the file is decodable audio and returns its duration in
    /// seconds. Throws a per-file `AudioImportError` for corrupt/misnamed
    /// files or videos without an audio track.
    static func probeDuration(of url: URL) async throws -> Double {
        let fileName = url.lastPathComponent
        guard isSupported(fileName: fileName) else {
            throw AudioImportError.unsupportedType(fileName: fileName)
        }
        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        let duration: Double
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
        } catch {
            throw AudioImportError.unreadable(fileName: fileName)
        }
        guard !audioTracks.isEmpty else {
            throw isVideo(fileName: fileName)
                ? AudioImportError.noAudioTrack(fileName: fileName)
                : AudioImportError.unreadable(fileName: fileName)
        }
        guard duration.isFinite, duration > 0 else {
            throw AudioImportError.unreadable(fileName: fileName)
        }
        return duration
    }
}
