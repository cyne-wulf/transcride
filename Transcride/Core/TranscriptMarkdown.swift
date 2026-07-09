import Foundation

/// Generates the human-facing `transcript.md` body from a `TranscriptOriginal`
/// and knows whether an existing body is still machine-generated (so a
/// retranscribe may regenerate it) or was hand-edited (M4+) and must be left
/// alone.
enum TranscriptMarkdown {
    /// A silence this long between consecutive words starts a new paragraph.
    static let paragraphPauseThreshold: TimeInterval = 2.0

    /// Plain transcript text, paragraph-broken on long pauses. Words are
    /// joined with single spaces; paragraphs with blank lines.
    static func body(from transcript: TranscriptOriginal) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var lastEnd: Double?

        for segment in transcript.segments {
            for word in segment.words {
                let text = word.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if let lastEnd, word.start - lastEnd >= paragraphPauseThreshold, !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
                current.append(text)
                lastEnd = word.end
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// True when `existingBody` is what we would generate from `transcript` —
    /// i.e. the file is still machine-generated and safe to regenerate.
    /// Whitespace-normalized so incidental trailing-newline differences don't
    /// count as edits; any real text change does. Unknown/legacy generation
    /// formats compare unequal, which errs on the safe side (never overwrite).
    static func isGeneratedBody(_ existingBody: String, from transcript: TranscriptOriginal) -> Bool {
        normalize(existingBody) == normalize(body(from: transcript))
    }

    /// An empty body (the M2 stub) is always safe to fill in.
    static func isStubBody(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
