import Foundation

/// Naming and discovery of an entry's markdown transcript file.
///
/// Contract: an untitled entry's transcript is `transcript.md`; when the user
/// titles the entry (rename), the file is renamed to `<Title>.md` so the vault
/// reads naturally in Obsidian. Externally created files are never renamed —
/// discovery accepts whatever markdown file the entry folder contains.
enum TranscriptFile {
    static let defaultName = "transcript.md"

    /// Filesystem-safe file name for a titled entry; `transcript.md` when the
    /// title is nil or empty.
    static func fileName(forTitle title: String?) -> String {
        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return defaultName }
        return name + ".md"
    }

    /// Picks the transcript among an entry folder's file names: prefers
    /// `transcript.md`, else the first visible `.md` file alphabetically.
    static func find(in fileNames: [String]) -> String? {
        if fileNames.contains(defaultName) { return defaultName }
        return fileNames
            .filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            .min { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// URL of the entry folder's transcript file, if it has one.
    static func url(inEntry entryURL: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: entryURL.path)) ?? []
        return find(in: names).map { entryURL.appending(path: $0) }
    }
}
