import Foundation
import Testing

@Suite("Transcript word mapping")
struct TranscriptWordMapTests {
    private func transcript(_ words: [(String, Double, Double)]) -> TranscriptOriginal {
        let mapped = words.map { TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2) }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: mapped.first?.start ?? 0, end: mapped.last?.end ?? 0, words: mapped)]
        )
    }

    @Test func renderedTextExactlyMatchesM3Generation() {
        let value = transcript([
            ("  Hello  ", 0, 0.4),
            ("world.", 0.5, 0.9),
            ("Next", 2.9, 3.2), // Exactly 2.0 s starts a paragraph.
            ("idea", 3.3, 3.6),
        ])
        let map = TranscriptWordMap(transcript: value)
        #expect(map.renderedText == TranscriptMarkdown.body(from: value))
        #expect(map.renderedText == "Hello world.\n\nNext idea")
        #expect(map.range(forWordAt: 0) == 0..<5)
        #expect(map.range(forWordAt: 1) == 6..<12)
        #expect(map.range(forWordAt: 2) == 14..<18)
        #expect(map.range(forWordAt: 3) == 19..<23)
    }

    @Test func offsetsAreUTF16AndMergedWordKeepsOneIdentity() {
        let value = transcript([
            ("Hi", 0, 0.2),
            ("👋🏽", 0.3, 0.5),
            ("Ashan Devine,", 0.6, 1.2),
        ])
        let map = TranscriptWordMap(transcript: value)
        #expect(map.renderedText == "Hi 👋🏽 Ashan Devine,")
        #expect(map.range(forWordAt: 0) == 0..<2)
        #expect(map.range(forWordAt: 1) == 3..<7) // Emoji + skin tone = four UTF-16 units.
        #expect(map.range(forWordAt: 2) == 8..<21)
        #expect(map.wordIndex(containingUTF16Offset: 14) == 2) // Internal space of merged word.
    }

    @Test func emptyWordsAreSkippedWithoutRenumbering() {
        let map = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("   ", 0.3, 0.4), ("two", 0.5, 0.7),
        ]))
        #expect(map.renderedText == "one two")
        #expect(map.spans.map(\.wordIndex) == [0, 2])
        #expect(map.range(forWordAt: 1) == nil)
        #expect(map.range(forWordAt: 2) == 4..<7)
    }

    @Test func characterLookupDistinguishesRunsAndSeparators() {
        let map = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5),
        ]))
        #expect(map.wordIndex(containingUTF16Offset: 1) == 0)
        #expect(map.wordIndex(containingUTF16Offset: 3) == nil)
        #expect(map.wordIndex(atOrBeforeUTF16Offset: 3) == 0)
        #expect(map.wordIndex(atOrBeforeUTF16Offset: 4) == 1)
        #expect(map.startTime(atOrBeforeUTF16Offset: 5) == 0.3)
        #expect(map.wordIndex(atOrBeforeUTF16Offset: -1) == nil)
    }

    @Test func audioLookupUsesHalfOpenRangesAndNearestPrevious() {
        let map = TranscriptWordMap(transcript: transcript([
            ("one", 1.0, 1.3), ("two", 2.0, 2.4), ("three", 2.5, 2.8),
        ]))
        #expect(map.wordIndex(atTime: 0.9) == nil)
        #expect(map.wordIndex(atTime: 1.0) == 0)
        #expect(map.wordIndex(atTime: 1.299) == 0)
        #expect(map.wordIndex(atTime: 1.3) == 0)
        #expect(map.wordIndex(atTime: 2.0) == 1)
        #expect(map.wordIndex(atTime: 2.45) == 1)
        #expect(map.wordIndex(atTime: 10) == 2)
        #expect(map.wordIndex(atTime: .nan) == nil)
    }

    @Test func editedMatchCuesByOccurrenceDespiteShiftedOffsets() {
        let map = TranscriptWordMap(transcript: transcript([
            ("alpha", 0, 0.4), ("beta", 0.5, 0.9), ("gamma", 1.0, 1.4),
        ]))
        // "# Heading\n\n" prefix shifts every offset by 11.
        let body = "# Heading\n\nalpha beta gamma"
        let match = (body as NSString).range(of: "beta")
        #expect(map.startTime(forMatch: match.lowerBound..<NSMaxRange(match), inEditedBody: body) == 0.5)
    }

    @Test func editedMatchOrdinalPicksTheRightRepeatedPhrase() {
        let map = TranscriptWordMap(transcript: transcript([
            ("go", 0, 0.2), ("stop", 0.5, 0.7), ("go", 1.0, 1.2),
        ]))
        let body = "go stop go"
        // Second occurrence of "go" cues the second spoken "go", not the first.
        #expect(map.startTime(forMatch: 8..<10, inEditedBody: body) == 1.0)
        #expect(map.startTime(forMatch: 0..<2, inEditedBody: body) == 0)
    }

    @Test func editedMatchIsCaseInsensitiveAndEditedOnlyTextHasNoMoment() {
        let map = TranscriptWordMap(transcript: transcript([
            ("alpha", 0, 0.4), ("beta", 0.5, 0.9),
        ]))
        let body = "ALPHA beta plus my own words"
        #expect(map.startTime(forMatch: 0..<5, inEditedBody: body) == 0)
        let ownWords = (body as NSString).range(of: "own words")
        #expect(map.startTime(
            forMatch: ownWords.lowerBound..<NSMaxRange(ownWords), inEditedBody: body
        ) == nil)
        // Out-of-bounds and whitespace-only matches are rejected, not crashed.
        #expect(map.startTime(forMatch: 0..<999, inEditedBody: body) == nil)
        #expect(map.startTime(forMatch: 5..<6, inEditedBody: body) == nil)
    }
}

@Suite("Silence gap computation")
struct SilenceGapTests {
    private func transcript(_ words: [(String, Double, Double)]) -> TranscriptOriginal {
        let mapped = words.map { TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2) }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: mapped.first?.start ?? 0, end: mapped.last?.end ?? 0, words: mapped)]
        )
    }

    @Test func onlyStrictlyLongerGapsAreSkippable() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("one", 0, 0.4),
            ("two", 1.9, 2.2),   // 1.5 exactly: not skipped.
            ("three", 4.0, 4.3), // 1.8: skipped.
            ("four", 4.2, 4.6),  // overlap: not skipped.
        ]))
        let gap = try #require(gaps.first)
        #expect(gaps.count == 1)
        #expect(gap.start == 2.2)
        #expect(gap.end == 4.0)
        #expect(gap.previousWordIndex == 1)
        #expect(gap.nextWordIndex == 2)
        #expect(abs(gap.duration - 1.8) < 0.000_001)
    }

    @Test func thresholdIsTunableAndSkipUsesHalfOpenGap() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("one", 0, 0.2), ("two", 1.0, 1.2),
        ]), threshold: 0.5)
        let gap = try #require(gaps.first)
        #expect(SilenceGap.skipDestination(at: gap.start, in: gaps) == 1.0)
        #expect(SilenceGap.skipDestination(at: 0.999, in: gaps) == 1.0)
        #expect(SilenceGap.skipDestination(at: gap.end, in: gaps) == nil)
    }

    @Test func whitespaceWordsDoNotSplitRealWordGaps() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("one", 0, 0.2), (" ", 1.0, 1.1), ("two", 2.0, 2.2),
        ]), threshold: 1.5)
        let gap = try #require(gaps.first)
        #expect(gap.previousWordIndex == 0)
        #expect(gap.nextWordIndex == 2)
        #expect(gap.start == 0.2)
        #expect(gap.end == 2.0)
    }
}
