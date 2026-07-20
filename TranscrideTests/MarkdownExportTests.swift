import Foundation
import Testing

private func transcript(
    _ segments: [(speaker: String?, words: [(String, Double, Double)])]
) -> TranscriptOriginal {
    TranscriptOriginal(
        engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
        segments: segments.map { segment in
            let words = segment.words.map {
                TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2)
            }
            return TranscriptOriginal.Segment(
                start: words.first?.start ?? 0,
                end: words.last?.end ?? 0,
                speaker: segment.speaker,
                words: words
            )
        }
    )
}

@Suite("Markdown export (EXP-2)")
struct MarkdownExportTests {
    private let diarized = transcript([
        ("S1", [("Hello", 0.0, 0.4), ("there.", 0.5, 0.9)]),
        ("S2", [("Hi.", 1.2, 1.5)]),
    ])

    @Test func originalContentMatchesGeneratedBodyByDefault() {
        let plain = transcript([
            (nil, [("One", 0.0, 0.4), ("two.", 0.5, 0.9), ("Three.", 3.5, 4.0)]),
        ])
        #expect(MarkdownExport.originalContent(from: plain)
            == TranscriptMarkdown.body(from: plain))
    }

    @Test func speakerLabelsUseRenamedSpeakersAndCanBeOmitted() {
        let named = MarkdownExport.originalContent(
            from: diarized,
            speakerNames: ["S1": "Alice"],
            options: .init(includeSpeakerLabels: true)
        )
        #expect(named == "**Alice:** Hello there.\n\n**Speaker 2:** Hi.")

        let unlabeled = MarkdownExport.originalContent(
            from: diarized,
            speakerNames: ["S1": "Alice"],
            options: .init(includeSpeakerLabels: false)
        )
        #expect(unlabeled == "Hello there.\n\nHi.")
    }

    @Test func disabledDetectionRemovesSpeakerPresentationFromOriginalExport() {
        let content = MarkdownExport.originalContent(
            from: diarized,
            speakerNames: ["S1": "Alice"],
            options: .init(
                includeSpeakerLabels: true,
                speakerDetectionEnabled: false
            )
        )
        #expect(content == "Hello there. Hi.")
    }

    @Test func paragraphTimestampsPrefixEachParagraph() {
        let paused = transcript([
            (nil, [("First", 12.0, 12.4), ("part.", 12.5, 12.9),
                   ("Second", 75.0, 75.4), ("part.", 75.5, 75.9)]),
        ])
        let content = MarkdownExport.originalContent(
            from: paused,
            options: .init(includeParagraphTimestamps: true)
        )
        #expect(content == "[0:12] First part.\n\n[1:15] Second part.")
    }

    @Test func timestampsComposeWithSpeakerLabels() {
        let content = MarkdownExport.originalContent(
            from: diarized,
            speakerNames: ["S1": "Alice"],
            options: .init(includeSpeakerLabels: true, includeParagraphTimestamps: true)
        )
        #expect(content == "[0:00] **Alice:** Hello there.\n\n[0:01] **Speaker 2:** Hi.")
    }

    @Test func timestampLabelGrowsPastAnHour() {
        #expect(MarkdownExport.timestampLabel(0) == "0:00")
        #expect(MarkdownExport.timestampLabel(59.9) == "0:59")
        #expect(MarkdownExport.timestampLabel(754) == "12:34")
        #expect(MarkdownExport.timestampLabel(3723) == "1:02:03")
    }

    @Test func editedContentExportsBodyVerbatimTrimmed() {
        #expect(MarkdownExport.editedContent(body: "\n# My Note\n\nBody **text**.\n")
            == "# My Note\n\nBody **text**.")
    }

    @Test func fileNamesSuffixOnCaseInsensitiveCollision() {
        #expect(MarkdownExport.fileName(forTitle: "Standup Notes", existingNames: [])
            == "Standup Notes.md")
        #expect(MarkdownExport.fileName(
            forTitle: "Standup Notes",
            existingNames: ["standup notes.md"]
        ) == "Standup Notes 2.md")
        #expect(MarkdownExport.fileName(
            forTitle: "Standup Notes",
            existingNames: ["Standup Notes.md", "Standup Notes 2.md", "other.md"]
        ) == "Standup Notes 3.md")
    }
}
