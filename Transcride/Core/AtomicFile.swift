import Foundation

/// Write-temp-then-rename file writes. Every file write in the app goes through
/// here so a crash mid-write can never leave a corrupt or partial file.
///
/// The rename alone only orders *metadata*: the temp file's bytes may still sit
/// in the page cache when the rename is recorded, so a power loss could publish
/// a zero-length destination. Each write therefore flushes the temp file before
/// renaming it — see `Durability`.
enum AtomicFile {
    /// How hard a write is pushed toward the disk before it reports success.
    enum Durability: Sendable {
        /// `fsync` the temp file before the rename. Cheap, and enough to
        /// guarantee that a crash can only ever leave the previous, complete
        /// version of the file behind. The right choice for rebuildable
        /// artifacts (waveform caches, the search index, queues, manifests).
        case standard
        /// `F_FULLFSYNC` the temp file (a real device-cache barrier, unlike
        /// `fsync` on APFS) and sync the containing directory after the
        /// rename. Reserved for irreplaceable user data — the transcript
        /// markdown — where the extra milliseconds are worth it.
        case full
    }

    static func write(_ data: Data, to url: URL, durability: Durability = .standard) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        do {
            try data.write(to: tempURL, options: [])
            try flush(tempURL, durability: durability)
            let result = tempURL.withUnsafeFileSystemRepresentation { temp in
                url.withUnsafeFileSystemRepresentation { dest in
                    rename(temp!, dest!)
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Atomic rename failed: \(String(cString: strerror(errno)))",
                    NSFilePathErrorKey: url.path,
                ])
            }
            if durability == .full { syncDirectory(directory) }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    static func write(_ string: String, to url: URL, durability: Durability = .standard) throws {
        try write(Data(string.utf8), to: url, durability: durability)
    }

    /// Pushes the freshly written temp file out of the page cache. A write that
    /// cannot be flushed must not report success, so failures propagate.
    private static func flush(_ url: URL, durability: Durability) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        switch durability {
        case .standard:
            try handle.synchronize()
        case .full:
            // Not every file system implements the barrier; where it is
            // unsupported a plain fsync is the strongest guarantee available.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                try handle.synchronize()
            }
        }
    }

    /// Best effort: the rename has already succeeded, so the file is complete
    /// either way — this only makes the *name* durable sooner.
    private static func syncDirectory(_ url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}

/// Reads and writes the frontmatter of an entry's markdown transcript.
///
/// Use this instead of the `try? String(contentsOf:)`-else-build-a-stub
/// pattern, which destroyed real transcripts: a file that exists but cannot be
/// read (permissions, non-UTF-8 bytes, an undownloaded cloud placeholder) was
/// indistinguishable from a file that is not there, so a metadata toggle would
/// overwrite a full note with a two-line stub.
///
/// The distinction this type enforces:
/// - **absent** (the entry folder holds no markdown file) is a legitimate
///   reason to create one — that is what `createIfMissing` controls;
/// - **unreadable** never is: `read`/`update` throw
///   `VaultError.unreadableTranscript` and write nothing.
///
/// Writes go out with `AtomicFile.Durability.full`, skip when the mutation
/// changed nothing, and refuse to change the markdown body (see `update`).
enum EntryFrontmatter {
    /// What an entry's markdown transcript currently is.
    enum Slot: Sendable {
        /// The entry's transcript file and its parsed contents.
        case existing(url: URL, document: FrontmatterDocument)
        /// The entry has no markdown file at all; `url` is where a
        /// `transcript.md` would be created.
        case missing(url: URL)

        /// The transcript file, real or prospective.
        var url: URL {
            switch self {
            case .existing(let url, _), .missing(let url): return url
            }
        }

        /// The parsed document, or nil when the entry has no transcript.
        var document: FrontmatterDocument? {
            switch self {
            case .existing(_, let document): return document
            case .missing: return nil
            }
        }
    }

    struct UpdateResult: Sendable {
        /// The transcript file the update targeted. When nothing was written
        /// because the entry has no transcript and `createIfMissing` was
        /// false, this is where one *would* have been created.
        var url: URL
        /// The document now on disk — or, when nothing was written, the
        /// document that is already there (or the unwritten stub).
        var document: FrontmatterDocument
        /// Whether bytes were actually written.
        var wrote: Bool
    }

    /// Loads the entry's transcript.
    ///
    /// Throws `VaultError.notFound` when the entry folder is gone and
    /// `VaultError.unreadableTranscript` when the folder cannot be listed or
    /// its markdown file cannot be decoded — callers must never respond to
    /// those by fabricating a replacement.
    static func read(inEntry entryURL: URL) throws -> Slot {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: entryURL.path)
        } catch {
            // A folder we cannot see into may already hold a transcript, so
            // "no transcript" is not a conclusion we are allowed to draw.
            throw fm.fileExists(atPath: entryURL.path)
                ? VaultError.unreadableTranscript(entryURL.lastPathComponent)
                : VaultError.notFound(entryURL.lastPathComponent)
        }
        guard let name = TranscriptFile.find(in: names) else {
            return .missing(url: entryURL.appending(path: TranscriptFile.defaultName))
        }
        let url = entryURL.appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw VaultError.unreadableTranscript(name)
        }
        return .existing(url: url, document: FrontmatterDocument.parse(text))
    }

    /// Applies a **metadata-only** change to the entry's frontmatter and writes
    /// it atomically.
    ///
    /// - `createIfMissing: true` (the default) writes a fresh stub — seeded
    ///   with `created` from the entry folder's timestamp — when the entry has
    ///   no markdown file yet. Pass `false` for updates that are pointless
    ///   without an existing note (a duration refresh, say); the mutation is
    ///   then evaluated but nothing is created.
    /// - Nothing is written when the mutation leaves the document unchanged,
    ///   so a no-op toggle does not rewrite the file or bump its modification
    ///   date (which drives the "Recently Edited" sort).
    /// - `mutate` must not touch `document.body`. A mutation that does throws
    ///   `VaultError.metadataWriteWouldReplaceBody` and writes nothing, so a
    ///   bug in a caller cannot silently drop a hand-edited note. Use
    ///   `TranscriptEditDocument` for genuine body edits.
    @discardableResult
    static func update(
        inEntry entryURL: URL,
        createIfMissing: Bool = true,
        mutate: (inout FrontmatterDocument) -> Void
    ) throws -> UpdateResult {
        let slot = try read(inEntry: entryURL)
        let baseline: FrontmatterDocument
        switch slot {
        case .existing(_, let document):
            baseline = document
        case .missing:
            var stub = FrontmatterDocument(fields: [], body: "")
            stub.created = EntryFolderName(parsing: entryURL.lastPathComponent)?.date
            baseline = stub
        }

        var document = baseline
        mutate(&document)
        guard document != baseline else {
            return UpdateResult(url: slot.url, document: baseline, wrote: false)
        }
        guard document.body == baseline.body else {
            throw VaultError.metadataWriteWouldReplaceBody(slot.url.lastPathComponent)
        }
        if case .missing = slot, !createIfMissing {
            return UpdateResult(url: slot.url, document: baseline, wrote: false)
        }
        try AtomicFile.write(document.serialized(), to: slot.url, durability: .full)
        return UpdateResult(url: slot.url, document: document, wrote: true)
    }
}
