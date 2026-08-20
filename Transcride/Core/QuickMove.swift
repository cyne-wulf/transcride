import Foundation

/// A candidate folder for the Quick Move picker. `path` is vault-relative;
/// the empty path is the vault root.
struct QuickMoveDestination: Identifiable, Hashable, Sendable {
    let path: RelativePath

    var id: String { path }

    var isVaultRoot: Bool { path.isEmpty }

    var title: String { isVaultRoot ? "Vault Root" : path }

    var leafName: String {
        isVaultRoot ? "Vault Root" : path.lastComponent
    }
}

/// Pure destination enumeration and query filtering for Move Note… (no file
/// IO): the picker lists every existing folder except the note's current
/// parent, and ranks typed queries deterministically.
enum QuickMoveModel {
    /// All move destinations for an entry: the vault root plus every folder,
    /// excluding the entry's current parent. Empty-query order is Vault Root
    /// first, then remaining paths in natural (Finder-like) order.
    static func destinations(
        folderPaths: [RelativePath],
        excludingParentOf entryPath: RelativePath
    ) -> [QuickMoveDestination] {
        let parent = entryPath.parentRelativePath
        var seen: Set<RelativePath> = []
        var paths: [RelativePath] = []
        for path in [""] + folderPaths {
            guard path != parent, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
            .sorted { a, b in
                if a.isEmpty != b.isEmpty { return a.isEmpty }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map(QuickMoveDestination.init(path:))
    }

    /// Match quality, ordered best-first. Leaf-name matches outrank full-path
    /// matches; exact > prefix > substring > fuzzy subsequence.
    private enum Rank: Int, Comparable {
        case leafExact, leafPrefix, leafSubstring
        case pathExact, pathPrefix, pathSubstring
        case leafFuzzy, pathFuzzy

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func filtered(
        _ destinations: [QuickMoveDestination],
        query rawQuery: String
    ) -> [QuickMoveDestination] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return destinations }

        let ranked: [(QuickMoveDestination, Rank)] = destinations.compactMap { destination in
            rank(destination, query: query).map { (destination, $0) }
        }
        // Stable: sort only by rank; equal ranks keep the natural input order.
        return ranked
            .enumerated()
            .sorted { a, b in
                if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
                return a.offset < b.offset
            }
            .map(\.element.0)
    }

    private static func rank(_ destination: QuickMoveDestination, query: String) -> Rank? {
        let leaf = destination.leafName.lowercased()
        let path = destination.title.lowercased()
        if leaf == query { return .leafExact }
        if leaf.hasPrefix(query) { return .leafPrefix }
        if leaf.contains(query) { return .leafSubstring }
        if path == query { return .pathExact }
        if path.hasPrefix(query) { return .pathPrefix }
        if path.contains(query) { return .pathSubstring }
        if isFuzzyMatch(query, in: leaf) { return .leafFuzzy }
        if isFuzzyMatch(query, in: path) { return .pathFuzzy }
        return nil
    }

    /// Ordered-subsequence match ("prj" matches "Projects").
    private static func isFuzzyMatch(_ query: String, in candidate: String) -> Bool {
        var index = candidate.startIndex
        for character in query {
            guard let found = candidate[index...].firstIndex(of: character) else {
                return false
            }
            index = candidate.index(after: found)
        }
        return true
    }
}

/// Outcome of a Move Note attempt, reported back to the picker so it can stay
/// open with an inline error instead of silently dismissing on failure.
enum QuickMoveOutcome: Equatable, Sendable {
    case moved(RelativePath)
    case destinationMissing
    case collision(String)
    case failed(String)

    var isSuccess: Bool {
        if case .moved = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .moved:
            nil
        case .destinationMissing:
            "That folder no longer exists. Pick another destination."
        case .collision(let name):
            "\(name) already exists in that folder, so the note was not moved."
        case .failed(let message):
            message
        }
    }
}
