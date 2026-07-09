import Foundation
import Testing

@Suite("transcript.md generation")
struct TranscriptMarkdownTests {
    private func transcript(wordTimes: [(String, Double, Double)]) -> TranscriptOriginal {
        let words = wordTimes.map { TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2) }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: words.first?.start ?? 0, end: words.last?.end ?? 0, words: words)]
        )
    }

    @Test func joinsWordsWithSpaces() {
        let t = transcript(wordTimes: [("Hello", 0, 0.4), ("world.", 0.5, 0.9)])
        #expect(TranscriptMarkdown.body(from: t) == "Hello world.")
    }

    @Test func breaksParagraphsOnLongPauses() {
        let t = transcript(wordTimes: [
            ("First", 0, 0.4), ("thought.", 0.5, 0.9),
            ("Second", 3.5, 3.9), ("thought.", 4.0, 4.4), // 2.6 s pause before
        ])
        #expect(TranscriptMarkdown.body(from: t) == "First thought.\n\nSecond thought.")
    }

    @Test func shortPausesDoNotBreak() {
        let t = transcript(wordTimes: [
            ("One", 0, 0.4), ("two", 1.5, 1.9), // 1.1 s pause — under threshold
        ])
        #expect(TranscriptMarkdown.body(from: t) == "One two")
    }

    @Test func recognizesGeneratedAndEditedBodies() {
        let t = transcript(wordTimes: [("Hello", 0, 0.4), ("world.", 0.5, 0.9)])
        let generated = TranscriptMarkdown.body(from: t)
        #expect(TranscriptMarkdown.isGeneratedBody(generated, from: t))
        #expect(TranscriptMarkdown.isGeneratedBody("\n" + generated + "\n", from: t))
        #expect(!TranscriptMarkdown.isGeneratedBody("Hello brave world.", from: t))
        #expect(TranscriptMarkdown.isStubBody("\n  \n"))
        #expect(!TranscriptMarkdown.isStubBody("text"))
    }
}

@Suite("Auto-title extraction")
struct AutoTitleTests {
    @Test func takesFirstSentenceUpToEightWords() {
        #expect(AutoTitle.extract(fromTranscriptText: "Buy milk on the way home. Also eggs.")
            == "Buy milk on the way home")
        #expect(AutoTitle.extract(fromTranscriptText:
            "This is a very long first sentence that keeps going and going forever.")
            == "This is a very long first sentence that")
    }

    @Test func skipsLeadingFillerWords() {
        #expect(AutoTitle.extract(fromTranscriptText: "Um, okay, so remember to call Alex tomorrow.")
            == "Remember to call Alex tomorrow")
    }

    @Test func cleansPunctuationAndCapitalizes() {
        #expect(AutoTitle.extract(fromTranscriptText: "ideas for the garden!") == "Ideas for the garden")
    }

    @Test func returnsNilForEmptyOrFillerOnly() {
        #expect(AutoTitle.extract(fromTranscriptText: "") == nil)
        #expect(AutoTitle.extract(fromTranscriptText: "um uh hmm") == nil)
    }
}

@Suite("Segment builder")
struct SegmentBuilderTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptOriginal.Word {
        .init(text: text, start: start, end: end)
    }

    @Test func breaksOnSentenceEndAndPause() {
        let segments = SegmentBuilder.segments(from: [
            word("Hello", 0, 0.4), word("world.", 0.5, 0.9),
            word("Next", 1.0, 1.3), word("part", 3.0, 3.4), // 1.7 s pause
        ])
        #expect(segments.count == 3)
        #expect(segments[0].words.map(\.text) == ["Hello", "world."])
        #expect(segments[1].words.map(\.text) == ["Next"])
        #expect(segments[2].words.map(\.text) == ["part"])
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 0.9)
        #expect(segments.allSatisfy { $0.speaker == nil })
    }

    @Test func emptyInputMakesNoSegments() {
        #expect(SegmentBuilder.segments(from: []).isEmpty)
    }

    @Test func stripsDecoderControlTokens() {
        // Real Whisper large-v3-turbo failure output from verification — a
        // collapsed decode must strip to nothing, never reach a note.
        let collapsed = "<|startoftranscript|><|en|><|transcribe|><|0.00|><|endoftext|>"
        #expect(SegmentBuilder.strippingSpecialTokens(collapsed) == "")
        #expect(SegmentBuilder.strippingSpecialTokens(
            "<|0.00|> This is a test.<|7.06|>"
        ) == "This is a test.")
        #expect(SegmentBuilder.strippingSpecialTokens("plain words") == "plain words")
    }
}
