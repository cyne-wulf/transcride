import Foundation
import Testing

@Suite("Frontmatter round-trip")
struct FrontmatterTests {
    let sample = """
    ---
    title: "Morning Thoughts"
    created: 2026-07-08T14:32:05+02:00
    duration: 83.20
    favorite: true
    audio_deleted: false
    source: recorded
    engine: parakeet-tdt-v3
    custom_key: kept as-is
    ---

    First paragraph of the note.

    Second paragraph.
    """

    @Test func parsesTypedFields() {
        let doc = FrontmatterDocument.parse(sample)
        #expect(doc.title == "Morning Thoughts")
        #expect(doc.duration == 83.2)
        #expect(doc.favorite == true)
        #expect(doc.audioDeleted == false)
        #expect(doc.source == "recorded")
        #expect(doc.engine == "parakeet-tdt-v3")
        #expect(doc.created != nil)
        #expect(doc.body.contains("First paragraph"))
    }

    @Test func untouchedDocumentSerializesByteExact() {
        let doc = FrontmatterDocument.parse(sample)
        #expect(doc.serialized() == sample)
    }

    @Test func editPreservesUnknownKeysAndBody() {
        var doc = FrontmatterDocument.parse(sample)
        doc.title = "Renamed Note"
        let out = doc.serialized()
        #expect(out.contains("title: \"Renamed Note\""))
        #expect(out.contains("custom_key: kept as-is"))
        #expect(out.contains("Second paragraph."))
        // Nothing else changed.
        let reparsed = FrontmatterDocument.parse(out)
        #expect(reparsed.title == "Renamed Note")
        #expect(reparsed.duration == 83.2)
        #expect(reparsed.body == doc.body)
    }

    @Test func titleWithSpecialCharactersRoundTrips() {
        var doc = FrontmatterDocument(fields: [], body: "body\n")
        let nasty = #"He said: "it's 50% #done" \ maybe"#
        doc.title = nasty
        let reparsed = FrontmatterDocument.parse(doc.serialized())
        #expect(reparsed.title == nasty)
    }

    @Test func documentWithoutFrontmatterIsAllBody() {
        let text = "Just a note.\nNo frontmatter here.\n"
        let doc = FrontmatterDocument.parse(text)
        #expect(!doc.hasFrontmatter)
        #expect(doc.body == text)
        #expect(doc.serialized() == text)
    }

    @Test func unclosedFrontmatterIsLeftAlone() {
        let text = "---\ntitle: broken\nno closing delimiter\n"
        let doc = FrontmatterDocument.parse(text)
        #expect(!doc.hasFrontmatter)
        #expect(doc.serialized() == text)
    }

    @Test func addingFieldsToBareBodyCreatesFrontmatter() {
        var doc = FrontmatterDocument(fields: [], body: "Hello.\n")
        doc.title = "New"
        doc.favorite = false
        let out = doc.serialized()
        #expect(out.hasPrefix("---\n"))
        let reparsed = FrontmatterDocument.parse(out)
        #expect(reparsed.title == "New")
        #expect(reparsed.favorite == false)
        #expect(reparsed.body == "Hello.\n")
    }

    @Test func favoriteWritesTrueAndRemovesOnFalse() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"T\"\n---\nBody stays put.\n")
        let body = doc.body
        doc.favorite = true
        #expect(doc.serialized().contains("favorite: true"))
        #expect(FrontmatterDocument.parse(doc.serialized()).favorite == true)
        // Unfavoriting removes the key entirely — ordinary entries never carry it.
        doc.favorite = false
        #expect(!doc.serialized().contains("favorite"))
        #expect(FrontmatterDocument.parse(doc.serialized()).favorite == false)
        // A favorite toggle is frontmatter-only: the body is byte-identical.
        #expect(doc.body == body)
    }

    @Test func createdDateRoundTrips() throws {
        var doc = FrontmatterDocument(fields: [], body: "")
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = 14; components.minute = 32; components.second = 5
        let date = try #require(Calendar.current.date(from: components))
        doc.created = date
        let reparsed = FrontmatterDocument.parse(doc.serialized())
        #expect(reparsed.created == date)
    }

    @Test func lenientExternalDateFormats() {
        #expect(FrontmatterDate.parse("2026-07-08") != nil)
        #expect(FrontmatterDate.parse("2026-07-08 14:32") != nil)
        #expect(FrontmatterDate.parse("2026-07-08T14:32:05Z") != nil)
        #expect(FrontmatterDate.parse("2026-07-08T14:32:05+0530") != nil)
        #expect(FrontmatterDate.parse("not a date") == nil)
    }

    @Test func singleQuotedAndCommentedScalars() {
        let text = "---\ntitle: 'It''s fine'\nsource: recorded # from mic\n---\nbody"
        let doc = FrontmatterDocument.parse(text)
        #expect(doc.title == "It's fine")
        #expect(doc.source == "recorded")
    }

    @Test func handEditedFlagIsAbsentUntilSetAndRemovedWhenCleared() {
        var doc = FrontmatterDocument.parse(sample)
        #expect(!doc.handEdited)
        #expect(doc.rawValue(for: "hand_edited") == nil)

        doc.handEdited = true
        #expect(doc.handEdited)
        #expect(doc.serialized().contains("hand_edited: true"))

        doc.handEdited = false
        #expect(!doc.handEdited)
        #expect(doc.rawValue(for: "hand_edited") == nil)
    }
}
