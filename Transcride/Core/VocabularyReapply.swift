import Foundation

/// VOC-4: re-running the correction backstop over existing transcripts after
/// the vocabulary gains terms. Preview is a pure dry run against one loaded
/// transcript; `VocabularyReapplyApplier` does the file work for the entries
/// the user approved. Both restrict matching to the given terms while the
/// whole vocabulary keeps protecting exact matches (`protectedBy`), and both
/// inherit every conservatism rule from `VocabularyCorrector` unchanged —
/// including never re-correcting a word that already carries
/// `corrected_from`, which is what makes a second pass find nothing.
enum VocabularyReapply {
    struct ProposedCorrection: Equatable, Sendable {
        /// The vocabulary form that would be written (trailing punctuation kept).
        var correctedText: String
        /// The transcript's current text — what `corrected_from` will preserve.
        var originalText: String
        var start: Double
        var end: Double
        /// The correction in context: a few surrounding words with the
        /// corrected form in place.
        var snippet: String
    }

    struct EntryPreview: Equatable, Sendable {
        var entryRelativePath: RelativePath
        var corrections: [ProposedCorrection]
    }

    /// Words of context shown on each side of a correction in the snippet.
    private static let snippetContext = 4

    /// Dry run: the corrections `terms` would make to `transcript`, without
    /// mutating anything. Already-corrected words are skipped by the corrector
    /// itself, so entries that took these corrections at transcription time
    /// (or in an earlier re-apply) produce an empty result.
    static func preview(
        terms: [String],
        protectedBy allTerms: [String],
        transcript: TranscriptOriginal
    ) -> [ProposedCorrection] {
        var corrected = transcript
        let count = VocabularyCorrector.apply(
            terms: terms, protectedBy: allTerms, to: &corrected
        )
        guard count > 0 else { return [] }

        // The corrector never touches a word that already has corrected_from,
        // so any corrected word not present verbatim in the source is new.
        let existing = Set(transcript.allWords.compactMap(Fingerprint.init))
        var proposals: [ProposedCorrection] = []
        for segment in corrected.segments {
            for (index, word) in segment.words.enumerated() {
                guard let print = Fingerprint(word), !existing.contains(print) else { continue }
                proposals.append(ProposedCorrection(
                    correctedText: word.text,
                    originalText: print.correctedFrom,
                    start: word.start,
                    end: word.end,
                    snippet: snippet(around: index, in: segment.words)
                ))
            }
        }
        return proposals
    }

    private struct Fingerprint: Hashable {
        var text: String
        var start: Double
        var end: Double
        var correctedFrom: String

        init?(_ word: TranscriptOriginal.Word) {
            guard let correctedFrom = word.correctedFrom else { return nil }
            self.text = word.text
            self.start = word.start
            self.end = word.end
            self.correctedFrom = correctedFrom
        }
    }

    private static func snippet(around index: Int, in words: [TranscriptOriginal.Word]) -> String {
        let lower = max(0, index - snippetContext)
        let upper = min(words.count, index + snippetContext + 1)
        var text = words[lower ..< upper].map(\.text).joined(separator: " ")
        if lower > 0 { text = "… " + text }
        if upper < words.count { text += " …" }
        return text
    }
}

/// The apply half of VOC-4: rewrites `transcript.original.json` for the
/// approved entries and regenerates `transcript.md` under the exact rules the
/// transcription-time applier uses — hand-edited bodies are never touched
/// (their JSON is still corrected), speaker renames carry into regenerated
/// labels, and no archive is made (a correction pass refines the same
/// original, just as transcription-time corrections precede the first write).
struct VocabularyReapplyApplier: Sendable {
    let vaultRoot: URL

    struct Summary: Equatable, Sendable {
        var correctionCount = 0
        /// Entries whose JSON changed (search-index resync targets).
        var changedEntryPaths: [RelativePath] = []
        /// Of those, entries whose markdown was hand-edited and kept as-is.
        var handEditedKeptCount = 0
    }

    func apply(
        terms: [String],
        protectedBy allTerms: [String],
        toEntriesAt paths: [RelativePath]
    ) throws -> Summary {
        var summary = Summary()
        for relPath in paths {
            let entryURL = vaultRoot.appendingRelativePath(relPath)
            let originalURL = TranscriptOriginal.url(inEntry: entryURL)
            guard let previous = TranscriptOriginal.load(from: originalURL) else { continue }

            // Recompute against the file's current state rather than trusting
            // a possibly stale preview — never-re-correct makes this safe.
            var corrected = previous
            let count = VocabularyCorrector.apply(
                terms: terms, protectedBy: allTerms, to: &corrected
            )
            guard count > 0 else { continue }
            try corrected.write(to: originalURL)
            summary.correctionCount += count
            summary.changedEntryPaths.append(relPath)

            // Markdown follows only where it is still machine-generated,
            // compared against the pre-correction original (same rule as the
            // transcription applier's previousOriginal).
            guard let transcriptURL = TranscriptFile.url(inEntry: entryURL),
                  let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                continue
            }
            var doc = FrontmatterDocument.parse(text)
            if TranscriptEditDocument.isForked(doc, comparedTo: previous) {
                summary.handEditedKeptCount += 1
            } else {
                doc.body = "\n" + TranscriptMarkdown.body(
                    from: corrected, speakerNames: SpeakerNames.names(in: doc)
                ) + "\n"
                try AtomicFile.write(doc.serialized(), to: transcriptURL)
            }
        }
        return summary
    }
}
