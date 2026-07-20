import Foundation

/// One folder that can receive an entry through Move Note. The vault root uses
/// the empty relative path everywhere on disk, but gets a readable UI label.
struct QuickMoveDestination: Identifiable, Hashable, Sendable {
    var relativePath: RelativePath

    var id: RelativePath { relativePath }
    var displayName: String { relativePath.isEmpty ? "Vault Root" : relativePath }
    var leafName: String { relativePath.isEmpty ? "Vault Root" : relativePath.lastComponent }
}

/// Match precedence is intentional: a leaf-name match is more useful than the
/// same match found only in a parent path, while exact/prefix/substring quality
/// takes precedence over fuzziness.
enum QuickMoveMatchKind: Int, Hashable, Sendable {
    case leafExact
    case pathExact
    case leafPrefix
    case pathPrefix
    case leafSubstring
    case pathSubstring
    case leafFuzzy
    case pathFuzzy
}

struct QuickMoveDestinationMatch: Identifiable, Hashable, Sendable {
    var destination: QuickMoveDestination
    var kind: QuickMoveMatchKind
    /// A lower score is better within one match kind. Match kind always wins
    /// before this score is considered.
    var score: Int

    var id: RelativePath { destination.id }
}

/// Pure destination enumeration and filtering for the Quick Move picker.
/// Results never include the entry's current parent folder.
struct QuickMoveDestinationCatalog: Equatable, Sendable {
    private(set) var destinations: [QuickMoveDestination]

    init(root: FolderNode, movingEntryAt entryPath: RelativePath) {
        self.init(
            folderPaths: root.allFolders.map(\.relativePath),
            excludingCurrentParent: entryPath.parentRelativePath
        )
    }

    /// This initializer keeps the model easy to unit-test without constructing
    /// a complete vault tree. Duplicate paths are ignored.
    init(folderPaths: [RelativePath], excludingCurrentParent currentParent: RelativePath) {
        var seen = Set<RelativePath>()
        destinations = folderPaths
            .filter { $0 != currentParent && seen.insert($0).inserted }
            .map { QuickMoveDestination(relativePath: $0) }
            .sorted(by: Self.destinationComesFirst)
    }

    /// Empty search preserves the browse order: Vault Root first when eligible,
    /// followed by naturally sorted full paths.
    func filteredDestinations(for query: String) -> [QuickMoveDestination] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return destinations }
        return rankedMatches(normalizedQuery: normalizedQuery).map(\.destination)
    }

    /// Exposes match metadata for selection stability, accessibility, and tests;
    /// the picker normally needs only `filteredDestinations(for:)`.
    func rankedMatches(for query: String) -> [QuickMoveDestinationMatch] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        return rankedMatches(normalizedQuery: normalizedQuery)
    }

    private func rankedMatches(normalizedQuery query: String) -> [QuickMoveDestinationMatch] {
        destinations.compactMap { destination in
            Self.match(destination, query: query)
        }.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return Self.destinationComesFirst(lhs.destination, rhs.destination)
        }
    }

    private static func match(
        _ destination: QuickMoveDestination,
        query: String
    ) -> QuickMoveDestinationMatch? {
        let leaf = normalized(destination.leafName)
        let path = normalized(destination.displayName)

        if leaf == query {
            return .init(destination: destination, kind: .leafExact, score: 0)
        }
        if path == query {
            return .init(destination: destination, kind: .pathExact, score: 0)
        }
        if leaf.hasPrefix(query) {
            return .init(
                destination: destination,
                kind: .leafPrefix,
                score: leaf.count - query.count
            )
        }
        if path.hasPrefix(query) {
            return .init(
                destination: destination,
                kind: .pathPrefix,
                score: path.count - query.count
            )
        }
        if let offset = substringOffset(of: query, in: leaf) {
            return .init(
                destination: destination,
                kind: .leafSubstring,
                score: offset * 100 + leaf.count - query.count
            )
        }
        if let offset = substringOffset(of: query, in: path) {
            return .init(
                destination: destination,
                kind: .pathSubstring,
                score: offset * 100 + path.count - query.count
            )
        }
        if let score = fuzzyScore(query: query, candidate: leaf) {
            return .init(destination: destination, kind: .leafFuzzy, score: score)
        }
        if let score = fuzzyScore(query: query, candidate: path) {
            return .init(destination: destination, kind: .pathFuzzy, score: score)
        }
        return nil
    }

    private static func substringOffset(of query: String, in candidate: String) -> Int? {
        guard let range = candidate.range(of: query) else { return nil }
        return candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    }

    /// Supports both close misspellings/transpositions and Obsidian-style
    /// ordered-subsequence queries (for example, "prj" → "Projects").
    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        var scores: [Int] = []

        let maximumDistance = query.count >= 10 ? 3 : (query.count >= 6 ? 2 : 1)
        let distance = damerauLevenshtein(
            query,
            candidate,
            maximum: maximumDistance
        )
        if distance <= maximumDistance {
            scores.append(distance * 100 + abs(candidate.count - query.count))
        }
        if let subsequence = subsequenceScore(query: query, candidate: candidate) {
            // Keep edit-distance corrections ahead of abbreviation matches when
            // both are possible, while retaining a stable score within fuzzy.
            scores.append(1_000 + subsequence)
        }
        return scores.min()
    }

    private static func subsequenceScore(query: String, candidate: String) -> Int? {
        let queryCharacters = Array(query)
        let candidateCharacters = Array(candidate)
        guard queryCharacters.count < candidateCharacters.count else { return nil }

        var searchIndex = 0
        var firstMatch: Int?
        var previousMatch: Int?
        var gaps = 0
        for character in queryCharacters {
            guard let match = candidateCharacters[searchIndex...].firstIndex(of: character) else {
                return nil
            }
            firstMatch = firstMatch ?? match
            if let previousMatch { gaps += max(0, match - previousMatch - 1) }
            previousMatch = match
            searchIndex = match + 1
            if searchIndex > candidateCharacters.count { return nil }
        }
        return (firstMatch ?? 0) * 10 + gaps * 4
            + candidateCharacters.count - queryCharacters.count
    }

    private static func damerauLevenshtein(
        _ lhs: String,
        _ rhs: String,
        maximum: Int
    ) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > maximum { return maximum + 1 }

        var previousPrevious = Array(0...b.count)
        var previous = previousPrevious
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    current[j - 1] + 1,
                    previous[j] + 1,
                    previous[j - 1] + cost
                )
                if i > 1, j > 1,
                   a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previousPrevious[j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maximum { return maximum + 1 }
            previousPrevious = previous
            previous = current
        }
        return previous[b.count]
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "/", with: " ")
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func destinationComesFirst(
        _ lhs: QuickMoveDestination,
        _ rhs: QuickMoveDestination
    ) -> Bool {
        if lhs.relativePath.isEmpty != rhs.relativePath.isEmpty {
            return lhs.relativePath.isEmpty
        }
        let comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.relativePath < rhs.relativePath
    }
}

/// Pure picker-selection behavior shared by the SwiftUI surface and tests.
/// A stale selection (for example, after a watched folder disappears) falls
/// back to the first remaining result, and arrow movement clamps at the ends.
enum QuickMoveSelection {
    static func reconciled(
        current: RelativePath?,
        destinationPaths: [RelativePath]
    ) -> RelativePath? {
        guard !destinationPaths.isEmpty else { return nil }
        if let current, destinationPaths.contains(current) { return current }
        return destinationPaths[0]
    }

    static func moved(
        current: RelativePath?,
        destinationPaths: [RelativePath],
        offset: Int
    ) -> RelativePath? {
        guard !destinationPaths.isEmpty else { return nil }
        let currentIndex = current.flatMap { destinationPaths.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : 0)
        let nextIndex = min(
            max(currentIndex + offset, 0),
            destinationPaths.count - 1
        )
        return destinationPaths[nextIndex]
    }
}

struct QuickMoveSuccess: Equatable, Sendable {
    var sourcePath: RelativePath
    var destinationFolder: RelativePath
    var movedPath: RelativePath
}

enum QuickMoveFailure: Error, Equatable, Sendable {
    case unavailable(String)
    case sourceMissing(RelativePath)
    case destinationMissing(RelativePath)
    case destinationCollision(entryName: String, destinationFolder: RelativePath)
    case fileSystem(String)

    static func classify(
        _ error: Error,
        sourcePath: RelativePath,
        destinationFolder: RelativePath
    ) -> QuickMoveFailure {
        if let vaultError = error as? VaultError {
            switch vaultError {
            case .notFound(let path) where path == sourcePath:
                return .sourceMissing(sourcePath)
            case .notFound(let path) where path == destinationFolder:
                return .destinationMissing(destinationFolder)
            case .alreadyExists(let name):
                return .destinationCollision(
                    entryName: name,
                    destinationFolder: destinationFolder
                )
            case .invalidName, .notFound:
                return .fileSystem(vaultError.localizedDescription)
            }
        }
        return .fileSystem(error.localizedDescription)
    }
}

extension QuickMoveFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .sourceMissing(let path):
            return "The note at “\(path)” is no longer available."
        case .destinationMissing(let path):
            let name = path.isEmpty ? "Vault Root" : path
            return "The destination “\(name)” is no longer available."
        case .destinationCollision(let entryName, let destinationFolder):
            let folder = destinationFolder.isEmpty ? "Vault Root" : destinationFolder
            return "A note named “\(entryName)” already exists in “\(folder)”."
        case .fileSystem(let message):
            return message
        }
    }
}

typealias QuickMoveResult = Result<QuickMoveSuccess, QuickMoveFailure>
