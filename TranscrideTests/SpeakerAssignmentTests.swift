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

@Suite("Speaker assignment (diarizer fusion)")
struct SpeakerAssignerTests {
    private let turns = [
        SpeakerTurn(speakerID: "S1", start: 0.0, end: 5.0),
        SpeakerTurn(speakerID: "S2", start: 6.0, end: 10.0),
    ]

    @Test func wordsAreAssignedByMidpointContainment() {
        let segments = transcript([
            (nil, [("hello", 0.0, 1.0), ("there", 4.0, 4.8), ("yes", 6.2, 6.8)]),
        ]).segments
        let result = SpeakerAssigner.apply(turns: turns, to: segments)
        #expect(result.count == 2)
        #expect(result[0].speaker == "S1")
        #expect(result[0].words.map(\.text) == ["hello", "there"])
        #expect(result[1].speaker == "S2")
        #expect(result[1].words.map(\.text) == ["yes"])
    }

    @Test func segmentBoundariesAreRecomputedFromSlices() {
        let segments = transcript([
            (nil, [("a", 0.0, 1.0), ("b", 6.5, 7.0)]),
        ]).segments
        let result = SpeakerAssigner.apply(turns: turns, to: segments)
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 1.0)
        #expect(result[1].start == 6.5)
        #expect(result[1].end == 7.0)
    }

    @Test func gapWordsTakeTheNearestTurnWithEarlierWinningTies() {
        // Midpoint 5.25 is 0.25 from S1's end and 0.75 from S2's start.
        #expect(SpeakerAssigner.speakerID(at: 5.25, in: turns) == "S1")
        // Midpoint 5.75 is nearer S2.
        #expect(SpeakerAssigner.speakerID(at: 5.75, in: turns) == "S2")
        // Exact tie at 5.5 goes to the earlier turn.
        #expect(SpeakerAssigner.speakerID(at: 5.5, in: turns) == "S1")
        // Turn ranges are half-open: the boundary belongs to no turn but
        // resolves at distance zero to the ending turn.
        #expect(SpeakerAssigner.speakerID(at: 0.0, in: turns) == "S1")
        #expect(SpeakerAssigner.speakerID(at: 10.0, in: turns) == "S2")
    }

    @Test func noTurnsLeavesSegmentsUntouched() {
        let segments = transcript([(nil, [("a", 0, 1), ("b", 1, 2)])]).segments
        #expect(SpeakerAssigner.apply(turns: [], to: segments) == segments)
    }

    @Test func consecutiveSameSpeakerWordsStayInOneSegment() {
        let segments = transcript([
            (nil, [("a", 0, 1), ("b", 1, 2), ("c", 2, 3), ("d", 3, 4)]),
        ]).segments
        let result = SpeakerAssigner.apply(
            turns: [SpeakerTurn(speakerID: "S1", start: 0, end: 10)], to: segments
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "S1")
        #expect(result[0].words.count == 4)
    }

    @Test func wordlessSegmentsPassThrough() {
        let empty = TranscriptOriginal.Segment(start: 0, end: 1, speaker: nil, words: [])
        let result = SpeakerAssigner.apply(turns: turns, to: [empty])
        #expect(result == [empty])
    }
}

@Suite("Speaker names")
struct SpeakerNamesTests {
    @Test func machineIDsGetDefaultDisplayNames() {
        #expect(SpeakerNames.defaultDisplayName(forID: "S1") == "Speaker 1")
        #expect(SpeakerNames.defaultDisplayName(forID: "S12") == "Speaker 12")
        #expect(SpeakerNames.defaultDisplayName(forID: "guest") == "guest")
        #expect(SpeakerNames.defaultDisplayName(forID: "S") == "S")
    }

    @Test func frontmatterRoundTripAndRemoval() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"Chat\"\n---\nbody")
        SpeakerNames.set(name: "Alice", forID: "S1", in: &doc)
        SpeakerNames.set(name: "Bob", forID: "S2", in: &doc)
        #expect(SpeakerNames.names(in: doc) == ["S1": "Alice", "S2": "Bob"])
        #expect(doc.value(for: "speaker_s1") == "Alice")

        // Empty or nil names remove the key entirely.
        SpeakerNames.set(name: "  ", forID: "S2", in: &doc)
        #expect(SpeakerNames.names(in: doc) == ["S1": "Alice"])
        #expect(doc.rawValue(for: "speaker_s2") == nil)

        // Unknown keys and the title line survive untouched.
        #expect(doc.title == "Chat")
    }

    @Test func displayNameFallsBackThroughTheMap() {
        let names = ["S1": "Alice"]
        #expect(SpeakerNames.displayName(forID: "S1", names: names) == "Alice")
        #expect(SpeakerNames.displayName(forID: "S2", names: names) == "Speaker 2")
    }

    @Test func speakerIDsAreOrderedByFirstAppearance() {
        let value = transcript([
            ("S2", [("hi", 0, 1)]),
            ("S1", [("yo", 1, 2)]),
            ("S2", [("ok", 2, 3)]),
            (nil, [("hm", 3, 4)]),
        ])
        #expect(SpeakerNames.speakerIDs(in: value) == ["S2", "S1"])
    }
}

@Suite("Speaker-labeled markdown and word map")
struct SpeakerMarkdownTests {
    private let diarized = transcript([
        ("S1", [("Hello", 0.0, 0.4), ("there.", 0.5, 0.9)]),
        ("S2", [("Hi!", 1.0, 1.4)]),
        ("S2", [("Still", 4.0, 4.3), ("me.", 4.4, 4.7)]), // 2.6 s pause, same speaker
    ])

    @Test func labelsAppearOnSpeakerChangesOnly() {
        let body = TranscriptMarkdown.body(from: diarized)
        #expect(body == "**Speaker 1:** Hello there.\n\n**Speaker 2:** Hi!\n\nStill me.")
    }

    @Test func renamesFlowIntoLabels() {
        let body = TranscriptMarkdown.body(from: diarized, speakerNames: ["S1": "Alice"])
        #expect(body == "**Alice:** Hello there.\n\n**Speaker 2:** Hi!\n\nStill me.")
    }

    @Test func labelsCanBeSuppressedForAutoTitling() {
        let body = TranscriptMarkdown.body(from: diarized, speakerLabels: false)
        #expect(body == "Hello there.\n\nHi!\n\nStill me.")
    }

    @Test func undiarizedTranscriptsRenderExactlyAsBefore() {
        let plain = transcript([
            (nil, [("Hello", 0, 0.4), ("world.", 0.5, 0.9), ("Next", 2.9, 3.2)]),
        ])
        #expect(TranscriptMarkdown.body(from: plain) == "Hello world.\n\nNext")
        #expect(TranscriptMarkdown.rendering(from: plain).labels.isEmpty)
    }

    @Test func generatedBodyRoundTripsWithNames() {
        let names = ["S1": "Alice", "S2": "Bob"]
        let body = TranscriptMarkdown.body(from: diarized, speakerNames: names)
        #expect(TranscriptMarkdown.isGeneratedBody(body, from: diarized, speakerNames: names))
        // Wrong names or a real edit compare unequal.
        #expect(!TranscriptMarkdown.isGeneratedBody(body, from: diarized))
        #expect(!TranscriptMarkdown.isGeneratedBody(
            body + " extra", from: diarized, speakerNames: names
        ))
    }

    @Test func isForkedExtractsNamesFromTheDocumentItself() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"Chat\"\n---\n")
        SpeakerNames.set(name: "Alice", forID: "S1", in: &doc)
        doc.body = "\n" + TranscriptMarkdown.body(
            from: diarized, speakerNames: SpeakerNames.names(in: doc)
        ) + "\n"
        #expect(!TranscriptEditDocument.isForked(doc, comparedTo: diarized))
        doc.body += "my own words\n"
        #expect(TranscriptEditDocument.isForked(doc, comparedTo: diarized))
    }

    @Test func wordMapStaysByteIdenticalToTheBodyWithLabels() {
        let names = ["S2": "Bob"]
        let map = TranscriptWordMap(transcript: diarized, speakerNames: names)
        #expect(map.renderedText == TranscriptMarkdown.body(from: diarized, speakerNames: names))
        #expect(map.speakerLabels.count == 2)

        let first = map.speakerLabels[0]
        let text = map.renderedText as NSString
        #expect(text.substring(with: NSRange(first.range)) == "**Speaker 1:**")
        #expect(first.speakerID == "S1")
        #expect(text.substring(with: NSRange(map.speakerLabels[1].range)) == "**Bob:**")
    }

    @Test func labelsAreSeparatorsNotWords() {
        let map = TranscriptWordMap(transcript: diarized)
        let firstLabel = map.speakerLabels[0]
        // Inside a label: no word run, no click-to-seek target.
        #expect(map.wordIndex(containingUTF16Offset: firstLabel.range.lowerBound + 3) == nil)
        #expect(map.speakerLabel(containingUTF16Offset: firstLabel.range.lowerBound + 3)?.speakerID == "S1")
        // The leading label precedes every word, so nearest-previous is nil.
        #expect(map.wordIndex(atOrBeforeUTF16Offset: firstLabel.range.lowerBound + 3) == nil)
        // Word lookups by time are unaffected by label text.
        #expect(map.wordIndex(atTime: 0.1) == 0)
        let helloRange = (map.renderedText as NSString).range(of: "Hello")
        #expect(map.wordIndex(containingUTF16Offset: helloRange.location + 1) == 0)
    }

    @Test func speakerChangeForcesParagraphBreakInTheMapToo() {
        // "Hi!" (word index 2) starts a paragraph despite only a 0.1 s pause.
        let map = TranscriptWordMap(transcript: diarized)
        let text = map.renderedText as NSString
        let hiRange = text.range(of: "Hi!")
        #expect(hiRange.location != NSNotFound)
        let before = text.substring(to: hiRange.location)
        #expect(before.hasSuffix("**Speaker 2:** "))
        #expect(map.wordIndex(containingUTF16Offset: hiRange.location) == 2)
        #expect(map.startTime(forWordAt: 2) == 1.0)
    }
}
