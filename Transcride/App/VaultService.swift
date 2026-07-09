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

    /// Re-reads frontmatter at save time, replaces only the body, and writes
    /// atomically. This keeps metadata and unknown YAML fields intact even
    /// when another in-app operation updated them after the editor opened.
    func saveTranscriptBody(
        _ body: String,
        markHandEdited: Bool,
        atEntryPath relPath: RelativePath
    ) throws -> FrontmatterDocument {
        let entryURL = rootURL.appendingRelativePath(relPath)
        guard let transcriptURL = TranscriptFile.url(inEntry: entryURL) else {
            throw VaultError.notFound("Transcript for \(relPath)")
        }
        var editable = try TranscriptEditDocument.load(from: transcriptURL)
        editable.replaceBody(body)
        // If the user edited and then undid back to the starting text before
        // the debounce fired, the real edit still forked this layer.
        if markHandEdited { editable.markHandEdited() }
        try editable.save(to: transcriptURL)
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
        try EntryCreator(vaultRoot: rootURL).createEntryFolder(inFolder: parent, date: date)
    }

    /// Removes an entry folder that never got any content (recording failed
    /// to start). Refuses non-empty folders.
    func removeEmptyEntryFolder(at relPath: RelativePath) throws {
        guard EntryFolderName(parsing: relPath.lastComponent) != nil else { return }
        let url = rootURL.appendingRelativePath(relPath)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.isEmpty else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Imports one audio file: probes it (per-file error for corrupt/misnamed
    /// files), then copies it into a new entry with a stub transcript.
    func importAudioFile(from sourceURL: URL, toFolder parent: RelativePath) async throws -> RelativePath {
        let duration = try await AudioImportFormat.probeDuration(of: sourceURL)
        return try EntryCreator(vaultRoot: rootURL)
            .importFile(from: sourceURL, toFolder: parent, date: .now, duration: duration)
    }

    // MARK: - Folder / entry mutations

    func createFolder(named name: String, inFolder parent: RelativePath) throws -> RelativePath {
        try operations.createFolder(named: name, inFolder: parent)
    }

    func renameFolder(at relPath: RelativePath, to newName: String) throws -> RelativePath {
        try operations.renameFolder(at: relPath, to: newName)
    }

    func renameEntry(at relPath: RelativePath, toTitle title: String) throws -> RelativePath {
        try operations.renameEntry(at: relPath, toTitle: title)
    }

    func moveItem(at relPath: RelativePath, toFolder destFolder: RelativePath) throws -> RelativePath {
        try operations.moveItem(at: relPath, toFolder: destFolder)
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
        try TranscriptionApplier(vaultRoot: rootURL).apply(
            segments: segments,
            toEntryAt: relPath,
            engine: engine,
            engineFrontmatterID: engineFrontmatterID,
            vocabularyTerms: vocabularyTerms,
            date: .now
        )
    }

    /// The entry's audio file name (canonical `audio.*` preferred), nil when
    /// the folder has no audio.
    func audioFileName(atEntryPath relPath: RelativePath) -> String? {
        let url = rootURL.appendingRelativePath(relPath)
        let fileNames = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        return VaultScanner.audioFile(in: fileNames)
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
    }

    func trashItems() throws -> [TrashItem] {
        try trash.items()
    }

    func restore(_ item: TrashItem) throws -> RelativePath {
        try trash.restore(item)
    }

    func deletePermanently(_ item: TrashItem) throws {
        try trash.deletePermanently(item)
    }

    func purgeTrash() throws -> Int {
        try trash.purge()
    }
}
