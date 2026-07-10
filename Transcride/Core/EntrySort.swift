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

    /// Returns the entries in this order. Every order breaks ties by created
    /// date (newest first) then path, so the result is deterministic even for
    /// identical titles or durations.
    func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            switch self {
            case .dateNewest:
                break
            case .duration:
                // Longest first; entries without audio duration go last.
                switch (a.duration, b.duration) {
                case (let da?, let db?) where da != db: return da > db
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
            case .title:
                let order = a.displayTitle.localizedStandardCompare(b.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
            case .recentlyEdited:
                if a.modified != b.modified { return a.modified > b.modified }
            }
            if a.created != b.created { return a.created > b.created }
            return a.relativePath < b.relativePath
        }
    }
}
