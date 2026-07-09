import Foundation

/// Auto-titling (TRN-7): entries still named "New Recording" get their title
/// from the first meaningful transcript line. User-set titles are never
/// touched — callers must check `Entry`'s title before applying.
enum AutoTitle {
    /// The stub title recordings are created with; the only title auto-titling
    /// is allowed to replace.
    static let placeholderTitle = "New Recording"

    static let maxWords = 8

    /// Filler tokens skipped at the start of the transcript before the title
    /// is taken. Comparison is lowercase and punctuation-stripped.
    private static let leadingFillers: Set<String> = [
        "um", "uh", "uhm", "er", "ah", "hmm", "mhm", "like",
        "okay", "ok", "so", "well", "yeah", "alright", "right", "anyway",
    ]

    /// Extracts a title (≤ `maxWords` words, cleaned) from transcript text,
    /// or nil when the transcript has nothing meaningful to offer.
    static func extract(fromTranscriptText text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        // Skip leading filler words, then take up to the first sentence break.
        var start = 0
        while start < words.count, isFiller(words[start]) { start += 1 }
        guard start < words.count else { return nil }

        var titleWords: [String] = []
        for word in words[start...] {
            let cleaned = clean(word)
            if !cleaned.isEmpty {
                titleWords.append(cleaned)
            }
            if titleWords.count == maxWords || endsSentence(word) {
                break
            }
        }
        guard !titleWords.isEmpty else { return nil }

        var title = titleWords.joined(separator: " ")
        title = title.prefix(1).uppercased() + title.dropFirst()
        // A one-character "sentence" isn't a meaningful title.
        guard title.count >= 2 else { return nil }
        return title
    }

    private static func isFiller(_ word: String) -> Bool {
        leadingFillers.contains(
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        )
    }

    /// Strips wrapping punctuation but keeps in-word characters (apostrophes,
    /// hyphens) so "don't" and "check-in" survive.
    private static func clean(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func endsSentence(_ rawWord: String) -> Bool {
        guard let last = rawWord.last else { return false }
        return ".!?…".contains(last)
    }
}
