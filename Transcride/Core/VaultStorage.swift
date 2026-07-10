import Foundation

/// One entry's audio footprint, for the Storage pane's ranked list (AUD-6).
struct EntryAudioSize: Identifiable, Equatable, Sendable {
    var entryRelativePath: RelativePath
    var audioBytes: Int64

    var id: String { entryRelativePath }
}

/// Where the vault's bytes live. "Audio" is every audio/video file in live
/// entries; "text" is everything else outside the trash (markdown, transcript
/// JSON, waveform caches, dot-folders like `.transcride`/`.obsidian`);
/// "trash" is all of Recently Deleted including its sidecars — so the three
/// buckets sum to what Finder reports for the vault folder.
struct VaultStorageSummary: Equatable, Sendable {
    var audioBytes: Int64 = 0
    var textBytes: Int64 = 0
    var trashBytes: Int64 = 0
    /// Entries with audio, largest first, capped by `measure(topAudioCount:)`.
    var largestAudioEntries: [EntryAudioSize] = []

    var totalBytes: Int64 { audioBytes + textBytes + trashBytes }
}

/// Read-only size accounting for the Storage settings pane. One filesystem
/// walk; runs on the VaultService actor, never the main thread.
enum VaultStorage {
    static func measure(vaultRoot: URL, topAudioCount: Int = 10) -> VaultStorageSummary {
        var summary = VaultStorageSummary()
        var audioByEntry: [RelativePath: Int64] = [:]
        walk(directory: vaultRoot, relativePath: "", entryPath: nil,
             summary: &summary, audioByEntry: &audioByEntry)
        summary.largestAudioEntries = audioByEntry
            .map { EntryAudioSize(entryRelativePath: $0.key, audioBytes: $0.value) }
            .sorted {
                if $0.audioBytes != $1.audioBytes { return $0.audioBytes > $1.audioBytes }
                return $0.entryRelativePath < $1.entryRelativePath
            }
            .prefix(topAudioCount)
            .map { $0 }
        return summary
    }

    private static func walk(
        directory: URL,
        relativePath: RelativePath,
        entryPath: RelativePath?,
        summary: inout VaultStorageSummary,
        audioByEntry: inout [RelativePath: Int64]
    ) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )) ?? []
        for url in contents {
            let name = url.lastPathComponent
            let itemRelPath = relativePath.appendingComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if relativePath.isEmpty && name == TrashStore.directoryName {
                    summary.trashBytes += directorySize(url)
                    continue
                }
                let childEntry = entryPath
                    ?? (EntryFolderName(parsing: name) != nil ? itemRelPath : nil)
                walk(directory: url, relativePath: itemRelPath, entryPath: childEntry,
                     summary: &summary, audioByEntry: &audioByEntry)
            } else {
                let size = Int64(values?.fileSize ?? 0)
                let ext = (name as NSString).pathExtension.lowercased()
                if VaultScanner.audioExtensions.contains(ext), !name.hasPrefix(".") {
                    summary.audioBytes += size
                    if let entryPath {
                        audioByEntry[entryPath, default: 0] += size
                    }
                } else {
                    summary.textBytes += size
                }
            }
        }
    }

    /// Every byte under `directory`, uncategorized (used for `.trash`).
    private static func directorySize(_ directory: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
