import Foundation

/// File-system mutations on a vault: create/rename folders, rename/move
/// entries. All paths are vault-relative. Frontmatter writes go through
/// `AtomicFile`; folder renames/moves are single `rename(2)`-backed moves.
struct VaultOperations: Sendable {
    let vaultRoot: URL

    private var fm: FileManager { FileManager.default }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String, inFolder parent: RelativePath) throws -> RelativePath {
        try validateName(name)
        let relPath = parent.appendingComponent(name)
        let url = vaultRoot.appendingRelativePath(relPath)
        guard !fm.fileExists(atPath: url.path) else {
            throw VaultError.alreadyExists(name)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return relPath
    }

    @discardableResult
    func renameFolder(at relPath: RelativePath, to newName: String) throws -> RelativePath {
        try validateName(newName)
        let newRelPath = relPath.parentRelativePath.appendingComponent(newName)
        guard newRelPath != relPath else { return relPath }
        let sourceURL = vaultRoot.appendingRelativePath(relPath)
        let destURL = vaultRoot.appendingRelativePath(newRelPath)
        guard fm.fileExists(atPath: sourceURL.path) else { throw VaultError.notFound(relPath) }
        guard !fm.fileExists(atPath: destURL.path) else { throw VaultError.alreadyExists(newName) }
        try fm.moveItem(at: sourceURL, to: destURL)
        return newRelPath
    }

    // MARK: - Entries

    /// Renames an entry: writes the new title into the transcript's frontmatter
    /// (creating `transcript.md` if the folder has none), renames the transcript
    /// file to `<Title>.md`, and renames the folder to
    /// `transcride-<timestamp>-<slug>`. The timestamp prefix never changes.
    @discardableResult
    func renameEntry(at relPath: RelativePath, toTitle rawTitle: String) throws -> RelativePath {
        guard let folderName = EntryFolderName(parsing: relPath.lastComponent) else {
            throw VaultError.notFound(relPath)
        }
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        guard fm.fileExists(atPath: entryURL.path) else { throw VaultError.notFound(relPath) }

        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // 1. Title into the frontmatter of whichever markdown file the entry has.
        let transcriptURL = TranscriptFile.url(inEntry: entryURL)
            ?? entryURL.appending(path: TranscriptFile.defaultName)
        var doc: FrontmatterDocument
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            doc = FrontmatterDocument.parse(text)
        } else {
            doc = FrontmatterDocument(fields: [], body: "")
            doc.created = folderName.date
        }
        doc.title = title.isEmpty ? nil : title
        try AtomicFile.write(doc.serialized(), to: transcriptURL)

        // 2. Rename the transcript file to match the title.
        let newFileName = TranscriptFile.fileName(forTitle: doc.title)
        if newFileName != transcriptURL.lastPathComponent {
            let newFileURL = entryURL.appending(path: newFileName)
            if !fm.fileExists(atPath: newFileURL.path) {
                try fm.moveItem(at: transcriptURL, to: newFileURL)
            }
        }

        // 3. Slug onto the folder name.
        let slug = Slug.make(from: title)
        let newFolderName = folderName.with(slug: slug.isEmpty ? nil : slug)
        guard newFolderName.string != folderName.string else { return relPath }

        let newRelPath = relPath.parentRelativePath.appendingComponent(newFolderName.string)
        let destURL = vaultRoot.appendingRelativePath(newRelPath)
        guard !fm.fileExists(atPath: destURL.path) else {
            throw VaultError.alreadyExists(newFolderName.string)
        }
        try fm.moveItem(at: entryURL, to: destURL)
        return newRelPath
    }

    /// Duplicates an entry (LIB-3): a fresh timestamp folder next to the
    /// source, every visible file copied, the copy titled "<Title> copy"
    /// (frontmatter, `.md` file name, and folder slug all follow). `created`
    /// becomes the duplication time so date sorting places the copy where it
    /// was made; an untitled source stays untitled.
    @discardableResult
    func duplicateEntry(at relPath: RelativePath, date: Date = .now) throws -> RelativePath {
        guard EntryFolderName(parsing: relPath.lastComponent) != nil else {
            throw VaultError.notFound(relPath)
        }
        let sourceURL = vaultRoot.appendingRelativePath(relPath)
        guard fm.fileExists(atPath: sourceURL.path) else { throw VaultError.notFound(relPath) }

        let sourceTitle = TranscriptFile.url(inEntry: sourceURL)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { FrontmatterDocument.parse($0).title }
        let copyTitle = sourceTitle.map { $0 + " copy" }

        let slug = Slug.make(from: copyTitle ?? "")
        let newRelPath = try EntryCreator(vaultRoot: vaultRoot).createEntryFolder(
            inFolder: relPath.parentRelativePath, date: date, slug: slug.isEmpty ? nil : slug
        )
        let destURL = vaultRoot.appendingRelativePath(newRelPath)
        do {
            let names = try fm.contentsOfDirectory(atPath: sourceURL.path)
                .filter {
                    !$0.hasPrefix(".") || $0 == TranscriptAlignmentState.staleFileName
                }
            for name in names {
                try fm.copyItem(
                    at: sourceURL.appending(path: name),
                    to: destURL.appending(path: name)
                )
            }
            if let transcriptURL = TranscriptFile.url(inEntry: destURL),
               let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                var doc = FrontmatterDocument.parse(text)
                if let copyTitle { doc.title = copyTitle }
                doc.created = date
                try AtomicFile.write(doc.serialized(), to: transcriptURL)
                let newFileName = TranscriptFile.fileName(forTitle: doc.title)
                if newFileName != transcriptURL.lastPathComponent {
                    let newFileURL = destURL.appending(path: newFileName)
                    if !fm.fileExists(atPath: newFileURL.path) {
                        try fm.moveItem(at: transcriptURL, to: newFileURL)
                    }
                }
            }
        } catch {
            // Failed mid-copy: remove the half-made duplicate.
            try? fm.removeItem(at: destURL)
            throw error
        }
        return newRelPath
    }

    /// Moves an entry (or folder) into another folder. Returns the new path.
    @discardableResult
    func moveItem(at relPath: RelativePath, toFolder destFolder: RelativePath) throws -> RelativePath {
        let name = relPath.lastComponent
        let newRelPath = destFolder.appendingComponent(name)
        guard newRelPath != relPath else { return relPath }

        let sourceURL = vaultRoot.appendingRelativePath(relPath)
        let destURL = vaultRoot.appendingRelativePath(newRelPath)
        guard fm.fileExists(atPath: sourceURL.path) else { throw VaultError.notFound(relPath) }
        guard !fm.fileExists(atPath: destURL.path) else { throw VaultError.alreadyExists(name) }
        // Refuse to move a folder into itself or a descendant.
        if newRelPath == relPath || newRelPath.hasPrefix(relPath + "/") {
            throw VaultError.invalidName(destFolder)
        }
        try fm.moveItem(at: sourceURL, to: destURL)
        return newRelPath
    }

    // MARK: - Validation

    private func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == name,
              !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw VaultError.invalidName(name)
        }
    }
}
