import Foundation

/// Vault-search filters (SRCH-5). Filters narrow the hit list *after* the
/// text query runs: hits are matched against entry metadata from the vault
/// snapshot, so the search index schema stays a pure text cache.
struct VaultSearchFilters: Equatable, Sendable {
    static let displayedResultLimit = 150

    enum AudioPresence: String, CaseIterable, Sendable {
        case any
        case hasAudio
        case noteOnly

        var displayName: String {
            switch self {
            case .any: return "Audio & Notes"
            case .hasAudio: return "Has Audio"
            case .noteOnly: return "Note Only"
            }
        }
    }

    enum DatePreset: String, CaseIterable, Sendable {
        case any
        case today
        case last7Days
        case last30Days
        case custom

        var displayName: String {
            switch self {
            case .any: return "Any Date"
            case .today: return "Today"
            case .last7Days: return "Last 7 Days"
            case .last30Days: return "Last 30 Days"
            case .custom: return "Custom Range…"
            }
        }
    }

    /// Restrict hits to entries inside this folder (or any of its
    /// subfolders); nil = the whole vault.
    var folder: RelativePath?
    var datePreset: DatePreset = .any
    /// Custom range bounds, interpreted as whole calendar days (inclusive).
    /// Only consulted when `datePreset == .custom`.
    var customStart = Date(timeIntervalSince1970: 0)
    var customEnd = Date.distantFuture
    var audio: AudioPresence = .any
    var favoritesOnly = false
    /// Canonical tag ids. Multiple selections are ORed; this group remains
    /// ANDed with folder/date/audio/favorite filters.
    var selectedTags: Set<String> = []

    /// True when any filter would exclude something.
    var isActive: Bool {
        folder != nil || datePreset != .any || audio != .any || favoritesOnly
            || !selectedTags.isEmpty
    }

    func matches(_ entry: Entry, now: Date = .now, calendar: Calendar = .current) -> Bool {
        if let folder {
            guard entry.relativePath.hasPrefix(folder + "/") else { return false }
        }
        if favoritesOnly, !entry.favorite { return false }
        guard EditorTagExtractor.matchesAny(
            entryTags: entry.tags,
            selectedTags: selectedTags
        ) else { return false }
        switch audio {
        case .any: break
        case .hasAudio:
            guard entry.hasAudio else { return false }
        case .noteOnly:
            guard !entry.hasAudio else { return false }
        }
        return dateRange(now: now, calendar: calendar).map {
            $0.contains(entry.created)
        } ?? true
    }

    /// Applies metadata filters before the UI result cap. This ordering is
    /// essential for common words: hundreds of unfiltered note-only hits must
    /// not hide a later audio hit from the Has Audio result set.
    func apply(
        to hits: [SearchHit],
        entries: [Entry],
        now: Date = .now,
        limit: Int = displayedResultLimit
    ) -> [SearchHit] {
        guard limit > 0 else { return [] }
        guard isActive else { return Array(hits.prefix(limit)) }
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.relativePath, $0)
        })
        return Array(hits.lazy.filter { hit in
            guard let entry = entriesByPath[hit.entryPath] else { return false }
            return matches(entry, now: now)
        }.prefix(limit))
    }

    /// The created-date window the preset describes; nil = unrestricted.
    private func dateRange(now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        func daysBack(_ days: Int) -> Date {
            calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -days, to: now) ?? now
            )
        }
        switch datePreset {
        case .any:
            return nil
        case .today:
            return calendar.startOfDay(for: now)...now
        case .last7Days:
            return daysBack(6)...now
        case .last30Days:
            return daysBack(29)...now
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay)
                .map { $0.addingTimeInterval(-1) } ?? .distantFuture
            return start...end
        }
    }
}
