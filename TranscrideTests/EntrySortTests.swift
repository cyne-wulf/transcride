import Foundation
import Testing

@Suite("Entry sort orders")
struct EntrySortTests {
    private func makeEntry(
        path: String,
        title: String? = nil,
        created: Date,
        modified: Date? = nil,
        duration: Double? = nil,
        favorite: Bool = false
    ) -> Entry {
        Entry(
            relativePath: path,
            folderName: EntryFolderName(date: created),
            title: title,
            created: created,
            modified: modified ?? created,
            duration: duration,
            snippet: "",
            favorite: favorite,
            audioDeleted: false,
            audioFileName: nil,
            hasTranscript: true,
            transcriptFileName: "transcript.md"
        )
    }

    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func dateSortsNewestFirst() {
        let old = makeEntry(path: "a", created: base)
        let new = makeEntry(path: "b", created: base.addingTimeInterval(60))
        #expect(EntrySortOrder.dateNewest.sorted([old, new]).map(\.id) == ["b", "a"])
    }

    @Test func durationSortsLongestFirstAndMissingLast() {
        let short = makeEntry(path: "short", created: base, duration: 10)
        let long = makeEntry(path: "long", created: base, duration: 500)
        let none = makeEntry(path: "none", created: base.addingTimeInterval(999))
        let sorted = EntrySortOrder.duration.sorted([none, short, long])
        #expect(sorted.map(\.id) == ["long", "short", "none"])
    }

    @Test func titleSortsCaseInsensitivelyAndNumerically() {
        let b = makeEntry(path: "1", title: "banana", created: base)
        let a = makeEntry(path: "2", title: "Apple", created: base)
        let two = makeEntry(path: "3", title: "Entry 2", created: base)
        let ten = makeEntry(path: "4", title: "Entry 10", created: base)
        let sorted = EntrySortOrder.title.sorted([ten, b, two, a])
        #expect(sorted.map(\.title) == ["Apple", "banana", "Entry 2", "Entry 10"])
    }

    @Test func equalTitlesFallBackToNewestCreated() {
        let older = makeEntry(path: "older", title: "Same", created: base)
        let newer = makeEntry(path: "newer", title: "Same", created: base.addingTimeInterval(60))
        #expect(EntrySortOrder.title.sorted([older, newer]).map(\.id) == ["newer", "older"])
    }

    @Test func recentlyEditedSortsByModified() {
        let stale = makeEntry(path: "stale", created: base.addingTimeInterval(600), modified: base)
        let fresh = makeEntry(path: "fresh", created: base, modified: base.addingTimeInterval(600))
        #expect(EntrySortOrder.recentlyEdited.sorted([stale, fresh]).map(\.id) == ["fresh", "stale"])
    }

    @Test func identicalKeysAreDeterministicByPath() {
        let a = makeEntry(path: "a", created: base, duration: 5)
        let b = makeEntry(path: "b", created: base, duration: 5)
        for order in EntrySortOrder.allCases {
            #expect(order.sorted([b, a]).map(\.id) == ["a", "b"])
        }
    }
}
