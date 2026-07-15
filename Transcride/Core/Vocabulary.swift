import Foundation

/// `<vault>/vocabulary.txt` — one term per line (words or short phrases the
/// user wants transcribed correctly). Blank lines and `#` comments ignored.
enum VocabularyFile {
    static let fileName = "vocabulary.txt"

    static func url(inVault vaultURL: URL) -> URL {
        vaultURL.appending(path: fileName)
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func serialize(_ terms: [String]) -> String {
        terms.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }

    /// Parses a clipboard-friendly vocabulary list. In addition to the vault's
    /// plain one-term-per-line format, accept common Markdown bullets and
    /// numbered-list markers so a copied dictionary can be pasted back in.
    static func parseImportedTerms(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine in
                var term = rawLine.trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty, !term.hasPrefix("#") else { return nil }

                let bulletPrefixes = ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "]
                if let prefix = bulletPrefixes.first(where: { term.hasPrefix($0) }) {
                    term.removeFirst(prefix.count)
                } else if let marker = term.range(
                    of: #"^\d+[.)]\s+"#,
                    options: .regularExpression
                ) {
                    term.removeSubrange(marker)
                }

                term = term.trimmingCharacters(in: .whitespaces)
                return term.isEmpty ? nil : term
            }
    }

    static func markdownList(_ terms: [String]) -> String {
        terms.map { "- \($0)" }.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }

    static func load(fromVault vaultURL: URL) -> [String] {
        guard let text = try? String(contentsOf: url(inVault: vaultURL), encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    static func save(_ terms: [String], toVault vaultURL: URL) throws {
        try AtomicFile.write(serialize(terms), to: url(inVault: vaultURL))
    }
}

/// Builds the natural-language context given to Whisper Small for vocabulary
/// biasing. A bare comma-separated dictionary looks like preceding transcript
/// text to Whisper and can be echoed, shuffled, or repeated on short clips.
/// Framing the same terms as context keeps the spellings available without
/// inviting the decoder to continue the list.
enum VocabularyBiasPrompt {
    static func text(for rawTerms: [String]) -> String? {
        var seen: Set<String> = []
        let terms = rawTerms.compactMap { rawTerm -> String? in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
        }
        guard !terms.isEmpty else { return nil }

        let list: String
        switch terms.count {
        case 1:
            list = terms[0]
        case 2:
            list = "\(terms[0]) and \(terms[1])"
        default:
            list = terms.dropLast().joined(separator: ", ") + ", and " + terms.last!
        }
        return "Important vocabulary for the following recording includes \(list)."
    }
}

/// The correction backstop (VOC-3): after any engine transcribes, transcript
/// words are fuzzy-matched against vocabulary terms and rewritten in place,
/// with the engine's original preserved in `corrected_from`.
///
/// Deliberately conservative — a false correction is worse than a miss:
/// - fuzzy matching needs ≥ 5 significant characters and edit distance ≤ 1
///   (≤ 2 for terms of 8+ characters, ≤ 3 only for single words against such
///   terms — where the equal phonetic key confines the edits to the vowel
///   pattern, e.g. "Erikeet" → "Airakeet"), an anchored first character
///   (equal, or both vowels) once the distance exceeds 1, AND an equal
///   phonetic key, so look-alikes that sound different ("transcribe" vs
///   "Transcride") are left alone;
/// - case-only rewrites happen only for terms with internal capitals
///   ("FluidAudio"), never plain names, so sentence capitalization survives;
/// - a window that exactly matches a *different* vocabulary term is never
///   corrected.
///
/// Multi-word handling: adjacent transcript words are joined (up to 4) and
/// compared against each term with spaces removed, so "fluid audio" can
/// become "FluidAudio". A merged correction keeps the first word's start and
/// the last word's end, so word→audio mapping stays valid for M4.
enum VocabularyCorrector {
    struct Term {
        let canonical: String
        /// Lowercased letters/digits only (spaces, apostrophes, hyphens dropped).
        let key: String
        let phonetic: String
        let wordCount: Int
        let hasInternalCapitals: Bool

        init?(_ raw: String) {
            let canonical = raw.trimmingCharacters(in: .whitespaces)
            let key = VocabularyCorrector.normalize(canonical)
            guard !canonical.isEmpty, key.count >= 2 else { return nil }
            self.canonical = canonical
            self.key = key
            self.phonetic = VocabularyCorrector.phoneticKey(key)
            self.wordCount = canonical.split(whereSeparator: \.isWhitespace).count
            self.hasInternalCapitals =
                canonical.dropFirst().contains(where: \.isUppercase)
                || canonical.contains(where: \.isNumber)
        }
    }

    /// Longest run of transcript words considered for one term.
    private static let maxWindow = 4
    /// Minimum key length before fuzzy (non-exact) matching is allowed.
    private static let minFuzzyLength = 5

    /// Applies the backstop in place. Returns the number of corrections made.
    ///
    /// `protectedBy` widens the never-correct set without widening the match
    /// set: a re-apply pass restricted to newly added terms (VOC-4) passes the
    /// whole vocabulary here, so a window that exactly matches some *other*
    /// term keeps its transcription-time protection.
    @discardableResult
    static func apply(
        terms rawTerms: [String],
        protectedBy allRawTerms: [String]? = nil,
        to transcript: inout TranscriptOriginal
    ) -> Int {
        let terms = rawTerms.compactMap(Term.init)
        guard !terms.isEmpty else { return 0 }
        let protectedTerms = (allRawTerms ?? rawTerms).compactMap(Term.init)
        let exactKeys = Set(terms.map(\.key)).union(protectedTerms.map(\.key))
        var corrections = 0

        for segmentIndex in transcript.segments.indices {
            var words = transcript.segments[segmentIndex].words
            var index = 0
            while index < words.count {
                if let match = bestMatch(
                    at: index, in: words, terms: terms, exactKeys: exactKeys
                ) {
                    let replaced = words[index ..< index + match.windowSize]
                    let originalText = replaced.map(\.text).joined(separator: " ")
                    let trailing = trailingPunctuation(of: replaced.last!.text)
                    words[index] = TranscriptOriginal.Word(
                        text: match.term.canonical + trailing,
                        start: replaced.first!.start,
                        end: replaced.last!.end,
                        correctedFrom: originalText
                    )
                    words.removeSubrange((index + 1) ..< (index + match.windowSize))
                    corrections += 1
                }
                index += 1
            }
            transcript.segments[segmentIndex].words = words
        }
        return corrections
    }

    // MARK: - Matching

    private struct Match {
        let term: Term
        let windowSize: Int
    }

    /// Best correction starting at `index`, preferring longer windows so
    /// "fluid audio" beats a single-word match on "fluid".
    private static func bestMatch(
        at index: Int, in words: [TranscriptOriginal.Word],
        terms: [Term], exactKeys: Set<String>
    ) -> Match? {
        // Never re-correct output of an earlier pass.
        guard words[index].correctedFrom == nil else { return nil }

        for windowSize in stride(from: maxWindow, through: 1, by: -1) {
            guard index + windowSize <= words.count else { continue }
            let window = words[index ..< index + windowSize]
            guard windowSize == 1 || window.allSatisfy({ $0.correctedFrom == nil }) else { continue }
            let windowKey = window.map { normalize($0.text) }.joined()
            guard !windowKey.isEmpty else { continue }

            for term in terms {
                // A multi-word window must not out-span the term wildly:
                // only consider joins when the term could plausibly cover them.
                if windowSize > 1, windowKey.count > term.key.count + 2 { continue }

                if windowKey == term.key {
                    // Exact (case/spacing-insensitive) hit. Correct when the
                    // written form actually differs and the change is safe.
                    let writtenForm = window.map(\.text).joined(separator: " ")
                    let strippedForm = stripPunctuation(writtenForm)
                    if strippedForm == term.canonical { return nil }
                    if windowSize > 1 || term.hasInternalCapitals || term.wordCount > 1 {
                        return Match(term: term, windowSize: windowSize)
                    }
                    return nil // case-only difference on a plain word — leave it
                }

                // Fuzzy: conservative thresholds + phonetic gate.
                guard term.key.count >= minFuzzyLength,
                      abs(windowKey.count - term.key.count) <= 2,
                      !exactKeys.contains(windowKey)
                else { continue }
                // Distance 3 is only for single words against long terms: the
                // phonetic gate then confines all edits to the vowel pattern.
                let maxDistance = term.key.count >= 8 ? (windowSize == 1 ? 3 : 2) : 1
                let distance = editDistance(windowKey, term.key, limit: maxDistance)
                guard distance >= 1, distance <= maxDistance else { continue }
                if distance >= 2, windowKey.first != term.key.first,
                   !(isVowel(windowKey.first) && isVowel(term.key.first)) { continue }
                guard phoneticKey(windowKey) == phoneticKey(term.key) else { continue }
                return Match(term: term, windowSize: windowSize)
            }
        }
        return nil
    }

    // MARK: - Normalization

    /// Lowercased letters and digits only.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func stripPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isVowel(_ char: Character?) -> Bool {
        guard let char else { return false }
        return "aeiou".contains(char)
    }

    private static func trailingPunctuation(of text: String) -> String {
        var result = ""
        for char in text.reversed() {
            guard char.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains),
                  char != "'" , char != "-"
            else { break }
            result = String(char) + result
        }
        return result
    }

    /// Soundex-style key over a normalized string: consonants mapped to sound
    /// classes, vowels/h/w/y dropped (the leading character keeps a neutral
    /// "0" so "Oshan"/"Ashan" agree), repeats collapsed. No length cap — long
    /// words must agree along their whole consonant skeleton.
    static func phoneticKey(_ normalized: String) -> String {
        guard !normalized.isEmpty else { return "" }
        var key = ""
        var lastCode: Character?
        for (offset, char) in normalized.enumerated() {
            let code: Character?
            switch char {
            case "b", "f", "p", "v": code = "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": code = "2"
            case "d", "t": code = "3"
            case "l": code = "4"
            case "m", "n": code = "5"
            case "r": code = "6"
            case "a", "e", "i", "o", "u", "h", "w", "y": code = offset == 0 ? "0" : nil
            default: code = char // digits, non-ASCII: keep as-is
            }
            if let code {
                if code != lastCode { key.append(code) }
                lastCode = code
            } else {
                lastCode = nil
            }
        }
        return key
    }

    /// Damerau–Levenshtein (optimal string alignment) distance, early-exiting
    /// once the distance must exceed `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > limit { return limit + 1 }
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var previous2 = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0 ... t.count)
        var current = [Int](repeating: 0, count: t.count + 1)

        for i in 1 ... s.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1 ... t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var value = Swift.min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    value = Swift.min(value, previous2[j - 2] + 1) // transposition
                }
                current[j] = value
                rowMin = Swift.min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[t.count]
    }
}
