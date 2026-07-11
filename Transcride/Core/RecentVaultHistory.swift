import Foundation

/// Pure ordering rules for the recent-vault list. Bookmark creation and
/// persistence stay in the app layer so Core remains sandbox-independent.
enum RecentVaultHistory {
    static let maximumCount = 3

    static func recording(
        _ path: String,
        in existingPaths: [String],
        maximumCount: Int = maximumCount
    ) -> [String] {
        guard maximumCount > 0 else { return [] }
        return ([path] + existingPaths.filter { $0 != path })
            .prefix(maximumCount)
            .map { $0 }
    }

    static func forgetting(_ path: String, in existingPaths: [String]) -> [String] {
        existingPaths.filter { $0 != path }
    }
}
