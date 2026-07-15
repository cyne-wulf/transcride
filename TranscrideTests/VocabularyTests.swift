import Foundation
import Testing

@Suite("Vocabulary file")
struct VocabularyFileTests {
    @Test func parsesOneTermPerLineSkippingBlanksAndComments() {
        let text = "Transcride\n\n# names\nAshan Devine\n  FluidAudio  \n"
        #expect(VocabularyFile.parse(text) == ["Transcride", "Ashan Devine", "FluidAudio"])
    }

    @Test func serializeRoundTrips() {
        let terms = ["Transcride", "Ashan"]
        #expect(VocabularyFile.parse(VocabularyFile.serialize(terms)) == terms)
        #expect(VocabularyFile.serialize([]) == "")
    }

    @Test func importedListsAcceptMarkdownPlainTextAndNumbering() {
        let text = """
        - Transcride
        * FluidAudio
        + Parakeet
        1. WhisperKit
        2) Apple Speech
        Plain term
        # ignored note
        """
        #expect(VocabularyFile.parseImportedTerms(text) == [
            "Transcride", "FluidAudio", "Parakeet", "WhisperKit", "Apple Speech", "Plain term",
        ])
    }

    @Test func markdownDictionaryRoundTripsThroughImport() {
        let terms = ["Transcride", "FluidAudio", "Apple Speech"]
        #expect(VocabularyFile.markdownList(terms) == """
        - Transcride
        - FluidAudio
        - Apple Speech

        """)
        #expect(VocabularyFile.parseImportedTerms(VocabularyFile.markdownList(terms)) == terms)
    }
}

@Suite("Vocabulary bias prompt")
struct VocabularyBiasPromptTests {
    @Test func wrapsTermsAsContextInsteadOfRawTranscriptText() {
        #expect(VocabularyBiasPrompt.text(for: ["Transcride"]) ==
            "Important vocabulary for the following recording includes Transcride.")
        #expect(VocabularyBiasPrompt.text(for: ["Ashan Devine", "Mitesh Parikh"]) ==
            "Important vocabulary for the following recording includes Ashan Devine and Mitesh Parikh.")
        #expect(VocabularyBiasPrompt.text(for: ["Transcride", "Mitesh Parikh", "Ashan Devine"]) ==
            "Important vocabulary for the following recording includes Transcride, Mitesh Parikh, and Ashan Devine.")
    }

    @Test func ignoresEmptyAndDuplicateTerms() {
        #expect(VocabularyBiasPrompt.text(for: [" ", "Transcride", "Transcride", " Ashan "]) ==
            "Important vocabulary for the following recording includes Transcride and Ashan.")
        #expect(VocabularyBiasPrompt.text(for: []) == nil)
    }
}

@Suite("Vocabulary correction backstop")
struct VocabularyCorrectorTests {
    private let vocabulary = ["Transcride", "Ashan", "FluidAudio", "Parakeet"]

    private func transcript(_ texts: [String]) -> TranscriptOriginal {
        let words = texts.enumerated().map { index, text in
            TranscriptOriginal.Word(
                text: text, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4
            )
        }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: 0, end: Double(texts.count) * 0.5, words: words)]
        )
    }

    @Test func correctsCloseMissesAndRecordsOriginal() {
        var t = transcript(["I", "asked", "Ashen", "about", "it."])
        let count = VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(count == 1)
        let corrected = t.segments[0].words[2]
        #expect(corrected.text == "Ashan")
        #expect(corrected.correctedFrom == "Ashen")
    }

    @Test func preservesTrailingPunctuation() {
        var t = transcript(["Tell", "Ashen,", "please."])
        VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(t.segments[0].words[1].text == "Ashan,")
    }

    @Test func mergesSplitCompoundWords() {
        var t = transcript(["We", "use", "fluid", "audio", "here."])
        let count = VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(count == 1)
        let words = t.segments[0].words
        #expect(words.map(\.text) == ["We", "use", "FluidAudio", "here."])
        let merged = words[2]
        #expect(merged.correctedFrom == "fluid audio")
        #expect(merged.start == 1.0) // "fluid"'s start
        #expect(merged.end == 1.9) // "audio"'s end
    }

    @Test func leavesNearMissRealWordsAlone() {
        // Phonetically different look-alikes must survive (VOC-3: false
        // corrections are worse than misses).
        var t = transcript([
            "Please", "transcribe", "this", "and", "the", "transcribed", "one",
            "with", "a", "parakeet's", "ashen", "feather", "and", "fluid", "motion.",
        ])
        let before = t
        VocabularyCorrector.apply(terms: ["Transcride"], to: &t)
        #expect(t == before)

        // "ashen" *is* corrected when "Ashan" is a term (sounds identical),
        // but "fluid" alone and "transcribe" never are.
        var t2 = transcript(["transcribe", "the", "fluid", "sample"])
        VocabularyCorrector.apply(terms: vocabulary, to: &t2)
        #expect(t2.segments[0].words.map(\.text) == ["transcribe", "the", "fluid", "sample"])
    }

    @Test func correctsPhoneticallEqualMisspelling() {
        // "transcried" sounds like "Transcride" (same consonant skeleton).
        var t = transcript(["Open", "transcried", "now."])
        VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(t.segments[0].words[1].text == "Transcride")
    }

    @Test func caseOnlyRewriteOnlyForInternalCapitalTerms() {
        // "fluidaudio" → canonical camel case: safe, the term is distinctive.
        var t = transcript(["I", "like", "fluidaudio", "a", "lot."])
        VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(t.segments[0].words[2].text == "FluidAudio")

        // "ashan" mid-sentence is left as typed — plain-word case is not our
        // business (sentence caps, style).
        var t2 = transcript(["ashan", "said", "hi."])
        VocabularyCorrector.apply(terms: vocabulary, to: &t2)
        #expect(t2.segments[0].words[0].text == "ashan")
    }

    @Test func exactVocabularyWordsAreNeverTouched() {
        var t = transcript(["Transcride", "uses", "Parakeet", "models."])
        let count = VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(count == 0)
        #expect(t.segments[0].words.allSatisfy { $0.correctedFrom == nil })
    }

    @Test func shortTermsRequireExactMatch() {
        // 4-letter terms never fuzzy-match ("meat" must not become "Mead").
        var t = transcript(["some", "meat", "here"])
        VocabularyCorrector.apply(terms: ["Mead"], to: &t)
        #expect(t.segments[0].words[1].text == "meat")
    }

    @Test func multiWordPhraseTermMatches() {
        var t = transcript(["say", "hi", "to", "ashan", "devine", "today."])
        VocabularyCorrector.apply(terms: ["Ashan Devine"], to: &t)
        let words = t.segments[0].words
        #expect(words.map(\.text) == ["say", "hi", "to", "Ashan Devine", "today."])
        #expect(words[3].correctedFrom == "ashan devine")
    }

    @Test func editDistanceIsDamerau() {
        #expect(VocabularyCorrector.editDistance("transcride", "transcried", limit: 2) == 1)
        #expect(VocabularyCorrector.editDistance("abc", "abc", limit: 2) == 0)
        #expect(VocabularyCorrector.editDistance("abcdef", "xyzdef", limit: 2) == 3)
    }

    @Test func vowelOnsetMissesAreCorrected() {
        // Real Parakeet output from verification: "Oshan" for "Ashan" — one
        // substitution, identical consonant skeleton. The leading vowel must
        // not block the phonetic gate.
        #expect(VocabularyCorrector.phoneticKey("oshan") == VocabularyCorrector.phoneticKey("ashan"))
        var t = transcript(["like", "Oshan", "Divine,", "and"])
        let count = VocabularyCorrector.apply(terms: vocabulary, to: &t)
        #expect(count == 1)
        #expect(t.segments[0].words[1].text == "Ashan")
        #expect(t.segments[0].words[1].correctedFrom == "Oshan")
    }

    @Test func realWorldEngineMissesStayConservative() {
        // Also from verification runs: "ocean" is 3 edits from a 5-letter
        // term, "Mythish" 3 from a 6-letter one — both too far to correct
        // safely; real words never get rewritten into names.
        var t = transcript(["ocean", "waves", "or", "Mythish", "and", "meet", "this"])
        let before = t
        VocabularyCorrector.apply(terms: ["Ashan", "Mitesh"], to: &t)
        #expect(t == before)
    }

    @Test func vowelRespellingsOfLongTermsAreCorrected() {
        // Real Parakeet output: "Erikeet," for "Airakeet" — 3 edits, but the
        // consonant skeleton is identical, so every edit is in the vowels.
        var t = transcript(["like", "Erikeet,", "maybe"])
        VocabularyCorrector.apply(terms: ["Airakeet"], to: &t)
        #expect(t.segments[0].words[1].text == "Airakeet,")
        #expect(t.segments[0].words[1].correctedFrom == "Erikeet,")
    }

    @Test func distanceThreeNeverAppliesToJoinedWindows() {
        // "flat audio" shares FluidAudio's consonant skeleton at 3 edits;
        // multi-word joins stay capped at 2 so real phrases survive.
        var t = transcript(["a", "flat", "audio", "profile"])
        let before = t
        VocabularyCorrector.apply(terms: ["FluidAudio"], to: &t)
        #expect(t == before)
    }

    @Test func phraseWithVowelOnsetMissIsCorrected() {
        // Real Parakeet output: "Oshan Divine," with both "Ashan" and
        // "Ashan Devine" in the vocabulary — the longer phrase must win
        // (previously the raw 2-char prefix gate stranded "Divine,").
        var t = transcript(["like", "Oshan", "Divine,", "and"])
        let count = VocabularyCorrector.apply(terms: ["Ashan", "Ashan Devine"], to: &t)
        #expect(count == 1)
        let words = t.segments[0].words
        #expect(words.map(\.text) == ["like", "Ashan Devine,", "and"])
        #expect(words[1].correctedFrom == "Oshan Divine,")
    }

    @Test func realWorldTrailingPunctuationMiss() {
        // Apple Speech emitted "Parik," for "Parikh," — corrected with the
        // comma preserved.
        var t = transcript(["Mitesh", "Parik,", "and"])
        VocabularyCorrector.apply(terms: ["Parikh"], to: &t)
        #expect(t.segments[0].words[1].text == "Parikh,")
        #expect(t.segments[0].words[1].correctedFrom == "Parik,")
    }
}
