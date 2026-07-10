import Foundation

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

    init(transcript: TranscriptOriginal, speakerNames: [String: String] = [:]) {
        // The map shares TranscriptMarkdown's rendering walk, so renderedText
        // stays byte-identical to the generated body — search offsets, word
        // runs, and markdown all live in one coordinate space.
        let rendering = TranscriptMarkdown.rendering(from: transcript, speakerNames: speakerNames)
        renderedText = rendering.text
        spans = rendering.words.map {
            Span(
                wordIndex: $0.wordIndex,
                range: $0.range,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        speakerLabels = rendering.labels
    }

    func range(forWordAt wordIndex: Int) -> Range<Int>? {
        spans.first(where: { $0.wordIndex == wordIndex })?.range
    }

    /// Returns a word only when the character is inside its rendered run.
    /// Separating spaces, paragraph breaks and speaker labels deliberately
    /// return nil.
    func wordIndex(containingUTF16Offset offset: Int) -> Int? {
        spans.first(where: { $0.range.contains(offset) })?.wordIndex
    }

    /// The speaker label under a character, for click-to-rename (TRN-6).
    func speakerLabel(containingUTF16Offset offset: Int) -> TranscriptRendering.SpeakerLabel? {
        speakerLabels.first(where: { $0.range.contains(offset) })
    }

    /// Best-effort lookup for clicks or search offsets that land on separator
    /// text: the containing word wins, otherwise the nearest previous word.
    func wordIndex(atOrBeforeUTF16Offset offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        var previous: Span?
        for span in spans {
            if span.range.contains(offset) { return span.wordIndex }
            if span.range.lowerBound > offset { break }
            previous = span
        }
        return previous?.wordIndex
    }

    /// Word active at an audio time. Inter-word gaps and time after the final
    /// word resolve to the nearest previous word; time before the first word
    /// has no mapping. Ranges are `[start, end)`.
    func wordIndex(atTime time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        var previous: Span?
        for span in spans {
            if time < span.startTime { return previous?.wordIndex }
            if time < span.endTime { return span.wordIndex }
            previous = span
        }
        return previous?.wordIndex
    }

    func startTime(forWordAt wordIndex: Int) -> TimeInterval? {
        spans.first(where: { $0.wordIndex == wordIndex })?.startTime
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
