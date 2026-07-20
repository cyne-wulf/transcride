import Foundation
import Testing

@Suite("Transcription applier")
struct TranscriptionApplierTests {
    // MARK: - Fixtures

    private func makeVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "applier-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates an entry folder with a transcript.md carrying frontmatter,
    /// mirroring what recording/import produce. Returns the relative path.
    private func makeEntry(
        in vault: URL,
        title: String?,
        body: String = "\n"
    ) throws -> RelativePath {
        let name = "transcride-2026-07-09T10-00-00"
        let entryURL = vault.appending(path: name)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        var doc = FrontmatterDocument(fields: [], body: body)
        doc.created = EntryFolderName(parsing: name)?.date
        doc.title = title
        try doc.serialized().write(
            to: entryURL.appending(path: TranscriptFile.defaultName),
            atomically: true, encoding: .utf8
        )
        return name
    }

    private func engineMeta() -> TranscriptOriginal.EngineMetadata {
        .init(
            engine: "parakeet",
            model: "parakeet-tdt-0.6b-v3",
            options: [:],
            created: "2026-07-09T12:00:00Z",
            appVersion: "1.0 (1)"
        )
    }

    /// One segment whose words start at `startingAt`, 0.4 s apart.
    private func segment(_ texts: [String], startingAt: Double = 0) -> TranscriptOriginal.Segment {
        let words = texts.enumerated().map { index, text in
            let start = startingAt + Double(index) * 0.4
            return TranscriptOriginal.Word(text: text, start: start, end: start + 0.3)
        }
        return .init(start: words.first!.start, end: words.last!.end, speaker: nil, words: words)
    }

    private func transcriptText(inEntry entryURL: URL) throws -> String {
        let url = try #require(TranscriptFile.url(inEntry: entryURL))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tests

    @Test func firstApplyWritesJSONRegeneratesMarkdownAndAutoTitles() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: AutoTitle.placeholderTitle)

        let applier = TranscriptionApplier(vaultRoot: vault)
        let outcome = try applier.apply(
            segments: [segment(["Project", "kickoff", "plan"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // Auto-title renamed the entry; the outcome points at the new path.
        #expect(outcome.appliedTitle == "Project kickoff plan")
        #expect(outcome.entryRelativePath != relPath)
        #expect(outcome.entryRelativePath.hasPrefix("transcride-2026-07-09T10-00-00"))
        #expect(outcome.archivedOriginalName == nil)
        #expect(!outcome.markdownLeftAlone)

        let entryURL = vault.appendingRelativePath(outcome.entryRelativePath)
        #expect(FileManager.default.fileExists(atPath: entryURL.path))

        // JSON written and round-trips.
        let loaded = try #require(TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL)))
        #expect(loaded.schema == TranscriptOriginal.currentSchema)
        #expect(loaded.engine.engine == "parakeet")
        #expect(loaded.allWords.map(\.text) == ["Project", "kickoff", "plan"])

        // Markdown regenerated: body + engine field, file renamed for the title.
        let text = try transcriptText(inEntry: entryURL)
        let doc = FrontmatterDocument.parse(text)
        #expect(doc.body.contains("Project kickoff plan"))
        #expect(doc.engine == "parakeet-tdt-v3")
        #expect(doc.title == "Project kickoff plan")
        #expect(TranscriptFile.url(inEntry: entryURL)?.lastPathComponent == "Project kickoff plan.md")
    }

    @Test func userTitleIsNeverReplaced() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Team Standup")

        let outcome = try TranscriptionApplier(vaultRoot: vault).apply(
            segments: [segment(["Totally", "different", "words"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: .now
        )

        #expect(outcome.appliedTitle == nil)
        #expect(outcome.entryRelativePath == relPath)
        let doc = FrontmatterDocument.parse(
            try transcriptText(inEntry: vault.appendingRelativePath(relPath))
        )
        #expect(doc.title == "Team Standup")
        #expect(doc.engine == "parakeet-tdt-v3") // stub body was still regenerated
    }

    @Test func retranscribeArchivesAndRegeneratesUneditedMarkdown() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Budget Sync")
        let applier = TranscriptionApplier(vaultRoot: vault)

        _ = try applier.apply(
            segments: [segment(["First", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let outcome = try applier.apply(
            segments: [segment(["Second", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "whisperkit-small",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let entryURL = vault.appendingRelativePath(relPath)
        // Prior original archived under the dated name, new one in place.
        let archivedName = try #require(outcome.archivedOriginalName)
        #expect(archivedName.hasPrefix("transcript.original.2"))
        #expect(archivedName.hasSuffix(".json"))
        let archived = try #require(TranscriptOriginal.load(from: entryURL.appending(path: archivedName)))
        #expect(archived.allWords.map(\.text) == ["First", "engine", "pass"])
        let current = try #require(TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL)))
        #expect(current.allWords.map(\.text) == ["Second", "engine", "pass"])

        // The generated (never-edited) markdown followed the new original.
        #expect(!outcome.markdownLeftAlone)
        let doc = FrontmatterDocument.parse(try transcriptText(inEntry: entryURL))
        #expect(doc.body.contains("Second engine pass"))
        #expect(doc.engine == "whisperkit-small")
    }

    @Test func retranscribeNeverTouchesHandEditedMarkdown() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Budget Sync")
        let applier = TranscriptionApplier(vaultRoot: vault)

        _ = try applier.apply(
            segments: [segment(["First", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // The user rewrites the note (M4 will do this in-app; simulate externally).
        let entryURL = vault.appendingRelativePath(relPath)
        let transcriptURL = try #require(TranscriptFile.url(inEntry: entryURL))
        var doc = FrontmatterDocument.parse(try String(contentsOf: transcriptURL, encoding: .utf8))
        doc.body = "\nMy own hand-written summary.\n"
        try doc.serialized().write(to: transcriptURL, atomically: true, encoding: .utf8)
        let editedText = try String(contentsOf: transcriptURL, encoding: .utf8)
        try ExtensionTranscriptState(
            knownTranscriptDuration: 10,
            combinedAudioDuration: 12,
            normalizedToM4A: false
        ).write(to: entryURL)

        let outcome = try applier.apply(
            segments: [segment(["Second", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "whisperkit-small",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_100)
        )

        // Markdown byte-identical; original still replaced + archived.
        #expect(outcome.markdownLeftAlone)
        #expect(try String(contentsOf: transcriptURL, encoding: .utf8) == editedText)
        #expect(ExtensionTranscriptState.load(from: entryURL) == nil)
        #expect(outcome.archivedOriginalName != nil)
        let current = try #require(TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL)))
        #expect(current.allWords.map(\.text) == ["Second", "engine", "pass"])
    }

    @Test func explicitHandEditedFlagPreventsRegenerationEvenWhenBodyStillMatches() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Budget Sync")
        let applier = TranscriptionApplier(vaultRoot: vault)

        _ = try applier.apply(
            segments: [segment(["First", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let entryURL = vault.appendingRelativePath(relPath)
        let transcriptURL = try #require(TranscriptFile.url(inEntry: entryURL))
        var doc = FrontmatterDocument.parse(try String(contentsOf: transcriptURL, encoding: .utf8))
        doc.handEdited = true
        try AtomicFile.write(doc.serialized(), to: transcriptURL)
        let flaggedText = try String(contentsOf: transcriptURL, encoding: .utf8)

        let outcome = try applier.apply(
            segments: [segment(["Second", "engine", "pass"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "whisperkit-small",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_100)
        )

        #expect(outcome.markdownLeftAlone)
        #expect(try String(contentsOf: transcriptURL, encoding: .utf8) == flaggedText)
    }

    @Test func retranscriptionClearsDisabledSpeakerPreferenceWithoutChangingHandEditedBody() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Interview", body: "My edited note.\n")
        let entryURL = vault.appendingRelativePath(relPath)
        let transcriptURL = try #require(TranscriptFile.url(inEntry: entryURL))
        var doc = FrontmatterDocument.parse(
            try String(contentsOf: transcriptURL, encoding: .utf8)
        )
        doc.handEdited = true
        doc.speakerDetectionEnabled = false
        try AtomicFile.write(doc.serialized(), to: transcriptURL)

        let outcome = try TranscriptionApplier(vaultRoot: vault).apply(
            segments: [segment(["Fresh", "engine", "words"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: [],
            date: Date(timeIntervalSince1970: 1_800_000_200)
        )

        let updated = FrontmatterDocument.parse(
            try String(contentsOf: transcriptURL, encoding: .utf8)
        )
        #expect(outcome.markdownLeftAlone)
        #expect(updated.body == "My edited note.\n")
        #expect(updated.handEdited)
        #expect(updated.speakerDetectionEnabled)
        #expect(updated.rawValue(for: "speaker_detection") == nil)
    }

    @Test func vocabularyBackstopRunsBeforeWriting() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let relPath = try makeEntry(in: vault, title: "Vocab Check")

        let outcome = try TranscriptionApplier(vaultRoot: vault).apply(
            segments: [segment(["The", "transcried", "app"])],
            toEntryAt: relPath,
            engine: engineMeta(),
            engineFrontmatterID: "parakeet-tdt-v3",
            vocabularyTerms: ["Transcride"],
            date: .now
        )

        #expect(outcome.correctionCount == 1)
        let entryURL = vault.appendingRelativePath(relPath)
        let loaded = try #require(TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL)))
        let corrected = try #require(loaded.allWords.first(where: { $0.text == "Transcride" }))
        #expect(corrected.correctedFrom == "transcried")
        let doc = FrontmatterDocument.parse(try transcriptText(inEntry: entryURL))
        #expect(doc.body.contains("Transcride"))
    }

    @Test func missingEntryThrowsNotFound() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        #expect(throws: VaultError.self) {
            try TranscriptionApplier(vaultRoot: vault).apply(
                segments: [segment(["Hello"])],
                toEntryAt: "transcride-2026-07-09T10-00-00",
                engine: engineMeta(),
                engineFrontmatterID: "parakeet-tdt-v3",
                vocabularyTerms: [],
                date: .now
            )
        }
    }
}
