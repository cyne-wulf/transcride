import Foundation
import Testing

@Suite("EntryFolderName parsing")
struct EntryFolderNameTests {
    @Test func parsesCanonicalName() throws {
        let name = try #require(EntryFolderName(parsing: "transcride-2026-07-08T14-32-05"))
        #expect(name.timestamp == "2026-07-08T14-32-05")
        #expect(name.slug == nil)
        #expect(name.string == "transcride-2026-07-08T14-32-05")
    }

    @Test func parsesNameWithSlug() throws {
        let name = try #require(EntryFolderName(parsing: "transcride-2026-07-08T14-32-05-morning-thoughts"))
        #expect(name.timestamp == "2026-07-08T14-32-05")
        #expect(name.slug == "morning-thoughts")
        #expect(name.string == "transcride-2026-07-08T14-32-05-morning-thoughts")
    }

    @Test(arguments: [
        "transcride-2026-07-08",                    // date only
        "transcride-2026-07-08T14-32",              // missing seconds
        "transcride-2026-13-08T14-32-05",           // month 13
        "transcride-2026-07-08T24-32-05",           // hour 24
        "transcride-2026-07-08T14-32-05x",          // junk instead of -slug
        "transcride-2026-07-08T14-32-05-",          // dangling hyphen, empty slug
        "recording-2026-07-08T14-32-05",            // wrong prefix
        "transcride-",
        "Journal",
        "",
    ])
    func rejectsInvalidNames(_ input: String) {
        #expect(EntryFolderName(parsing: input) == nil)
    }

    @Test func dateRoundTrip() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = 14; components.minute = 32; components.second = 5
        let date = try #require(Calendar.current.date(from: components))

        let name = EntryFolderName(date: date)
        #expect(name.string == "transcride-2026-07-08T14-32-05")
        #expect(name.date == date)
    }

    @Test func slugChangeKeepsIdentity() throws {
        let original = try #require(EntryFolderName(parsing: "transcride-2026-07-08T14-32-05-old-title"))
        let renamed = original.with(slug: "new-title")
        #expect(renamed.timestamp == original.timestamp)
        #expect(renamed.string == "transcride-2026-07-08T14-32-05-new-title")

        let cleared = original.with(slug: nil)
        #expect(cleared.string == "transcride-2026-07-08T14-32-05")
        #expect(original.with(slug: "").string == "transcride-2026-07-08T14-32-05")
    }
}
