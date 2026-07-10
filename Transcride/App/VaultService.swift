import Foundation

struct EntryTranscriptContent: Sendable {
    var edited: FrontmatterDocument?
    var original: TranscriptOriginal?
}

/// Background actor owning all vault file I/O so the main thread never touches
/// the disk. Wraps the scanner (with its cache), mutation operations, and trash.
actor VaultService {
    let rootURL: URL
    private var scanner = VaultScanner()
    private let operations: VaultOperations
    private let trash: TrashStore
    private var searchIndex: VaultSearchIndex?

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.operations = VaultOperations(vaultRoot: rootURL)
        self.trash = TrashStore(vaultRoot: rootURL)
    }

    // MARK: - Reading

    func snapshot() -> VaultSnapshot {
        scanner.scan(root: rootURL)
    }

    func readTranscript(atEntryPath relPath: RelativePath) -> FrontmatterDocument? {
        guard let url = TranscriptFile.url(inEntry: rootURL.appendingRelativePath(relPath)),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FrontmatterDocument.parse(text)
    }

    func readTranscriptContent(atEntryPath relPath: RelativePath) -> EntryTranscriptContent {
        let entryURL = rootURL.appendingRelativePath(relPath)
        let edited: FrontmatterDocument?
        if let url = TranscriptFile.url(inEntry: entryURL),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            edited = FrontmatterDocument.parse(text)
        } else {
            edited = nil
        }
        return EntryTranscriptContent(
            edited: edited,
            original: TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        )
    }

    // MARK: - Search cache

    /// Opens and fully reconciles the rebuildable cache. AppModel starts this
    /// in an unstructured task after the vault becomes usable, so a large
    /// first rebuild never holds up window navigation on the main actor.
    func initializeSearchIndex() throws {
        let databaseURL = VaultSearchIndex.defaultDatabaseURL(forVault: rootURL)
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        let index = try VaultSearchIndex(vaultRoot: rootURL, databaseURL: databaseURL)
        // VaultSearchIndex builds a brand-new cache during initialization.
        // An existing cache is rebuilt on every open so missed events from a
        // prior process can never leave stale search results.
        if existed { try index.rebuild() }
        searchIndex = index
    }

    func search(_ query: String, fuzzy: Bool, limit: Int = 150) throws -> [SearchHit] {
        guard let searchIndex else {
            throw SearchIndexError.sqlite("The vault is still being indexed")
        }
        do {
            return try searchIndex.search(query, fuzzy: fuzzy, limit: limit)
        } catch {
            _ = try searchIndex.recoverIfNeeded()
            return try searchIndex.search(query, fuzzy: fuzzy, limit: limit)
        }
    }

    /// File-event paths remain coalesced by FSEvents. The index reconciler
    /// removes vanished records and re-reads only entries intersecting those
    /// paths, including every child of a renamed folder.
    func synchronizeSearchIndex(changedAbsolutePaths: [String]) {
        guard let searchIndex else { return }
        do {
            try searchIndex.synchronize(changedAbsolutePaths: changedAbsolutePaths)
        } catch {
            do {
                _ = try searchIndex.recoverIfNeeded()
                try searchIndex.synchronize(changedAbsolutePaths: changedAbsolutePaths)
            } catch {
                DebugLog.append("search index sync FAILED: \(error)")
            }
        }
    }

    func synchronizeSearchEntry(at relativePath: RelativePath) {
        synchronizeSearchIndex(relativePaths: [relativePath])
    }

    private func synchronizeSearchIndex(relativePaths: [RelativePath]) {
        synchronizeSearchIndex(changedAbsolutePaths: relativePaths.map {
            rootURL.appendingRelativePath($0).path
        })
    }

    /// Re-reads frontmatter at save time, replaces only the body, and writes
    /// atomically. This keeps metadata and unknown YAML fields intact even
    /// when another in-app operation updated them after the editor opened.
    func saveTranscriptBody(
        _ body: String,
        markHandEdited: Bool,
        clearHandEdited: Bool = false,
        atEntryPath relPath: RelativePath
    ) throws -> FrontmatterDocument {
        let entryURL = rootURL.appendingRelativePath(relPath)
        guard let transcriptURL = TranscriptFile.url(inEntry: entryURL) else {
            throw VaultError.notFound("Transcript for \(relPath)")
        }
        var editable = try TranscriptEditDocument.load(from: transcriptURL)
        editable.replaceBody(body, markHandEdited: markHandEdited)
        if markHandEdited { editable.markHandEdited() }
        if clearHandEdited { editable.clearHandEdited() }
        try editable.save(to: transcriptURL)
        synchronizeSearchIndex(relativePaths: [relPath])
        return editable.document
    }

    /// Loads the entry's `waveform.json`, generating (and caching) it from the
    /// audio file when missing or unreadable — so deleting the file in Finder
    /// simply causes a rebuild on next open (PLY-3).
    func waveform(forEntryAt relPath: RelativePath, audioFileName: String) async throws -> WaveformData {
        let entryURL = rootURL.appendingRelativePath(relPath)
        let cacheURL = WaveformData.url(inEntry: entryURL)
        if let cached = WaveformData.load(from: cacheURL) { return cached }
        let waveform = try await WaveformGenerator.generate(
            fromAudioAt: entryURL.appending(path: audioFileName)
        )
        try waveform.write(to: cacheURL)
        return waveform
    }

    // MARK: - Entry creation (M2: recording & import)

    /// Creates the (still empty) entry folder a new recording streams into.
    func createEntryFolder(inFolder parent: RelativePath, date: Date) throws -> RelativePath {
        let path = try EntryCreator(vaultRoot: rootURL)
            .createEntryFolder(inFolder: parent, date: date)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    /// Removes an entry folder that never got any content (recording failed
    /// to start). Refuses non-empty folders.
    func removeEmptyEntryFolder(at relPath: RelativePath) throws {
        guard EntryFolderName(parsing: relPath.lastComponent) != nil else { return }
        let url = rootURL.appendingRelativePath(relPath)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.isEmpty else { return }
        try FileManager.default.removeItem(at: url)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    /// Imports one audio file: probes it (per-file error for corrupt/misnamed
    /// files), then copies it into a new entry with a stub transcript.
    func importAudioFile(from sourceURL: URL, toFolder parent: RelativePath) async throws -> RelativePath {
        let duration = try await AudioImportFormat.probeDuration(of: sourceURL)
        let path = try EntryCreator(vaultRoot: rootURL)
            .importFile(from: sourceURL, toFolder: parent, date: .now, duration: duration)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    // MARK: - Folder / entry mutations

    func createFolder(named name: String, inFolder parent: RelativePath) throws -> RelativePath {
        try operations.createFolder(named: name, inFolder: parent)
    }

    func renameFolder(at relPath: RelativePath, to newName: String) throws -> RelativePath {
        let newPath = try operations.renameFolder(at: relPath, to: newName)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    func renameEntry(at relPath: RelativePath, toTitle title: String) throws -> RelativePath {
        let newPath = try operations.renameEntry(at: relPath, toTitle: title)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    func moveItem(at relPath: RelativePath, toFolder destFolder: RelativePath) throws -> RelativePath {
        let newPath = try operations.moveItem(at: relPath, toFolder: destFolder)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    // MARK: - Transcription (M3)

    /// Applies one finished transcription (correction backstop, archive,
    /// `transcript.original.json`, `transcript.md`, auto-title) on this actor
    /// so the writes serialize with every other vault mutation.
    func applyTranscription(
        segments: [TranscriptOriginal.Segment],
        toEntryAt relPath: RelativePath,
        engine: TranscriptOriginal.EngineMetadata,
        engineFrontmatterID: String,
        vocabularyTerms: [String]
    ) throws -> TranscriptionApplier.Outcome {
        let outcome = try TranscriptionApplier(vaultRoot: rootURL).apply(
            segments: segments,
            toEntryAt: relPath,
            engine: engine,
            engineFrontmatterID: engineFrontmatterID,
            vocabularyTerms: vocabularyTerms,
            date: .now
        )
        synchronizeSearchIndex(relativePaths: [relPath, outcome.entryRelativePath])
        return outcome
    }

    // MARK: - Audio lifecycle (AUD-1)

    /// Byte size of the entry's audio file, for the Delete Audio warning.
    func audioFileByteSize(atEntryPath relPath: RelativePath) -> Int64? {
        guard let name = audioFileName(atEntryPath: relPath) else { return nil }
        let url = rootURL.appendingRelativePath(relPath).appending(path: name)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Moves the entry's audio (and waveform cache) to Recently Deleted and
    /// flags the frontmatter; the transcript stays behind as a plain note.
    func deleteAudio(atEntryPath relPath: RelativePath) throws {
        try trash.trashEntryAudio(atEntryPath: relPath)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    /// Trim (AUD-3): exports the kept range, stages the pre-trim audio in
    /// Recently Deleted, swaps the trimmed file in, and updates the
    /// frontmatter duration. The caller enqueues the retranscription.
    func trimAudio(atEntryPath relPath: RelativePath, selection: TrimSelection) async throws -> TrimApplier.Outcome {
        guard let audioName = audioFileName(atEntryPath: relPath) else {
            throw VaultError.notFound(relPath.appendingComponent("audio"))
        }
        let audioURL = rootURL.appendingRelativePath(relPath).appending(path: audioName)
        let exported = try await AudioTrimExport.export(from: audioURL, keeping: selection)
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        // The exporter trims on packet boundaries; probe the real duration
        // rather than trusting the requested range.
        let newDuration = (try? await AudioImportFormat.probeDuration(of: exported.url))
            ?? selection.length
        let outcome = try TrimApplier(vaultRoot: rootURL).apply(
            trimmedFileAt: exported.url,
            fileName: exported.fileName,
            newDuration: newDuration,
            toEntryAt: relPath
        )
        synchronizeSearchIndex(relativePaths: [relPath])
        return outcome
    }

    /// The entry's audio file name (canonical `audio.*` preferred), nil when
    /// the folder has no audio.
    func audioFileName(atEntryPath relPath: RelativePath) -> String? {
        let url = rootURL.appendingRelativePath(relPath)
        let fileNames = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        return VaultScanner.audioFile(in: fileNames)
    }

    /// Speaker rename (TRN-6): stores machine-id → display-name mappings in
    /// the entry's frontmatter (`speaker_s1: "Alice"`; nil/empty removes) and
    /// regenerates the markdown labels for a never-hand-edited entry. The
    /// JSON keeps the stable machine ids untouched.
    func saveSpeakerNames(
        _ names: [String: String?], atEntryPath relPath: RelativePath
    ) throws {
        let entryURL = rootURL.appendingRelativePath(relPath)
        guard let transcriptURL = TranscriptFile.url(inEntry: entryURL),
              let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw VaultError.notFound("Transcript for \(relPath)")
        }
        var doc = FrontmatterDocument.parse(text)
        let original = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        // Decide regenerability against the *current* names before applying
        // the rename, so a previously regenerated labeled body still matches.
        let regenerable = !TranscriptEditDocument.isForked(doc, comparedTo: original)
        for (id, name) in names {
            SpeakerNames.set(name: name, forID: id, in: &doc)
        }
        if regenerable, let original {
            doc.body = "\n" + TranscriptMarkdown.body(
                from: original, speakerNames: SpeakerNames.names(in: doc)
            ) + "\n"
        }
        try AtomicFile.write(doc.serialized(), to: transcriptURL)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    func vocabularyTerms() -> [String] {
        VocabularyFile.load(fromVault: rootURL)
    }

    func saveVocabularyTerms(_ terms: [String]) throws {
        try VocabularyFile.save(terms, toVault: rootURL)
    }

    // MARK: - Trash

    func trashItem(atRelativePath relPath: RelativePath) throws {
        try trash.trashItem(atRelativePath: relPath)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    func trashItems() throws -> [TrashItem] {
        try trash.items()
    }

    func restore(_ item: TrashItem) throws -> RelativePath {
        let path = try trash.restore(item)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    func deletePermanently(_ item: TrashItem) throws {
        try trash.deletePermanently(item)
    }

    func purgeTrash() throws -> Int {
        try trash.purge()
    }
}
