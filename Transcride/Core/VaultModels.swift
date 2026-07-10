import Foundation

/// Vault-relative paths use "/" separators; "" is the vault root.
typealias RelativePath = String

extension RelativePath {
    var parentRelativePath: RelativePath {
        guard let slash = lastIndex(of: "/") else { return "" }
        return String(self[..<slash])
    }

    var lastComponent: String {
        guard let slash = lastIndex(of: "/") else { return self }
        return String(self[index(after: slash)...])
    }

    func appendingComponent(_ name: String) -> RelativePath {
        isEmpty ? name : self + "/" + name
    }
}

extension URL {
    func appendingRelativePath(_ relPath: RelativePath) -> URL {
        relPath.isEmpty ? self : appending(path: relPath, directoryHint: .isDirectory)
    }
}

/// One entry (a `transcride-<timestamp>` folder) as shown in the library.
struct Entry: Identifiable, Hashable, Sendable {
    var relativePath: RelativePath
    var folderName: EntryFolderName
    var title: String?
    var created: Date
    var duration: Double?
    var snippet: String
    var favorite: Bool
    var audioDeleted: Bool
    /// Name of the entry's audio file (prefers `audio.*`, else first by name);
    /// nil when the entry has no visible audio file.
    var audioFileName: String?
    var hasTranscript: Bool
    /// Name of the entry's markdown file (`transcript.md` until titled, then
    /// `<Title>.md`); nil when the entry has no transcript yet.
    var transcriptFileName: String?

    var id: String { relativePath }
    var parentRelativePath: RelativePath { relativePath.parentRelativePath }
    var hasAudio: Bool { audioFileName != nil }

    /// Why audio-dependent actions (retranscribe, trim, speaker detection,
    /// share audio) are greyed out; nil when the entry's audio is available.
    /// The disk is the source of truth: a restored audio file re-enables the
    /// actions even if a stale `audio_deleted` flag lingers in frontmatter.
    var audioUnavailableExplanation: String? {
        if hasAudio { return nil }
        if audioDeleted {
            return "The audio was deleted. Restore it from Recently Deleted to use audio features."
        }
        return "This entry has no audio file."
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let slug = folderName.slug {
            return slug.split(separator: "-").joined(separator: " ").capitalized
        }
        return created.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A non-entry subfolder of the vault (or the vault root itself, relativePath "").
struct FolderNode: Identifiable, Hashable, Sendable {
    var relativePath: RelativePath
    var name: String
    var subfolders: [FolderNode]
    var entries: [Entry]

    var id: String { relativePath }

    /// nil when empty so OutlineGroup hides the disclosure triangle.
    var outlineChildren: [FolderNode]? { subfolders.isEmpty ? nil : subfolders }

    func folder(at relPath: RelativePath) -> FolderNode? {
        if relativePath == relPath { return self }
        for sub in subfolders {
            if let found = sub.folder(at: relPath) { return found }
        }
        return nil
    }

    /// Self plus all descendants, depth-first.
    var allFolders: [FolderNode] {
        [self] + subfolders.flatMap(\.allFolders)
    }

    var totalEntryCount: Int {
        entries.count + subfolders.reduce(0) { $0 + $1.totalEntryCount }
    }
}

/// Immutable scan result handed from the background scanner to the UI.
struct VaultSnapshot: Sendable {
    var root: FolderNode

    func folder(at relPath: RelativePath) -> FolderNode? {
        root.folder(at: relPath)
    }

    func entry(withID id: String) -> Entry? {
        root.allFolders.lazy.compactMap { $0.entries.first(where: { $0.id == id }) }.first
    }
}

enum VaultError: LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "“\(name)” is not a valid name."
        case .alreadyExists(let name):
            return "“\(name)” already exists."
        case .notFound(let path):
            return "“\(path)” could not be found."
        }
    }
}
