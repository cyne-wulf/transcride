import Foundation

/// Validates engine-supplied word timing and repairs only the unusable parts.
/// The repair is pure so both newly produced transcripts and immutable legacy
/// originals can use the same rules without rewriting files on disk.
enum TranscriptTimingRepair {
    struct Outcome: Equatable, Sendable {
        var segments: [TranscriptOriginal.Segment]
        var didRepair: Bool
        /// Most of the timing stream was unusable. Engines can use this to
        /// retry with segment timestamps rather than persisting synthetic
        /// timing derived from a broken word-alignment pass.
        var globallyDegraded: Bool
    }

    private struct Address {
        var segment: Int
        var word: Int
    }

    private static let equalityTolerance: TimeInterval = 0.001

    static func repair(
        segments: [TranscriptOriginal.Segment],
        duration: TimeInterval
    ) -> Outcome {
        guard duration.isFinite, duration > 0 else {
            return Outcome(segments: segments, didRepair: false, globallyDegraded: false)
        }

        var addresses: [Address] = []
        var words: [TranscriptOriginal.Word] = []
        for (segmentIndex, segment) in segments.enumerated() {
            for (wordIndex, word) in segment.words.enumerated() {
                addresses.append(Address(segment: segmentIndex, word: wordIndex))
                words.append(word)
            }
        }
        guard !words.isEmpty else {
            let repaired = repairedSegmentBounds(in: segments, duration: duration)
            return Outcome(
                segments: repaired,
                didRepair: segments != repaired,
                globallyDegraded: false
            )
        }

        var bad = words.map { word in
            !word.start.isFinite || !word.end.isFinite
                || word.start < 0 || word.end <= word.start || word.end > duration
        }

        // A later word may overlap slightly with the previous one, but its
        // start and end must never run backwards through the transcript.
        var previousStart: TimeInterval?
        var previousEnd: TimeInterval?
        for index in words.indices where !bad[index] {
            if let previousStart,
               words[index].start < previousStart - equalityTolerance
                || words[index].end < (previousEnd ?? previousStart) - equalityTolerance {
                bad[index] = true
            } else {
                previousStart = words[index].start
                previousEnd = words[index].end
            }
        }

        // WhisperKit's observed failure mode is a long run sharing one start
        // value (usually accompanied by zero-length words). Three words is
        // long enough to distinguish it from a plausible simultaneous token.
        var runStart = 0
        while runStart < words.count {
            var runEnd = runStart + 1
            while runEnd < words.count,
                  words[runEnd].start.isFinite,
                  words[runStart].start.isFinite,
                  abs(words[runEnd].start - words[runStart].start) <= equalityTolerance {
                runEnd += 1
            }
            if runEnd - runStart >= 3 {
                for index in runStart..<runEnd { bad[index] = true }
            }
            runStart = runEnd
        }

        let badCount = bad.lazy.filter { $0 }.count
        var globallyDegraded = badCount >= 3 && badCount * 2 >= words.count

        var repairedWords = words
        if globallyDegraded {
            repairedWords = distribute(words: words, from: 0, to: duration)
        } else {
            var index = 0
            while index < words.count {
                guard bad[index] else { index += 1; continue }
                let start = index
                while index < words.count, bad[index] { index += 1 }
                let end = index
                let lower = start > 0 ? repairedWords[start - 1].end : 0
                let upper = end < words.count ? words[end].start : duration
                guard lower.isFinite, upper.isFinite, upper > lower else {
                    // There is no safe interval between the neighboring
                    // anchors. Retiming the full stream is the only way to
                    // guarantee positive, monotonic spans.
                    repairedWords = distribute(words: words, from: 0, to: duration)
                    globallyDegraded = true
                    break
                }
                let replacement = distribute(words: Array(words[start..<end]), from: lower, to: upper)
                for (offset, word) in replacement.enumerated() {
                    repairedWords[start + offset] = word
                }
            }
        }

        var repairedSegments = segments
        for index in addresses.indices {
            let address = addresses[index]
            repairedSegments[address.segment].words[address.word] = repairedWords[index]
        }
        for segmentIndex in repairedSegments.indices {
            let changed = repairedSegments[segmentIndex].words != segments[segmentIndex].words
            let segment = repairedSegments[segmentIndex]
            let boundsInvalid = !segment.start.isFinite || !segment.end.isFinite
                || segment.start < 0 || segment.end <= segment.start || segment.end > duration
            if changed || boundsInvalid, let first = segment.words.first, let last = segment.words.last {
                repairedSegments[segmentIndex].start = first.start
                repairedSegments[segmentIndex].end = last.end
            }
        }

        return Outcome(
            segments: repairedSegments,
            didRepair: repairedSegments != segments,
            globallyDegraded: globallyDegraded
        )
    }

    /// Assigns positive contiguous spans weighted by visible word length.
    /// Exact text and correction metadata are retained.
    static func distribute(
        words: [TranscriptOriginal.Word],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> [TranscriptOriginal.Word] {
        guard !words.isEmpty, start.isFinite, end.isFinite, end > start else { return words }
        let weights = words.map {
            Double(max(1, $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count))
        }
        let totalWeight = weights.reduce(0, +)
        var cursor = start
        return words.indices.map { index in
            var word = words[index]
            let wordEnd = index == words.index(before: words.endIndex)
                ? end
                : cursor + (end - start) * weights[index] / totalWeight
            word.start = cursor
            word.end = wordEnd
            cursor = wordEnd
            return word
        }
    }

    private static func repairedSegmentBounds(
        in segments: [TranscriptOriginal.Segment], duration: TimeInterval
    ) -> [TranscriptOriginal.Segment] {
        var result = segments
        for index in result.indices {
            let segment = result[index]
            guard !segment.start.isFinite || !segment.end.isFinite
                    || segment.start < 0 || segment.end <= segment.start || segment.end > duration else {
                continue
            }
            let start = min(max(segment.start.isFinite ? segment.start : 0, 0), duration)
            let end = min(max(segment.end.isFinite ? segment.end : duration, start), duration)
            result[index].start = start
            result[index].end = end
        }
        return result
    }
}

/// Deterministic word, rendered-character, and audio-time mapping for the
/// original transcript layer. Character offsets are UTF-16 offsets so ranges
/// can be passed directly to AppKit text APIs as `NSRange` values.
struct TranscriptWordMap: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        /// Index in `TranscriptOriginal.allWords`. Empty/whitespace-only words
        /// are omitted from `spans`, but do not renumber later words.
        var wordIndex: Int
        var range: Range<Int>
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    let renderedText: String
    let spans: [Span]
    /// Rendered speaker labels (`**Name:**` runs) for diarized transcripts.
    /// Labels are separator text: they never resolve to a word and never
    /// highlight, but the view styles them and routes clicks to rename.
    let speakerLabels: [TranscriptRendering.SpeakerLabel]
    private let hasMonotonicTimings: Bool

    init(
        transcript: TranscriptOriginal,
        duration: TimeInterval? = nil,
        speakerNames: [String: String] = [:],
        speakerDetectionEnabled: Bool = true
    ) {
        // The map shares TranscriptMarkdown's rendering walk, so renderedText
        // stays byte-identical to the generated body — search offsets, word
        // runs, and markdown all live in one coordinate space.
        let rendering = TranscriptMarkdown.rendering(
            from: transcript,
            speakerNames: speakerNames,
            speakerDetectionEnabled: speakerDetectionEnabled
        )
        renderedText = rendering.text
        let repairedWords: [TranscriptOriginal.Word]? = duration.map {
            TranscriptTimingRepair.repair(segments: transcript.segments, duration: $0)
                .segments.flatMap(\.words)
        }
        let builtSpans = rendering.words.map {
            let timing = repairedWords?[$0.wordIndex]
            return Span(
                wordIndex: $0.wordIndex,
                range: $0.range,
                startTime: timing?.start ?? $0.startTime,
                endTime: timing?.end ?? $0.endTime
            )
        }
        spans = builtSpans
        speakerLabels = rendering.labels
        hasMonotonicTimings = zip(builtSpans, builtSpans.dropFirst()).allSatisfy {
            $0.startTime <= $1.startTime && $0.endTime <= $1.endTime
        }
    }

    func range(forWordAt wordIndex: Int) -> Range<Int>? {
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].wordIndex < wordIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count, spans[lower].wordIndex == wordIndex else { return nil }
        return spans[lower].range
    }

    /// Returns a word only when the character is inside its rendered run.
    /// Separating spaces, paragraph breaks and speaker labels deliberately
    /// return nil.
    func wordIndex(containingUTF16Offset offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].range.upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count, spans[lower].range.contains(offset) else { return nil }
        return spans[lower].wordIndex
    }

    /// The speaker label under a character, for click-to-rename (TRN-6).
    func speakerLabel(containingUTF16Offset offset: Int) -> TranscriptRendering.SpeakerLabel? {
        guard offset >= 0 else { return nil }
        var lower = 0
        var upper = speakerLabels.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if speakerLabels[middle].range.upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < speakerLabels.count,
              speakerLabels[lower].range.contains(offset) else { return nil }
        return speakerLabels[lower]
    }

    /// Best-effort lookup for clicks or search offsets that land on separator
    /// text: the containing word wins, otherwise the nearest previous word.
    func wordIndex(atOrBeforeUTF16Offset offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].range.lowerBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return spans[lower - 1].wordIndex
    }

    /// Word active at an audio time. Inter-word gaps and time after the final
    /// word resolve to the nearest previous word; time before the first word
    /// has no mapping. Ranges are `[start, end)`.
    func wordIndex(atTime time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        guard hasMonotonicTimings else {
            var previous: Span?
            for span in spans {
                if time < span.startTime { return previous?.wordIndex }
                if time < span.endTime { return span.wordIndex }
                previous = span
            }
            return previous?.wordIndex
        }

        var startLower = 0
        var startUpper = spans.count
        while startLower < startUpper {
            let middle = startLower + (startUpper - startLower) / 2
            if spans[middle].startTime <= time {
                startLower = middle + 1
            } else {
                startUpper = middle
            }
        }
        guard startLower > 0 else { return nil }

        var endLower = 0
        var endUpper = startLower
        while endLower < endUpper {
            let middle = endLower + (endUpper - endLower) / 2
            if spans[middle].endTime <= time {
                endLower = middle + 1
            } else {
                endUpper = middle
            }
        }
        let index = endLower < startLower ? endLower : startLower - 1
        return spans[index].wordIndex
    }

    func startTime(forWordAt wordIndex: Int) -> TimeInterval? {
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].wordIndex < wordIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count, spans[lower].wordIndex == wordIndex else { return nil }
        return spans[lower].startTime
    }

    func startTime(atOrBeforeUTF16Offset offset: Int) -> TimeInterval? {
        guard let wordIndex = wordIndex(atOrBeforeUTF16Offset: offset) else { return nil }
        return startTime(forWordAt: wordIndex)
    }

    /// Best-effort cue for an edited-layer search match (SRCH-3). Edits shift
    /// character offsets arbitrarily, so the matched text is re-located in the
    /// timed rendering by case-insensitive occurrence ordinal instead. Returns
    /// nil when the phrase no longer appears in the original — edited-only
    /// text simply has no audio moment.
    func startTime(forMatch matchRange: Range<Int>, inEditedBody body: String) -> TimeInterval? {
        let nsBody = body as NSString
        let nsRange = NSRange(location: matchRange.lowerBound, length: matchRange.count)
        guard nsRange.location >= 0, NSMaxRange(nsRange) <= nsBody.length else { return nil }
        let phrase = nsBody.substring(with: nsRange)
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let bodyOccurrences = Self.caseInsensitiveOccurrences(of: phrase, in: nsBody)
        let ordinal = bodyOccurrences.firstIndex(of: nsRange.location) ?? 0
        let renderedOccurrences = Self.caseInsensitiveOccurrences(
            of: phrase, in: renderedText as NSString
        )
        guard !renderedOccurrences.isEmpty else { return nil }
        let offset = renderedOccurrences[min(ordinal, renderedOccurrences.count - 1)]
        return startTime(atOrBeforeUTF16Offset: offset)
    }

    private static func caseInsensitiveOccurrences(of phrase: String, in text: NSString) -> [Int] {
        var locations: [Int] = []
        var searchLocation = 0
        while searchLocation < text.length {
            let found = text.range(
                of: phrase,
                options: .caseInsensitive,
                range: NSRange(location: searchLocation, length: text.length - searchLocation)
            )
            guard found.location != NSNotFound else { break }
            locations.append(found.location)
            searchLocation = found.location + max(found.length, 1)
        }
        return locations
    }
}

/// Playback-safe projection of the immutable word map into a hand-edited
/// Markdown body. Only the byte-identical UTF-16 prefix can retain karaoke
/// timing; the first divergence becomes a visible boundary and every later
/// word deliberately loses its audio mapping.
struct EditedTranscriptPlaybackMap: Equatable, Sendable {
    let unchangedUTF16PrefixLength: Int
    let boundaryWordIndex: Int?
    let boundaryStartTime: TimeInterval?
    let cueRange: Range<Int>?

    private let original: TranscriptWordMap
    private let editedContentOffset: Int

    init(original: TranscriptWordMap, editedBody: String) {
        self.original = original
        let originalText = original.renderedText as NSString
        let editedText = editedBody as NSString
        let contentOffset = Self.firstNonWhitespaceOffset(in: editedText)
        editedContentOffset = contentOffset
        let sharedLength = min(originalText.length, max(0, editedText.length - contentOffset))
        var prefixLength = 0
        while prefixLength < sharedLength,
              originalText.character(at: prefixLength)
                == editedText.character(at: contentOffset + prefixLength) {
            prefixLength += 1
        }
        unchangedUTF16PrefixLength = prefixLength

        let boundary = original.spans.first { $0.range.upperBound > prefixLength }
        boundaryWordIndex = boundary?.wordIndex
        boundaryStartTime = boundary?.startTime
        cueRange = boundary == nil
            ? nil
            : Self.tokenRange(atOrAfter: contentOffset + prefixLength, in: editedText)
    }

    /// The edited body shares coordinates with the original only through the
    /// exact prefix. A partly edited word is excluded in full.
    func range(forWordAt wordIndex: Int) -> Range<Int>? {
        guard let range = original.range(forWordAt: wordIndex),
              range.upperBound <= unchangedUTF16PrefixLength else { return nil }
        return (range.lowerBound + editedContentOffset)..<(range.upperBound + editedContentOffset)
    }

    private static func firstNonWhitespaceOffset(in text: NSString) -> Int {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var offset = 0
        while offset < text.length,
              scalar(at: offset, in: text).map(whitespace.contains) == true {
            offset += 1
        }
        return offset
    }

    private static func tokenRange(atOrAfter offset: Int, in text: NSString) -> Range<Int>? {
        guard text.length > 0 else { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines
        var position = min(max(offset, 0), text.length - 1)

        // Insertions and replacements cue the first visible token at the
        // divergence. If the divergence lands immediately after a token (for
        // example removing an emoji modifier or deleting a suffix), that
        // preceding token is the changed visible run.
        if scalar(at: position, in: text).map(whitespace.contains) == true,
           position > 0,
           scalar(at: position - 1, in: text).map(whitespace.contains) != true {
            position -= 1
        }
        while position < text.length,
              scalar(at: position, in: text).map(whitespace.contains) == true {
            position += 1
        }
        if position == text.length {
            position = min(max(offset - 1, 0), text.length - 1)
            while position > 0,
                  scalar(at: position, in: text).map(whitespace.contains) == true {
                position -= 1
            }
        }
        guard scalar(at: position, in: text).map(whitespace.contains) != true else { return nil }

        var lower = position
        while lower > 0,
              scalar(at: lower - 1, in: text).map(whitespace.contains) != true {
            lower -= 1
        }
        var upper = position + 1
        while upper < text.length,
              scalar(at: upper, in: text).map(whitespace.contains) != true {
            upper += 1
        }
        return lower..<upper
    }

    /// UTF-16 surrogate code units are intentionally treated as non-whitespace;
    /// token expansion therefore includes the complete adjacent surrogate run.
    private static func scalar(at offset: Int, in text: NSString) -> UnicodeScalar? {
        UnicodeScalar(text.character(at: offset))
    }
}
