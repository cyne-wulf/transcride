import Foundation

/// One deterministic rendering of a transcript: the text plus the UTF-16
/// ranges of every word run and speaker label in it. `TranscriptMarkdown` and
/// `TranscriptWordMap` both consume this single walk, which is what keeps the
/// generated `transcript.md` body, the search-index content, and the synced
/// view's coordinates byte-identical by construction.
struct TranscriptRendering: Equatable, Sendable {
    struct WordSpan: Equatable, Sendable {
        /// Index in `TranscriptOriginal.allWords`. Empty/whitespace-only words
        /// are omitted from `words`, but do not renumber later words.
        var wordIndex: Int
        var range: Range<Int>
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    struct SpeakerLabel: Equatable, Sendable {
        var speakerID: String
        /// Range of the whole markdown label, `**Name:**`, asterisks included.
        var range: Range<Int>
    }

    var text: String
    var words: [WordSpan]
    var labels: [SpeakerLabel]
}

/// Generates the human-facing `transcript.md` body from a `TranscriptOriginal`
/// and knows whether an existing body is still machine-generated (so a
/// retranscribe may regenerate it) or was hand-edited (M4+) and must be left
/// alone.
enum TranscriptMarkdown {
    /// A silence this long between consecutive words starts a new paragraph.
    static let paragraphPauseThreshold: TimeInterval = 2.0

    /// The single rendering walk. Words are joined with single spaces;
    /// paragraphs (blank-line separated) start on long pauses and on speaker
    /// changes. Diarized transcripts (TRN-6) get a markdown `**Name:**` label
    /// at the start of each paragraph whose speaker differs from the previous
    /// paragraph's; `speakerNames` maps machine ids to chosen names, falling
    /// back to "Speaker N". Transcripts without speakers render exactly as
    /// they did before diarization existed.
    static func rendering(
        from transcript: TranscriptOriginal,
        speakerNames: [String: String] = [:],
        speakerLabels includeLabels: Bool = true
    ) -> TranscriptRendering {
        var text = ""
        var words: [TranscriptRendering.WordSpan] = []
        var labels: [TranscriptRendering.SpeakerLabel] = []
        var previousEnd: TimeInterval?
        var currentSpeaker: String?
        var started = false
        var wordIndex = -1

        for segment in transcript.segments {
            for word in segment.words {
                wordIndex += 1
                let wordText = word.text.trimmingCharacters(in: .whitespaces)
                guard !wordText.isEmpty else { continue }

                let speakerChanged = started && segment.speaker != currentSpeaker
                if started {
                    let pauseBreak = previousEnd.map {
                        word.start - $0 >= paragraphPauseThreshold
                    } ?? false
                    text += (speakerChanged || pauseBreak) ? "\n\n" : " "
                }
                if includeLabels, let speaker = segment.speaker, !started || speakerChanged {
                    let name = SpeakerNames.displayName(forID: speaker, names: speakerNames)
                    let lowerBound = text.utf16.count
                    text += "**\(name):**"
                    labels.append(.init(speakerID: speaker, range: lowerBound..<text.utf16.count))
                    text += " "
                }
                let lowerBound = text.utf16.count
                text += wordText
                words.append(.init(
                    wordIndex: wordIndex,
                    range: lowerBound..<text.utf16.count,
                    startTime: word.start,
                    endTime: word.end
                ))
                previousEnd = word.end
                currentSpeaker = segment.speaker
                started = true
            }
        }
        return TranscriptRendering(text: text, words: words, labels: labels)
    }

    /// Plain transcript text, paragraph-broken on long pauses and speaker
    /// changes, with markdown speaker labels when the transcript is diarized.
    static func body(
        from transcript: TranscriptOriginal,
        speakerNames: [String: String] = [:],
        speakerLabels: Bool = true
    ) -> String {
        rendering(from: transcript, speakerNames: speakerNames, speakerLabels: speakerLabels).text
    }

    /// True when `existingBody` is what we would generate from `transcript` —
    /// i.e. the file is still machine-generated and safe to regenerate.
    /// Whitespace-normalized so incidental trailing-newline differences don't
    /// count as edits; any real text change does. Unknown/legacy generation
    /// formats compare unequal, which errs on the safe side (never overwrite).
    static func isGeneratedBody(
        _ existingBody: String,
        from transcript: TranscriptOriginal,
        speakerNames: [String: String] = [:]
    ) -> Bool {
        normalize(existingBody) == normalize(body(from: transcript, speakerNames: speakerNames))
    }

    /// An empty body (the M2 stub) is always safe to fill in.
    static func isStubBody(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
