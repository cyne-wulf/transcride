import Foundation

/// Applies one finished transcription to an entry folder: runs the vocabulary
/// backstop, archives a prior original, writes `transcript.original.json`,
/// regenerates `transcript.md` (unless hand-edited), and auto-titles
/// placeholder entries (TRN-4/5/7 + VOC-3). Pure file work — callable from
/// any actor that owns vault I/O.
struct TranscriptionApplier: Sendable {
    let vaultRoot: URL

    struct Outcome: Sendable {
        /// The entry's path after an auto-title rename (unchanged otherwise).
        var entryRelativePath: RelativePath
        /// The title applied by auto-titling, nil when none happened.
        var appliedTitle: String?
        /// Archive file name when a prior original was superseded.
        var archivedOriginalName: String?
        /// True when `transcript.md` was hand-edited and therefore left
        /// untouched even though the original changed underneath it (TRN-5).
        var markdownLeftAlone: Bool
        /// Vocabulary-backstop corrections applied.
        var correctionCount: Int
    }

    func apply(
        segments: [TranscriptOriginal.Segment],
        toEntryAt relPath: RelativePath,
        engine: TranscriptOriginal.EngineMetadata,
        engineFrontmatterID: String,
        vocabularyTerms: [String],
        date: Date
    ) throws -> Outcome {
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw VaultError.notFound(relPath)
        }

        // 1. Correction backstop — the raw engine words stay in corrected_from.
        var transcript = TranscriptOriginal(engine: engine, segments: segments)
        let correctionCount = VocabularyCorrector.apply(terms: vocabularyTerms, to: &transcript)

        // 2. Archive a prior original (retranscribe), then write the new one.
        let previousOriginal = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        let archivedURL = try TranscriptOriginal.archiveExisting(inEntry: entryURL, date: date)
        try transcript.write(to: TranscriptOriginal.url(inEntry: entryURL))

        // 3. Regenerate transcript.md — but never over a hand edit. A body is
        // safe to replace when it's the empty stub or exactly what the
        // previous original generated (whitespace-insensitive).
        let transcriptURL = TranscriptFile.url(inEntry: entryURL)
            ?? entryURL.appending(path: TranscriptFile.defaultName)
        var doc: FrontmatterDocument
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            doc = FrontmatterDocument.parse(text)
        } else {
            doc = FrontmatterDocument(fields: [], body: "")
            doc.created = EntryFolderName(parsing: relPath.lastComponent)?.date
        }

        let regenerable = !TranscriptEditDocument.isForked(doc, comparedTo: previousOriginal)
        var markdownLeftAlone = false
        if regenerable {
            // Speaker renames stored in the frontmatter carry over into the
            // regenerated labels; the JSON keeps the machine ids.
            doc.body = "\n" + TranscriptMarkdown.body(
                from: transcript, speakerNames: SpeakerNames.names(in: doc)
            ) + "\n"
            doc.engine = engineFrontmatterID
            try AtomicFile.write(doc.serialized(), to: transcriptURL)
        } else {
            markdownLeftAlone = true
        }
        // The authoritative transcript now matches the combined audio. This
        // hidden derived marker may be removed without touching hand-edited
        // Markdown bytes.
        try? FileManager.default.removeItem(at: ExtensionTranscriptState.url(inEntry: entryURL))

        // 4. Auto-title (TRN-7): only the recording placeholder is replaced;
        // user-set titles (and import filenames) are never overwritten.
        var outcome = Outcome(
            entryRelativePath: relPath,
            appliedTitle: nil,
            archivedOriginalName: archivedURL?.lastPathComponent,
            markdownLeftAlone: markdownLeftAlone,
            correctionCount: correctionCount
        )
        if doc.title == AutoTitle.placeholderTitle,
           let title = AutoTitle.extract(
               fromTranscriptText: TranscriptMarkdown.body(from: transcript, speakerLabels: false)
           ) {
            do {
                let newPath = try VaultOperations(vaultRoot: vaultRoot)
                    .renameEntry(at: relPath, toTitle: title)
                outcome.entryRelativePath = newPath
                outcome.appliedTitle = title
            } catch {
                // A name collision must not fail the transcription itself.
            }
        }
        return outcome
    }
}
