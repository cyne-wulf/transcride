import Foundation
import Testing

@Suite("Transcript file naming and discovery")
struct TranscriptFileTests {
    @Test func untitledUsesDefaultName() {
        #expect(TranscriptFile.fileName(forTitle: nil) == "transcript.md")
        #expect(TranscriptFile.fileName(forTitle: "") == "transcript.md")
        #expect(TranscriptFile.fileName(forTitle: "   ") == "transcript.md")
    }

    @Test func titleBecomesFileName() {
        #expect(TranscriptFile.fileName(forTitle: "My Note") == "My Note.md")
        #expect(TranscriptFile.fileName(forTitle: "  Padded  ") == "Padded.md")
    }

    @Test func unsafeCharactersSanitized() {
        #expect(TranscriptFile.fileName(forTitle: "A/B: C") == "A-B- C.md")
        #expect(TranscriptFile.fileName(forTitle: "...dotty") == "dotty.md")
        #expect(TranscriptFile.fileName(forTitle: "///") == "---.md")
    }

    @Test func longTitlesCapped() {
        let long = String(repeating: "x", count: 300)
        let name = TranscriptFile.fileName(forTitle: long)
        #expect(name == String(repeating: "x", count: 100) + ".md")
    }

    @Test func findPrefersDefaultName() {
        #expect(TranscriptFile.find(in: ["Apple.md", "transcript.md", "audio.m4a"]) == "transcript.md")
    }

    @Test func findFallsBackToFirstMarkdownFile() {
        #expect(TranscriptFile.find(in: ["Zebra.md", "audio.m4a", "Apple.md"]) == "Apple.md")
        #expect(TranscriptFile.find(in: [".hidden.md", "Note.md"]) == "Note.md")
        #expect(TranscriptFile.find(in: ["audio.m4a"]) == nil)
        #expect(TranscriptFile.find(in: []) == nil)
    }
}
