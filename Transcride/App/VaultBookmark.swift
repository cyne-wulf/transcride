import Foundation

/// Persists the chosen vault as a security-scoped bookmark so the sandboxed
/// app can reopen it across launches.
enum VaultBookmark {
    static let defaultsKey = "vaultBookmark"

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Resolves the stored bookmark. The caller is responsible for
    /// `startAccessingSecurityScopedResource` on the returned URL.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            // Refresh the bookmark; requires momentary access.
            let accessing = url.startAccessingSecurityScopedResource()
            try? save(url)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
