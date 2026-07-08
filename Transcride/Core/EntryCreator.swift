import Foundation

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
        try AtomicFile.write(doc.serialized(), to: entryURL.appending(path: TranscriptFile.defaultName))
    }

    /// Imports one audio file: creates an entry folder (slug from the file
    /// name), copies the source in unchanged (original untouched, format and
    /// extension preserved), and writes a stub transcript titled after the
    /// source file. `duration` must be probed by the caller
    /// (`AudioImportFormat.probeDuration`) *before* calling, so corrupt files
    /// never leave a half-made entry.
    func importFile(
        from sourceURL: URL, toFolder parent: RelativePath, date: Date, duration: Double
    ) throws -> RelativePath {
        let title = AudioImportFormat.title(forSourceName: sourceURL.lastPathComponent)
        let slug = Slug.make(from: title)
        let relPath = try createEntryFolder(
            inFolder: parent, date: date, slug: slug.isEmpty ? nil : slug
        )
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        do {
            let audioName = AudioImportFormat.importedFileName(
                forSourceName: sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: entryURL.appending(path: audioName))

            var doc = FrontmatterDocument(fields: [], body: "")
            doc.title = title
            doc.created = date
            doc.duration = duration
            doc.source = "imported"
            let transcriptName = TranscriptFile.fileName(forTitle: title)
            try AtomicFile.write(doc.serialized(), to: entryURL.appending(path: transcriptName))
        } catch {
            // Failed mid-import: remove the half-made entry so the vault stays clean.
            try? FileManager.default.removeItem(at: entryURL)
            throw error
        }
        return relPath
    }
}
