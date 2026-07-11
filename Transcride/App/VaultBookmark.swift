import Foundation

/// Persists the chosen vault as a security-scoped bookmark so the sandboxed
/// app can reopen it across launches.
enum VaultBookmark {
    static let defaultsKey = "vaultBookmark"
    private static let recentDefaultsKey = "recentVaultBookmarksV1"

    struct RecentVault: Identifiable, Equatable {
        let url: URL

        var id: String { Self.canonicalPath(for: url) }

        fileprivate static func canonicalPath(for url: URL) -> String {
            url.standardizedFileURL.path
        }
    }

    private struct StoredRecentVault: Codable, Equatable {
        var path: String
        var bookmark: Data
    }

    static func save(_ url: URL) throws {
        let data = try bookmarkData(for: url)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Adds a security-scoped bookmark to the three-item MRU independently of
    /// the current-vault bookmark used for relaunch restoration.
    static func recordRecent(_ url: URL) throws {
        let path = RecentVault.canonicalPath(for: url)
        let newRecord = StoredRecentVault(path: path, bookmark: try bookmarkData(for: url))
        let existing = storedRecents()
        let orderedPaths = RecentVaultHistory.recording(path, in: existing.map(\.path))
        var recordsByPath = existing.reduce(into: [String: StoredRecentVault]()) {
            $0[$1.path] = $1
        }
        recordsByPath[path] = newRecord
        saveRecents(orderedPaths.compactMap { recordsByPath[$0] })
    }

    static func resolveRecents() -> [RecentVault] {
        var refreshedRecords: [StoredRecentVault] = []
        var results: [RecentVault] = []

        for record in storedRecents() {
            guard let resolved = resolve(record.bookmark) else { continue }
            let path = RecentVault.canonicalPath(for: resolved.url)
            guard !results.contains(where: { $0.id == path }) else { continue }

            results.append(RecentVault(url: resolved.url))
            let bookmark: Data
            if resolved.isStale {
                let accessing = resolved.url.startAccessingSecurityScopedResource()
                bookmark = (try? bookmarkData(for: resolved.url)) ?? record.bookmark
                if accessing { resolved.url.stopAccessingSecurityScopedResource() }
            } else {
                bookmark = record.bookmark
            }
            refreshedRecords.append(StoredRecentVault(path: path, bookmark: bookmark))
        }

        if refreshedRecords != storedRecents() {
            saveRecents(Array(refreshedRecords.prefix(RecentVaultHistory.maximumCount)))
        }
        return Array(results.prefix(RecentVaultHistory.maximumCount))
    }

    static func forgetRecent(_ recent: RecentVault) {
        let remainingPaths = RecentVaultHistory.forgetting(
            recent.id,
            in: storedRecents().map(\.path)
        )
        let recordsByPath = storedRecents().reduce(into: [String: StoredRecentVault]()) {
            $0[$1.path] = $1
        }
        saveRecents(remainingPaths.compactMap { recordsByPath[$0] })
    }

    /// Resolves the stored bookmark. The caller is responsible for
    /// `startAccessingSecurityScopedResource` on the returned URL.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        guard let resolved = resolve(data) else { return nil }
        if resolved.isStale {
            // Refresh the bookmark; requires momentary access.
            let accessing = resolved.url.startAccessingSecurityScopedResource()
            try? save(resolved.url)
            if accessing { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return resolved.url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }

    private static func storedRecents() -> [StoredRecentVault] {
        guard let data = UserDefaults.standard.data(forKey: recentDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([StoredRecentVault].self, from: data)) ?? []
    }

    private static func saveRecents(_ records: [StoredRecentVault]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: recentDefaultsKey)
    }
}
