import Foundation

/// Entry-list sort options (LIB-4). Raw values are persisted in UserDefaults.
enum EntrySortOrder: String, CaseIterable, Sendable {
    case dateNewest = "date"
    case duration = "duration"
    case title = "title"
    case recentlyEdited = "recently-edited"

    var displayName: String {
        switch self {
        case .dateNewest: return "Date"
        case .duration: return "Duration"
        case .title: return "Title"
        case .recentlyEdited: return "Recently Edited"
        }
    }

    var defaultDirection: EntrySortDirection {
        self == .title ? .ascending : .descending
    }

    /// Returns the entries in this order. Every order breaks ties by created
    /// date (newest first) then path, so the result is deterministic even for
    /// identical titles or durations.
    func sorted(
        _ entries: [Entry],
        direction: EntrySortDirection? = nil
    ) -> [Entry] {
        let direction = direction ?? defaultDirection
        return entries.sorted { a, b in
            switch self {
            case .dateNewest:
                if a.created != b.created {
                    return direction.orders(a.created, before: b.created)
                }
            case .duration:
                // Missing durations stay last regardless of direction.
                switch (a.duration, b.duration) {
                case (let da?, let db?) where da != db:
                    return direction.orders(da, before: db)
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
            case .title:
                let order = a.displayTitle.localizedStandardCompare(b.displayTitle)
                if order != .orderedSame {
                    return direction == .ascending
                        ? order == .orderedAscending
                        : order == .orderedDescending
                }
            case .recentlyEdited:
                if a.modified != b.modified {
                    return direction.orders(a.modified, before: b.modified)
                }
            }
            // Preserve the established deterministic tie rules independently
            // of direction so equal primary keys never reshuffle unexpectedly.
            if a.created != b.created { return a.created > b.created }
            return a.relativePath < b.relativePath
        }
    }
}

enum EntrySortDirection: String, CaseIterable, Sendable {
    case ascending
    case descending

    var toggled: Self {
        self == .ascending ? .descending : .ascending
    }

    fileprivate func orders<T: Comparable>(_ lhs: T, before rhs: T) -> Bool {
        self == .ascending ? lhs < rhs : lhs > rhs
    }
}
