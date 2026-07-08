import Foundation
import Testing

@Suite("Slugification")
struct SlugTests {
    @Test func basicTitle() {
        #expect(Slug.make(from: "Morning Thoughts") == "morning-thoughts")
    }

    @Test func stripsPunctuation() {
        #expect(Slug.make(from: "What's up, Doc?! (part 2)") == "what-s-up-doc-part-2")
    }

    @Test func collapsesSeparators() {
        #expect(Slug.make(from: "  a  --  b  ") == "a-b")
    }

    @Test func foldsDiacritics() {
        #expect(Slug.make(from: "Café à Paris") == "cafe-a-paris")
    }

    @Test func capsLengthWithoutTrailingHyphen() {
        let slug = Slug.make(from: String(repeating: "word ", count: 20))
        #expect(slug.count <= Slug.maxLength)
        #expect(!slug.hasSuffix("-"))
        #expect(!slug.isEmpty)
    }

    @Test func emptyAndPunctuationOnlyTitles() {
        #expect(Slug.make(from: "") == "")
        #expect(Slug.make(from: "?!...---") == "")
        #expect(Slug.make(from: "   ") == "")
    }
}
