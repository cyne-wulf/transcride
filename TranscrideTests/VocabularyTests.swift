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
}
