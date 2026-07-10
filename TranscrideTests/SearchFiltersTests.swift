import Foundation
import Testing

@Suite("Vault search filters")
struct SearchFiltersTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// Fixed "now": 2026-07-10 12:00:00 UTC.
    private var now: Date {
        DateComponents(
            calendar: calendar, year: 2026, month: 7, day: 10, hour: 12
        ).date!
    }

    private func makeEntry(
        path: String,
        createdDaysAgo: Double,
        hasAudio: Bool = false,
        favorite: Bool = false
    ) -> Entry {
        let created = now.addingTimeInterval(-createdDaysAgo * 86_400)
        return Entry(
            relativePath: path,
            folderName: EntryFolderName(date: created),
            title: nil,
            created: created,
            modified: created,
            duration: nil,
            snippet: "",
            favorite: favorite,
            audioDeleted: false,
            audioFileName: hasAudio ? "audio.m4a" : nil,
            hasTranscript: true,
            transcriptFileName: "transcript.md"
        )
    }

    @Test func defaultFiltersMatchEverythingAndAreInactive() {
        let filters = VaultSearchFilters()
        #expect(!filters.isActive)
        #expect(filters.matches(makeEntry(path: "x", createdDaysAgo: 400), now: now, calendar: calendar))
    }

    @Test func folderFilterMatchesFolderAndDescendants() {
        var filters = VaultSearchFilters()
        filters.folder = "Journal"
        #expect(filters.isActive)
        let inside = makeEntry(path: "Journal/transcride-2026-07-01T10-00-00", createdDaysAgo: 1)
        let nested = makeEntry(path: "Journal/Ideas/transcride-2026-07-01T10-00-00", createdDaysAgo: 1)
        let outside = makeEntry(path: "transcride-2026-07-01T10-00-00", createdDaysAgo: 1)
        let lookalike = makeEntry(path: "Journaling/transcride-2026-07-01T10-00-00", createdDaysAgo: 1)
        #expect(filters.matches(inside, now: now, calendar: calendar))
        #expect(filters.matches(nested, now: now, calendar: calendar))
        #expect(!filters.matches(outside, now: now, calendar: calendar))
        #expect(!filters.matches(lookalike, now: now, calendar: calendar))
    }

    @Test func datePresetsBoundTheCreatedDate() {
        let today = makeEntry(path: "a", createdDaysAgo: 0.1)
        let thisWeek = makeEntry(path: "b", createdDaysAgo: 5)
        let thisMonth = makeEntry(path: "c", createdDaysAgo: 20)
        let ancient = makeEntry(path: "d", createdDaysAgo: 90)

        var filters = VaultSearchFilters()
        filters.datePreset = .today
        #expect(filters.matches(today, now: now, calendar: calendar))
        #expect(!filters.matches(thisWeek, now: now, calendar: calendar))

        filters.datePreset = .last7Days
        #expect(filters.matches(thisWeek, now: now, calendar: calendar))
        #expect(!filters.matches(thisMonth, now: now, calendar: calendar))

        filters.datePreset = .last30Days
        #expect(filters.matches(thisMonth, now: now, calendar: calendar))
        #expect(!filters.matches(ancient, now: now, calendar: calendar))
    }

    @Test func customRangeIsInclusiveOfWholeDaysAndOrderAgnostic() {
        var filters = VaultSearchFilters()
        filters.datePreset = .custom
        filters.customStart = now.addingTimeInterval(-10 * 86_400)
        filters.customEnd = now.addingTimeInterval(-5 * 86_400)

        let inRange = makeEntry(path: "in", createdDaysAgo: 7)
        // Same calendar day as customEnd but later in the day: still included.
        let endOfLastDay = makeEntry(path: "edge", createdDaysAgo: 5 - 0.3)
        let before = makeEntry(path: "before", createdDaysAgo: 12)
        let after = makeEntry(path: "after", createdDaysAgo: 2)
        #expect(filters.matches(inRange, now: now, calendar: calendar))
        #expect(filters.matches(endOfLastDay, now: now, calendar: calendar))
        #expect(!filters.matches(before, now: now, calendar: calendar))
        #expect(!filters.matches(after, now: now, calendar: calendar))

        // Swapped bounds behave identically.
        swap(&filters.customStart, &filters.customEnd)
        #expect(filters.matches(inRange, now: now, calendar: calendar))
        #expect(!filters.matches(before, now: now, calendar: calendar))
    }

    @Test func audioPresenceFilters() {
        let withAudio = makeEntry(path: "a", createdDaysAgo: 1, hasAudio: true)
        let noteOnly = makeEntry(path: "b", createdDaysAgo: 1, hasAudio: false)

        var filters = VaultSearchFilters()
        filters.audio = .hasAudio
        #expect(filters.matches(withAudio, now: now, calendar: calendar))
        #expect(!filters.matches(noteOnly, now: now, calendar: calendar))

        filters.audio = .noteOnly
        #expect(!filters.matches(withAudio, now: now, calendar: calendar))
        #expect(filters.matches(noteOnly, now: now, calendar: calendar))
    }

    @Test func favoritesOnlyAndCombinationAreANDed() {
        var filters = VaultSearchFilters()
        filters.favoritesOnly = true
        filters.folder = "Journal"
        filters.audio = .hasAudio
        filters.datePreset = .last7Days

        let match = makeEntry(
            path: "Journal/transcride-2026-07-08T10-00-00",
            createdDaysAgo: 2, hasAudio: true, favorite: true
        )
        #expect(filters.matches(match, now: now, calendar: calendar))

        // Each violated condition alone breaks the match.
        var wrong = match
        wrong.favorite = false
        #expect(!filters.matches(wrong, now: now, calendar: calendar))
        wrong = match
        wrong.audioFileName = nil
        #expect(!filters.matches(wrong, now: now, calendar: calendar))
        wrong = match
        wrong.relativePath = "Other/transcride-2026-07-08T10-00-00"
        #expect(!filters.matches(wrong, now: now, calendar: calendar))
        wrong = match
        wrong.created = now.addingTimeInterval(-40 * 86_400)
        #expect(!filters.matches(wrong, now: now, calendar: calendar))
    }
}
