import Foundation

/// Scans the vault directory tree into a `VaultSnapshot`. Entry metadata reads
/// are cached by modification date so repeated scans (FSEvents refreshes)
/// only re-read what actually changed. Runs off the main thread (inside
/// `VaultService`); purely read-only — it never writes to the vault.
struct VaultScanner {
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus", "caf", "mp4", "mov",
    ]
    static let transcriptFileName = "transcript.md"

    private struct CachedEntry {
        var folderModified: Date
        var transcriptModified: Date?
        var entry: Entry
    }

    private var cache: [RelativePath: CachedEntry] = [:]

    mutating func scan(root: URL) -> VaultSnapshot {
        var seen = Set<RelativePath>()
        let rootNode = scanFolder(at: root, relativePath: "", name: root.lastPathComponent, seen: &seen)
        cache = cache.filter { seen.contains($0.key) }
        return VaultSnapshot(root: rootNode)
    }

    private mutating func scanFolder(
        at url: URL, relativePath: RelativePath, name: String, seen: inout Set<RelativePath>
    ) -> FolderNode {
        var subfolders: [FolderNode] = []
        var entries: [Entry] = []

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )) ?? []

        for itemURL in contents {
            let itemName = itemURL.lastPathComponent
            if itemName.hasPrefix(".") { continue }
            let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }

            let itemRelPath = relativePath.appendingComponent(itemName)
            if let folderName = EntryFolderName(parsing: itemName) {
                seen.insert(itemRelPath)
                entries.append(loadEntry(at: itemURL, relativePath: itemRelPath, folderName: folderName))
            } else {
                subfolders.append(scanFolder(at: itemURL, relativePath: itemRelPath, name: itemName, seen: &seen))
            }
        }

        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries.sort { $0.created > $1.created }
        return FolderNode(relativePath: relativePath, name: name, subfolders: subfolders, entries: entries)
    }

    private mutating func loadEntry(
        at url: URL, relativePath: RelativePath, folderName: EntryFolderName
    ) -> Entry {
        let folderModified = modificationDate(of: url) ?? .distantPast
        let transcriptURL = url.appending(path: Self.transcriptFileName)
        let transcriptModified = modificationDate(of: transcriptURL)

        if let cached = cache[relativePath],
           cached.folderModified == folderModified,
           cached.transcriptModified == transcriptModified {
            return cached.entry
        }

        var title: String?
        var created = folderName.date ?? folderModified
        var duration: Double?
        var snippet = ""
        var favorite = false
        var audioDeleted = false
        var hasTranscript = false

        if transcriptModified != nil,
           let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            hasTranscript = true
            let doc = FrontmatterDocument.parse(text)
            title = doc.title
            if let fmCreated = doc.created { created = fmCreated }
            duration = doc.duration
            favorite = doc.favorite
            audioDeleted = doc.audioDeleted
            snippet = Self.snippet(fromBody: doc.body)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []
        let hasAudio = contents.contains {
            Self.audioExtensions.contains($0.pathExtension.lowercased())
        }

        let entry = Entry(
            relativePath: relativePath,
            folderName: folderName,
            title: title,
            created: created,
            duration: duration,
            snippet: snippet,
            favorite: favorite,
            audioDeleted: audioDeleted,
            hasAudio: hasAudio,
            hasTranscript: hasTranscript
        )
        cache[relativePath] = CachedEntry(
            folderModified: folderModified,
            transcriptModified: transcriptModified,
            entry: entry
        )
        return entry
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// First ~160 characters of meaningful body text, markdown markers stripped.
    static func snippet(fromBody body: String, limit: Int = 160) -> String {
        var out = ""
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "---" { continue }
            while let first = text.first, "#>-*".contains(first) {
                text.removeFirst()
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += text
            if out.count >= limit { break }
        }
        return String(out.prefix(limit))
    }
}
