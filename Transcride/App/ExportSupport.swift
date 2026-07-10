import Foundation

/// Remembers the last "Export Markdown…" destination folder across launches
/// (EXP-2) as an app-scoped security bookmark, mirroring `VaultBookmark`.
/// The folder is only used to pre-select the export panel's directory — each
/// export is re-granted by the user's panel choice.
enum ExportDestination {
    static let defaultsKey = "exportDestinationBookmark"

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

/// Obsidian URI-scheme interop (Tier 4 of obsidian-compatibility.md): opening
/// a file by absolute path lets Obsidian resolve which of its vaults contains
/// it, so we never need to know the vault's registered name.
enum ObsidianLink {
    /// An Obsidian vault is any folder Obsidian has opened (it creates
    /// `.obsidian/` inside). Checks the folder and a few ancestors so exports
    /// into a vault's subfolder still count.
    static func isObsidianVault(_ folder: URL) -> Bool {
        var current = folder.standardizedFileURL
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: current.appending(path: ".obsidian").path
            ) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return false
    }

    static func openURL(forPath absolutePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: absolutePath)]
        return components.url
    }
}
