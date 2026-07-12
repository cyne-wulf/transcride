import Foundation
import Testing

@Suite("Transcript timing repair")
struct TranscriptTimingRepairTests {
    private func segment(_ words: [(String, Double, Double)]) -> TranscriptOriginal.Segment {
        let mapped = words.map { TranscriptOriginal.Word(text: $0.0, start: $0.1, end: $0.2) }
        return .init(
            start: mapped.first?.start ?? 0,
            end: mapped.last?.end ?? 0,
            words: mapped
        )
    }

    @Test func healthyTimingsRemainExactlyUnchanged() {
        let segments = [segment([
            ("Healthy", 0.12, 0.42), ("engine", 0.5, 0.88), ("timing", 1.0, 1.4),
        ])]
        let outcome = TranscriptTimingRepair.repair(segments: segments, duration: 2)
        #expect(outcome.segments == segments)
        #expect(!outcome.didRepair)
        #expect(!outcome.globallyDegraded)
    }

    @Test func realCollapsedTwentyOneWordShapeGetsPositiveMonotonicSpans() {
        let words = (0..<21).map { index in
            TranscriptOriginal.Word(
                text: index == 10 ? "substantially-longer" : "w\(index)",
                start: 7.25,
                end: index == 0 ? 7.5 : 7.25
            )
        }
        let segments = [TranscriptOriginal.Segment(start: 7.25, end: 99, words: words)]
        let outcome = TranscriptTimingRepair.repair(segments: segments, duration: 12)
        let repaired = outcome.segments[0].words

        #expect(outcome.didRepair)
        #expect(outcome.globallyDegraded)
        #expect(repaired.count == 21)
        #expect(repaired.first?.start == 0)
        #expect(repaired.last?.end == 12)
        #expect(repaired.allSatisfy { $0.end > $0.start })
        #expect(zip(repaired, repaired.dropFirst()).allSatisfy { pair in
            pair.0.end == pair.1.start
        })
        #expect((repaired[10].end - repaired[10].start) > (repaired[9].end - repaired[9].start))
        #expect(repaired.map(\.text) == words.map(\.text))
    }

    @Test func isolatedCollapsedRunIsRepairedBetweenHealthyAnchors() {
        let segments = [segment([
            ("one", 0, 0.4),
            ("bad", 1, 1), ("timing", 1, 1), ("run", 1, 1),
            ("five", 4, 4.4), ("six", 4.5, 4.9), ("seven", 5, 5.4), ("eight", 5.5, 5.9),
        ])]
        let outcome = TranscriptTimingRepair.repair(segments: segments, duration: 6)
        let words = outcome.segments[0].words

        #expect(!outcome.globallyDegraded)
        #expect(words[0] == segments[0].words[0])
        #expect(words[4...] == segments[0].words[4...])
        #expect(words[1].start == 0.4)
        #expect(words[3].end == 4)
        #expect(words[1...3].allSatisfy { $0.end > $0.start })
    }

    @Test func outOfBoundsAndBackwardsWordsAreRepairedAndClamped() {
        let segments = [segment([
            ("one", 0, 0.3),
            ("backwards", -1, -0.5),
            ("three", 1.2, 1.5),
            ("four", 1.6, 1.9),
            ("outside", 8, 9),
        ])]
        let outcome = TranscriptTimingRepair.repair(segments: segments, duration: 3)
        let words = outcome.segments[0].words

        #expect(!outcome.globallyDegraded)
        #expect(words[0] == segments[0].words[0])
        #expect(words[2] == segments[0].words[2])
        #expect(words[1].start == 0.3)
        #expect(words[1].end == 1.2)
        #expect(words[4].start == 1.9)
        #expect(words[4].end == 3)
    }

    @Test func decreasingEndTimeIsTreatedAsNonMonotonic() {
        let segments = [segment([
            ("one", 0, 0.8),
            ("backwards", 0.5, 0.6),
            ("three", 1.2, 1.5),
            ("four", 1.6, 1.9),
        ])]
        let outcome = TranscriptTimingRepair.repair(segments: segments, duration: 2)
        let words = outcome.segments[0].words

        #expect(!outcome.globallyDegraded)
        #expect(words[0] == segments[0].words[0])
        #expect(words[1].start == 0.8)
        #expect(words[1].end == 1.2)
        #expect(words[2] == segments[0].words[2])
    }
}

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

    @Test func repairedCollapsedMapAdvancesAcrossPlaybackAndScrubTimes() {
        let value = transcript((0..<21).map { ("word\($0)", 5.0, 5.0) })
        let map = TranscriptWordMap(transcript: value, duration: 21)
        let early = map.wordIndex(atTime: 0.1)
        let middle = map.wordIndex(atTime: 10.5)
        let late = map.wordIndex(atTime: 20.9)

        #expect(early != nil)
        #expect(middle != nil)
        #expect(late != nil)
        #expect(early! < middle!)
        #expect(middle! < late!)
    }

    @Test func timingRepairDoesNotShiftUTF16WordOrSpeakerRanges() throws {
        let value = TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [
                .init(start: 8, end: 8, speaker: "speaker_0", words: [
                    .init(text: "Hi", start: 8, end: 8),
                    .init(text: "👋🏽", start: 8, end: 8),
                    .init(text: "Ashan", start: 8, end: 8),
                ]),
                .init(start: 9, end: 9.4, speaker: "speaker_1", words: [
                    .init(text: "reply", start: 9, end: 9.4),
                ]),
            ]
        )
        let original = TranscriptWordMap(
            transcript: value,
            speakerNames: ["speaker_0": "Ashan", "speaker_1": "Guest"]
        )
        let repaired = TranscriptWordMap(
            transcript: value,
            duration: 10,
            speakerNames: ["speaker_0": "Ashan", "speaker_1": "Guest"]
        )

        #expect(repaired.renderedText == original.renderedText)
        #expect(repaired.spans.map(\.range) == original.spans.map(\.range))
        #expect(repaired.spans.map(\.wordIndex) == original.spans.map(\.wordIndex))
        #expect(repaired.speakerLabels == original.speakerLabels)
        #expect(try #require(repaired.range(forWordAt: 1)).count == 4)
    }

    @Test func editedPlaybackKeepsAnUnchangedBodyFullySynced() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let edited = EditedTranscriptPlaybackMap(original: original, editedBody: "one two three")

        #expect(edited.boundaryWordIndex == nil)
        #expect(edited.boundaryStartTime == nil)
        #expect(edited.cueRange == nil)
        #expect(edited.range(forWordAt: 2) == 8..<13)
    }

    @Test func editedPlaybackIgnoresSerializedBodyPaddingAndOffsetsRanges() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let unchanged = EditedTranscriptPlaybackMap(
            original: original, editedBody: "\n\none two three\n"
        )
        let changed = EditedTranscriptPlaybackMap(
            original: original, editedBody: "\n\none changed three\n"
        )

        #expect(unchanged.boundaryWordIndex == nil)
        #expect(unchanged.range(forWordAt: 0) == 2..<5)
        #expect(unchanged.range(forWordAt: 2) == 10..<15)
        #expect(changed.range(forWordAt: 0) == 2..<5)
        #expect(changed.boundaryWordIndex == 1)
        #expect(changed.boundaryStartTime == 0.3)
        #expect(changed.cueRange == 6..<13)
    }

    @Test func editedPlaybackStopsBeforeReplacementAndCuesChangedToken() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let body = "one changed three"
        let edited = EditedTranscriptPlaybackMap(original: original, editedBody: body)

        #expect(edited.range(forWordAt: 0) == 0..<3)
        #expect(edited.range(forWordAt: 1) == nil)
        #expect(edited.boundaryWordIndex == 1)
        #expect(edited.boundaryStartTime == 0.3)
        #expect(edited.cueRange == 4..<11)
    }

    @Test func editedPlaybackHandlesFirstWordAndWhitespaceEdits() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let firstWord = EditedTranscriptPlaybackMap(
            original: original, editedBody: "ONE two three"
        )
        let whitespace = EditedTranscriptPlaybackMap(
            original: original, editedBody: "one  two three"
        )

        #expect(firstWord.boundaryWordIndex == 0)
        #expect(firstWord.cueRange == 0..<3)
        #expect(whitespace.range(forWordAt: 0) == 0..<3)
        #expect(whitespace.boundaryWordIndex == 1)
        #expect(whitespace.cueRange == 5..<8)
    }

    @Test func editedPlaybackHandlesInsertionAndMiddleDeletion() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let insertion = EditedTranscriptPlaybackMap(
            original: original, editedBody: "one added two three"
        )
        let deletion = EditedTranscriptPlaybackMap(original: original, editedBody: "one three")

        #expect(insertion.boundaryWordIndex == 1)
        #expect(insertion.cueRange == 4..<9)
        #expect(deletion.boundaryWordIndex == 1)
        #expect(deletion.cueRange == 4..<9)
    }

    @Test func editedPlaybackSuffixDeletionCuesLastSurvivingToken() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let edited = EditedTranscriptPlaybackMap(original: original, editedBody: "one two")

        #expect(edited.boundaryWordIndex == 2)
        #expect(edited.boundaryStartTime == 0.6)
        #expect(edited.cueRange == 4..<7)
    }

    @Test func editedPlaybackAppendLeavesEveryOriginalWordSynced() {
        let original = TranscriptWordMap(transcript: transcript([
            ("one", 0, 0.2), ("two", 0.3, 0.5), ("three", 0.6, 0.9),
        ]))
        let edited = EditedTranscriptPlaybackMap(
            original: original, editedBody: "one two three added"
        )

        #expect(edited.boundaryWordIndex == nil)
        #expect(edited.cueRange == nil)
        #expect(edited.range(forWordAt: 2) == 8..<13)
    }

    @Test func editedPlaybackUsesUTF16OffsetsForEmojiAndPartialWords() {
        let original = TranscriptWordMap(transcript: transcript([
            ("Hi", 0, 0.2), ("👋🏽", 0.3, 0.5), ("friend", 0.6, 0.9),
        ]))
        let emojiEdit = EditedTranscriptPlaybackMap(
            original: original, editedBody: "Hi 👋 friend"
        )
        let partialWord = EditedTranscriptPlaybackMap(
            original: original, editedBody: "Hi 👋🏽 friEND"
        )

        #expect(emojiEdit.boundaryWordIndex == 1)
        #expect(emojiEdit.cueRange == 3..<5)
        #expect(partialWord.boundaryWordIndex == 2)
        #expect(partialWord.cueRange == 8..<14)
    }

    @Test func editedPlaybackIncludesSpeakerLabelsInBoundaryCoordinates() {
        let value = TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: 0, end: 0.8, speaker: "speaker_0", words: [
                .init(text: "hello", start: 0, end: 0.3),
                .init(text: "there", start: 0.4, end: 0.8),
            ])]
        )
        let original = TranscriptWordMap(
            transcript: value, speakerNames: ["speaker_0": "Ashan"]
        )
        let body = original.renderedText.replacingOccurrences(of: "there", with: "friend")
        let edited = EditedTranscriptPlaybackMap(
            original: original, editedBody: body
        )

        #expect(edited.range(forWordAt: 0) == original.range(forWordAt: 0))
        #expect(edited.boundaryWordIndex == 1)
        #expect(edited.cueRange.map { (body as NSString).substring(with: NSRange($0)) } == "friend")
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
        #expect(abs(gap.start - 2.3) < 0.000_001)
        #expect(gap.end == 3.9)
        #expect(gap.previousWordIndex == 1)
        #expect(gap.nextWordIndex == 2)
        #expect(abs(gap.duration - 1.6) < 0.000_001)
    }

    @Test func thresholdIsTunableAndSkipUsesHalfOpenGap() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("one", 0, 0.2), ("two", 1.0, 1.2),
        ]), threshold: 0.5)
        let gap = try #require(gaps.first)
        #expect(abs(gap.start - 0.3) < 0.000_001)
        #expect(gap.end == 0.9)
        #expect(SilenceGap.skipDestination(at: gap.start, in: gaps) == 0.9)
        #expect(SilenceGap.skipDestination(at: 0.899, in: gaps) == 0.9)
        #expect(SilenceGap.skipDestination(at: gap.end, in: gaps) == nil)
    }

    @Test func leadingSilenceIsSkippedEvenForAOneWordClip() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("hello", 2.0, 2.4),
        ]), threshold: 1.5)
        let gap = try #require(gaps.first)
        #expect(gaps.count == 1)
        #expect(gap.start == 0.1)
        #expect(gap.end == 1.9)
        #expect(gap.previousWordIndex == 0)
        #expect(gap.nextWordIndex == 0)
        #expect(SilenceGap.skipDestination(at: 0, in: gaps) == nil)
        #expect(SilenceGap.skipDestination(at: 0.1, in: gaps) == 1.9)
        #expect(SilenceGap.skipDestination(at: 1.899, in: gaps) == 1.9)
        #expect(SilenceGap.skipDestination(at: 1.9, in: gaps) == nil)
    }

    @Test func leadingSilenceMustBeStrictlyLongerThanThreshold() {
        let gaps = SilenceGap.compute(from: transcript([
            ("hello", 1.5, 1.9), ("world", 2.0, 2.4),
        ]), threshold: 1.5)
        #expect(gaps.isEmpty)
    }

    @Test func trailingSilenceIsSkippedWithCompressionPadding() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("goodbye", 0.2, 0.6),
        ]), duration: 3.0, threshold: 1.5)
        let gap = try #require(gaps.first)
        #expect(gaps.count == 1)
        #expect(abs(gap.start - 0.7) < 0.000_001)
        #expect(gap.end == 2.9)
        #expect(gap.previousWordIndex == 0)
        #expect(gap.nextWordIndex == 0)
        #expect(SilenceGap.skipDestination(at: 0.699, in: gaps) == nil)
        #expect(SilenceGap.skipDestination(at: 0.7, in: gaps) == 2.9)
        #expect(SilenceGap.skipDestination(at: 2.899, in: gaps) == 2.9)
        #expect(SilenceGap.skipDestination(at: 2.9, in: gaps) == nil)
    }

    @Test func trailingSilenceNeedsDurationAndMustExceedThreshold() {
        let value = transcript([("goodbye", 0.2, 0.6)])
        #expect(SilenceGap.compute(from: value, threshold: 1.5).isEmpty)
        #expect(SilenceGap.compute(from: value, duration: 2.1, threshold: 1.5).isEmpty)
    }

    @Test func waveformSilenceUsesTheCompressionAmplitudeAndPaddingPlan() throws {
        let peaks = Array(repeating: Float(0), count: 40) // 2 seconds at 20 peaks/s
            + Array(repeating: Float(0.2), count: 20)
        let waveform = WaveformData(peaksPerSecond: 20, duration: 3, peaks: peaks)
        let gaps = SilenceGap.compute(from: waveform)
        let gap = try #require(gaps.first)
        #expect(gaps.count == 1)
        #expect(gap.start == AudioCompressionPlan.boundaryPadding)
        #expect(abs(gap.end - 1.9) < 0.000_001)

        let compressionPlan = AudioCompressionPlan.make(
            windowPeaks: waveform.peaks,
            windowDuration: 1 / Double(waveform.peaksPerSecond),
            sourceDuration: waveform.duration
        )
        #expect(compressionPlan.removedIntervals == [
            AudioCompressionInterval(start: gap.start, end: gap.end),
        ])
    }

    @Test func waveformDoesNotSkipAudioAboveCompressionSilenceThreshold() {
        let justAudible = AudioCompressionPlan.silenceAmplitudeThreshold + 0.001
        let waveform = WaveformData(
            peaksPerSecond: 20,
            duration: 2,
            peaks: Array(repeating: justAudible, count: 40)
        )
        #expect(SilenceGap.compute(from: waveform).isEmpty)
    }

    @Test func whitespaceWordsDoNotSplitRealWordGaps() throws {
        let gaps = SilenceGap.compute(from: transcript([
            ("one", 0, 0.2), (" ", 1.0, 1.1), ("two", 2.0, 2.2),
        ]), threshold: 1.5)
        let gap = try #require(gaps.first)
        #expect(gap.previousWordIndex == 0)
        #expect(gap.nextWordIndex == 2)
        #expect(abs(gap.start - 0.3) < 0.000_001)
        #expect(gap.end == 1.9)
    }

    @Test func malformedLegacyTimingIsRepairedBeforeGapDetection() {
        let value = transcript([
            ("one", 20, 20), ("two", 20, 20), ("three", 20, 20), ("four", 20, 20),
        ])
        let gaps = SilenceGap.compute(from: value, duration: 4)
        #expect(gaps.isEmpty)
    }
}
