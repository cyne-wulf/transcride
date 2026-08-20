import Foundation

/// Builds a new entry out of sight and moves it into the library in one step.
///
/// `catch { removeItem }` cleans up after a *thrown* error but cannot run when
/// the process is killed, so a half-copied import or duplicate used to survive
/// as a permanent phantom entry (the scanner lists any `transcride-*` folder,
/// however empty). Work therefore happens inside `<vault>/.staging/<uuid>/`,
/// which is hidden from the scanner, the search index, and recovery scans, and
/// becomes an entry only via a single atomic rename at the end.
struct EntryStaging: Sendable {
    static let directoryName = ".staging"
    /// How long an abandoned staging folder is left alone before a later
    /// import/duplicate sweeps it — long enough never to touch a live one.
    static let staleAge: TimeInterval = 3600

    let vaultRoot: URL
    let url: URL

    private var fm: FileManager { FileManager.default }

    /// Opens a staging folder, first clearing out corpses left by earlier runs.
    init(vaultRoot: URL) throws {
        self.vaultRoot = vaultRoot
        let container = vaultRoot.appending(path: Self.directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        Self.sweep(inVault: vaultRoot, olderThan: Self.staleAge)
        self.url = container.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Moves the finished folder into `parent` under a free entry name.
    /// Same volume, so this is one `rename(2)`: the entry is either absent or
    /// complete, never in between.
    func commit(
        inFolder parent: RelativePath, date: Date, slug: String? = nil
    ) throws -> RelativePath {
        var candidate = date
        for _ in 0..<100 {
            let name = EntryFolderName(date: candidate, slug: slug).string
            let relPath = parent.appendingComponent(name)
            let destination = vaultRoot.appendingRelativePath(relPath)
            if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: url, to: destination)
                return relPath
            }
            candidate = candidate.addingTimeInterval(1)
        }
        throw VaultError.alreadyExists(EntryFolderName(date: date, slug: slug).string)
    }

    /// Throws away unfinished work. Safe to call after `commit`.
    func discard() {
        try? fm.removeItem(at: url)
    }

    /// Removes staging folders older than `age`. Called before staging a new
    /// entry, and at launch, so nothing accumulates after a hard termination.
    static func sweep(inVault vaultRoot: URL, olderThan age: TimeInterval = EntryStaging.staleAge) {
        let fm = FileManager.default
        let container = vaultRoot.appending(path: directoryName, directoryHint: .isDirectory)
        guard let contents = try? fm.contentsOfDirectory(
            at: container, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// Creates new entry folders for recordings and imports. Folder names come
/// from `EntryFolderName`, stub transcripts are written with
/// `FrontmatterDocument` + `AtomicFile` per the entry-folder contract.
struct EntryCreator: Sendable {
    let vaultRoot: URL

    static let recordingDefaultTitle = "New Recording"

    /// Creates a new, empty entry folder in `parent` named with `date`'s
    /// timestamp (+ optional slug). Timestamps have one-second resolution, so
    /// on a collision (e.g. batch imports in the same second) the timestamp is
    /// advanced by one second until a free name is found.
    ///
    /// Used by recording, which needs the real folder up front to stream into.
    /// Anything that can build an entry before revealing it should stage it
    /// with `EntryStaging` instead.
    func createEntryFolder(
        inFolder parent: RelativePath, date: Date, slug: String? = nil
    ) throws -> RelativePath {
        let fm = FileManager.default
        var candidate = date
        for _ in 0..<100 {
            let name = EntryFolderName(date: candidate, slug: slug).string
            let relPath = parent.appendingComponent(name)
            let url = vaultRoot.appendingRelativePath(relPath)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return relPath
            }
            candidate = candidate.addingTimeInterval(1)
        }
        throw VaultError.alreadyExists(EntryFolderName(date: date, slug: slug).string)
    }

    /// Stub transcript for a finished recording: `transcript.md` (the entry is
    /// untitled in the file-naming sense), frontmatter title "New Recording",
    /// empty body. M3 replaces the *call site* of this with transcription
    /// queueing — see `TranscriptionSeam`.
    static func writeRecordingStub(entryURL: URL, created: Date, duration: Double) throws {
        var doc = FrontmatterDocument(fields: [], body: "")
        doc.title = Self.recordingDefaultTitle
        doc.created = created
        doc.duration = duration
        doc.source = "recorded"
        try AtomicFile.write(
            doc.serialized(),
            to: entryURL.appending(path: TranscriptFile.defaultName),
            durability: .full
        )
    }

    /// Imports one audio file: builds the entry in a staging folder (the
    /// source copied in unchanged — original untouched, format and extension
    /// preserved — plus a stub transcript titled after the source file), then
    /// moves it into `parent`. `duration` must be probed by the caller
    /// (`AudioImportFormat.probeDuration`) *before* calling, so corrupt files
    /// never reach the vault at all.
    func importFile(
        from sourceURL: URL, toFolder parent: RelativePath, date: Date, duration: Double
    ) throws -> RelativePath {
        let title = AudioImportFormat.title(forSourceName: sourceURL.lastPathComponent)
        let slug = Slug.make(from: title)
        let staging = try EntryStaging(vaultRoot: vaultRoot)
        do {
            let audioName = AudioImportFormat.importedFileName(
                forSourceName: sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: staging.url.appending(path: audioName))

            var doc = FrontmatterDocument(fields: [], body: "")
            doc.title = title
            doc.created = date
            doc.duration = duration
            doc.source = "imported"
            let transcriptName = TranscriptFile.fileName(forTitle: title)
            try AtomicFile.write(
                doc.serialized(),
                to: staging.url.appending(path: transcriptName),
                durability: .full
            )
            return try staging.commit(
                inFolder: parent, date: date, slug: slug.isEmpty ? nil : slug
            )
        } catch {
            // Nothing visible was ever created; drop the staged work.
            staging.discard()
            throw error
        }
    }
}
