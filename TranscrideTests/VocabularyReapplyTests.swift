import Foundation
import Testing

@Suite("Vocabulary re-apply (VOC-4)")
struct VocabularyReapplyTests {
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

    // MARK: - Preview

    @Test func previewFindsCalibrationCorrectionWithoutMutating() {
        let source = transcript(["I", "said", "like", "Erikeet,", "maybe", "so"])
        let proposals = VocabularyReapply.preview(
            terms: ["Airakeet"], protectedBy: ["Airakeet"], transcript: source
        )
        #expect(proposals.count == 1)
        let proposal = try! #require(proposals.first)
        #expect(proposal.correctedText == "Airakeet,")
        #expect(proposal.originalText == "Erikeet,")
        #expect(proposal.start == 1.5)
        // Snippet shows the correction in context with its neighbors.
        #expect(proposal.snippet.contains("Airakeet,"))
        #expect(proposal.snippet.contains("said"))
        // Dry run: the source transcript is untouched.
        #expect(source.segments[0].words[3].text == "Erikeet,")
        #expect(source.allWords.allSatisfy { $0.correctedFrom == nil })
    }

    @Test func previewStaysConservativeOnCalibrationNegatives() {
        // The deliberately-never-corrected cases from the M3 contract must
        // stay silent in re-apply too.
        let negatives = transcript(["ocean", "waves", "or", "Mythish", "and", "transcribe", "it"])
        #expect(VocabularyReapply.preview(
            terms: ["Ashan", "Mitesh", "Transcride"],
            protectedBy: ["Ashan", "Mitesh", "Transcride"],
            transcript: negatives
        ).isEmpty)
    }

    @Test func previewSkipsAlreadyCorrectedWords() {
        var t = transcript(["like", "Erikeet,", "maybe"])
        VocabularyCorrector.apply(terms: ["Airakeet"], to: &t)
        #expect(t.segments[0].words[1].correctedFrom == "Erikeet,")
        // A second pass over the corrected transcript proposes nothing.
        #expect(VocabularyReapply.preview(
            terms: ["Airakeet"], protectedBy: ["Airakeet"], transcript: t
        ).isEmpty)
    }

    @Test func wholeVocabularyProtectsExactMatchesInRestrictedPass() {
        // "Divine" exactly matches another vocabulary term; a pass restricted
        // to the new term "Devine" must keep the transcription-time
        // protection and leave it alone.
        let t = transcript(["truly", "Divine", "weather"])
        #expect(VocabularyReapply.preview(
            terms: ["Devine"], protectedBy: ["Divine", "Devine"], transcript: t
        ).isEmpty)
        // Without the protection the word would be eligible — guard the guard.
        #expect(!VocabularyReapply.preview(
            terms: ["Devine"], protectedBy: ["Devine"], transcript: t
        ).isEmpty)
    }

    // MARK: - Apply (file level)

    private func makeEntry(
        in vaultRoot: URL, folderName: String, texts: [String], handEdited: Bool
    ) throws -> RelativePath {
        let entryURL = vaultRoot.appending(path: folderName)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let original = transcript(texts)
        try original.write(to: TranscriptOriginal.url(inEntry: entryURL))
        var doc = FrontmatterDocument(fields: [], body: "")
        doc.body = handEdited
            ? "\nMy own words entirely.\n"
            : "\n" + TranscriptMarkdown.body(from: original) + "\n"
        if handEdited { doc.handEdited = true }
        try AtomicFile.write(doc.serialized(), to: entryURL.appending(path: "transcript.md"))
        return folderName
    }

    @Test func applyCorrectsJSONRegeneratesMarkdownAndIsIdempotent() throws {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appending(path: "reapply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let path = try makeEntry(
            in: vaultRoot, folderName: "transcride-2026-07-01T10-00-00",
            texts: ["like", "Erikeet,", "maybe"], handEdited: false
        )

        let applier = VocabularyReapplyApplier(vaultRoot: vaultRoot)
        let summary = try applier.apply(
            terms: ["Airakeet"], protectedBy: ["Airakeet"], toEntriesAt: [path]
        )
        #expect(summary.correctionCount == 1)
        #expect(summary.changedEntryPaths == [path])
        #expect(summary.handEditedKeptCount == 0)

        let entryURL = vaultRoot.appending(path: path)
        let corrected = try #require(
            TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        )
        #expect(corrected.segments[0].words[1].text == "Airakeet,")
        #expect(corrected.segments[0].words[1].correctedFrom == "Erikeet,")
        // No archive is made for a correction pass.
        let files = try FileManager.default.contentsOfDirectory(atPath: entryURL.path)
        #expect(files.filter { $0.hasPrefix("transcript.original") }.count == 1)
        // Markdown followed the corrected original.
        let md = try String(
            contentsOf: entryURL.appending(path: "transcript.md"), encoding: .utf8
        )
        #expect(md.contains("Airakeet,"))
        #expect(!md.contains("Erikeet,"))

        // Second pass finds nothing to do.
        let again = try applier.apply(
            terms: ["Airakeet"], protectedBy: ["Airakeet"], toEntriesAt: [path]
        )
        #expect(again == VocabularyReapplyApplier.Summary())
    }

    @Test func applyLeavesHandEditedMarkdownWhileCorrectingJSON() throws {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appending(path: "reapply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let path = try makeEntry(
            in: vaultRoot, folderName: "transcride-2026-07-01T11-00-00",
            texts: ["like", "Erikeet,", "maybe"], handEdited: true
        )

        let summary = try VocabularyReapplyApplier(vaultRoot: vaultRoot).apply(
            terms: ["Airakeet"], protectedBy: ["Airakeet"], toEntriesAt: [path]
        )
        #expect(summary.correctionCount == 1)
        #expect(summary.handEditedKeptCount == 1)

        let entryURL = vaultRoot.appending(path: path)
        let corrected = try #require(
            TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        )
        #expect(corrected.segments[0].words[1].text == "Airakeet,")
        let md = try String(
            contentsOf: entryURL.appending(path: "transcript.md"), encoding: .utf8
        )
        #expect(md.contains("My own words entirely."))
        #expect(!md.contains("Airakeet"))
    }
}
