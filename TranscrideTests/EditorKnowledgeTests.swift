import Foundation
import Testing

@Suite("Editor knowledge")
struct EditorKnowledgeTests {
    @Test func parsesTitleFolderAndAliasWikilinksButNotEmbeds() {
        let body = "[[Title]] [[Folder/Note]] [[Résumé|CV]] ![[image.png]]"
        let links = EditorWikiLinkParser.links(in: body)
        #expect(links.map(\.target) == ["Title", "Folder/Note", "Résumé"])
        #expect(links.map(\.displayText) == ["Title", "Folder/Note", "CV"])
        #expect(links[0].range == EditorUTF16Range(from: 0, to: 9))
    }

    @Test func resolvesUnicodeTitlesCaseInsensitivelyAndAliasDoesNotAffectTarget() throws {
        let link = try #require(EditorWikiLinkParser.links(in: "[[RÉSUMÉ|CV]]").first)
        let candidate = EditorWikiLinkCandidate(
            relativePath: "Work/transcride-resume",
            title: "résumé",
            modified: Date(timeIntervalSince1970: 1)
        )
        let resolution = try #require(EditorWikiLinkResolver.resolve(link, among: [candidate]))
        #expect(resolution.candidate == candidate)
        #expect(!resolution.isAmbiguous)
    }

    @Test func folderQualificationDisambiguatesExactParent() throws {
        let candidates = [
            EditorWikiLinkCandidate(
                relativePath: "Personal/transcride-note",
                title: "Plan",
                modified: Date(timeIntervalSince1970: 20)
            ),
            EditorWikiLinkCandidate(
                relativePath: "Work/transcride-note",
                title: "Plan",
                modified: Date(timeIntervalSince1970: 10)
            ),
        ]
        let resolution = try #require(EditorWikiLinkResolver.resolve(
            target: "work/PLAN",
            among: candidates
        ))
        #expect(resolution.candidate.relativePath == "Work/transcride-note")
        #expect(!resolution.isAmbiguous)
    }

    @Test func ambiguityUsesNewestThenNaturalNormalizedPath() throws {
        let tied = Date(timeIntervalSince1970: 100)
        let candidates = [
            EditorWikiLinkCandidate(relativePath: "Notes 10/b", title: "Same", modified: tied),
            EditorWikiLinkCandidate(relativePath: "Notes 2/a", title: "Same", modified: tied),
            EditorWikiLinkCandidate(
                relativePath: "Old/c",
                title: "Same",
                modified: Date(timeIntervalSince1970: 1)
            ),
        ]
        let resolution = try #require(EditorWikiLinkResolver.resolve(target: "Same", among: candidates))
        #expect(resolution.candidate.relativePath == "Notes 2/a")
        #expect(resolution.isAmbiguous)
        #expect(resolution.titleMatches.map(\.relativePath) == ["Notes 2/a", "Notes 10/b", "Old/c"])
    }

    @Test func indexedResolutionMatchesDeterministicResolverWithoutVaultRescans() throws {
        let candidates = (0..<10_000).map { index in
            EditorWikiLinkCandidate(
                relativePath: "Folder \(index)/entry",
                title: index.isMultiple(of: 2_000) ? "Shared" : "Note \(index)",
                modified: Date(timeIntervalSince1970: Double(index))
            )
        }
        let index = EditorWikiLinkIndex(candidates: candidates)
        let shared = try #require(index.resolve(target: "Shared"))
        #expect(shared.isAmbiguous)
        #expect(shared.candidate.relativePath == "Folder 8000/entry")
        #expect(index.resolve(target: "Folder 123/Note 123")?.candidate.relativePath
            == "Folder 123/entry")
    }

    @Test func externalLinkPolicyAllowsOnlyExplicitSemanticSchemes() {
        #expect(EditorExternalLinkPolicy.allowedURL("https://example.com") != nil)
        #expect(EditorExternalLinkPolicy.allowedURL("http://example.com") != nil)
        #expect(EditorExternalLinkPolicy.allowedURL("mailto:test@example.com") != nil)
        #expect(EditorExternalLinkPolicy.allowedURL("javascript:alert(1)") == nil)
        #expect(EditorExternalLinkPolicy.allowedURL("file:///tmp/private") == nil)
        #expect(EditorExternalLinkPolicy.allowedURL("//example.com") == nil)
    }

    @Test func unresolvedAndFragmentTargetsStayInert() {
        let candidate = EditorWikiLinkCandidate(
            relativePath: "Folder/entry",
            title: "Known",
            modified: .now
        )
        #expect(EditorWikiLinkResolver.resolve(target: "Missing", among: [candidate]) == nil)
        #expect(EditorWikiLinkResolver.resolve(target: "Known#Heading", among: [candidate]) == nil)
        #expect(EditorWikiLinkResolver.resolve(target: "Known^block", among: [candidate]) == nil)
    }

    @Test func extractsBodyAndInlineAndBlockYAMLTagsWithDisplaySpelling() {
        let markdown = """
        ---
        tags: [Project/Alpha, "Swift"]
        other: untouched
        tags:
          - Café
          - nested/Child
        ---
        #Project/Alpha #project/alpha #日本語 #hello-world #under_score
        """
        let tags = EditorTagExtractor.extract(markdown: markdown)
        #expect(tags.map(\.canonical) == [
            "project/alpha", "日本語", "hello-world", "under_score", "swift", "café", "nested/child",
        ])
        #expect(tags.first?.display == "Project/Alpha")
    }

    @Test func excludesEscapesCodeFencesInlineCodeAndLinkDestinations() {
        let body = """
        #kept \\#escaped `#inline` [label](https://example.com/#destination)
        [[Note#Heading]]
        ```swift
        let value = "#fenced"
        ```
        After #also-kept and word#not-a-tag and #123.
        """
        #expect(EditorTagExtractor.extract(body: body).map(\.canonical) == ["kept", "also-kept"])
    }

    @Test func validatesNumericAndNestedTagRules() {
        let body = "#123 #123/abc #/bad #bad/ #bad//child #good/child #élan"
        #expect(EditorTagExtractor.extract(body: body).map(\.canonical) == [
            "123/abc", "good/child", "élan",
        ])
    }

    @Test func canonicalizationIsUnicodeCaseInsensitiveWithoutChangingDisplay() {
        let tags = EditorTagExtractor.extract(body: "#CAFÉ #café")
        #expect(tags == [EditorTag(canonical: "café", display: "CAFÉ")])
    }

    @Test func parentAndDescendantSelectionUsesOrSemantics() {
        let entry = ["project/alpha", "people/alice", "status/open"]
        #expect(EditorTagExtractor.matchesAny(entryTags: entry, selectedTags: ["PROJECT"]))
        #expect(EditorTagExtractor.matchesAny(entryTags: entry, selectedTags: ["missing", "people/alice"]))
        #expect(!EditorTagExtractor.matchesAny(entryTags: entry, selectedTags: ["alpha", "people/bob"]))
        #expect(EditorTagExtractor.matchesAny(entryTags: entry, selectedTags: [String]()))
    }
}
