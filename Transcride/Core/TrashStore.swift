import Foundation

/// What a trashed item was before deletion. Sidecars written by M1 carry no
/// kind and decode as `.item`.
enum TrashItemKind: String, Codable, Sendable {
    /// A whole entry, folder, or file moved into the trash.
    case item
    /// An entry's audio (plus its waveform cache), removed via Delete Audio…
    /// (AUD-1); `originalPath` is the entry folder the audio came from.
    case entryAudio
}

/// Sidecar written next to each trashed item, recording where it came from.
struct TrashInfo: Codable, Equatable, Sendable {
    /// Vault-relative path the item lived at before deletion (including its
    /// name) — for `.entryAudio`, the entry folder the audio belongs to.
    var originalPath: String
    var deletedAt: Date
    /// nil in sidecars from before audio-only deletion existed (= `.item`).
    var kind: TrashItemKind?
}

/// One item sitting in `<vault>/.trash/`.
struct TrashItem: Identifiable, Hashable, Sendable {
    /// The item's folder/file name inside `.trash` (may carry a collision suffix).
    var trashedName: String
    var originalPath: String
    var deletedAt: Date
    var isEntry: Bool
    var kind: TrashItemKind = .item

    var id: String { trashedName }

    var displayName: String {
        if kind == .entryAudio {
            return "Audio — " + Self.entryDisplayName(fromFolderName: originalPath.lastComponent)
        }
        if isEntry, let slugName = Self.entrySlugName(fromFolderName: trashedName) {
            return slugName
        }
        return originalPath.lastComponent
    }

    private static func entryDisplayName(fromFolderName name: String) -> String {
        entrySlugName(fromFolderName: name) ?? name
    }

    private static func entrySlugName(fromFolderName name: String) -> String? {
        guard let parsed = EntryFolderName(parsing: name), let slug = parsed.slug else { return nil }
        return slug.split(separator: "-").joined(separator: " ").capitalized
    }
}

/// Manages `<vault>/.trash/`: move-in, listing, restore, permanent delete, and
/// the 30-day purge. Each trashed item gets a `<name>.trashinfo.json` sidecar.
struct TrashStore: Sendable {
    static let directoryName = ".trash"
    static let sidecarSuffix = ".trashinfo.json"
    static let retentionDays = 30

    let vaultRoot: URL
    var trashDirectory: URL { vaultRoot.appending(path: Self.directoryName, directoryHint: .isDirectory) }

    private var fm: FileManager { FileManager.default }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Operations

    /// Moves the item at `relativePath` into the trash. Returns its name in the trash.
    @discardableResult
    func trashItem(atRelativePath relativePath: RelativePath, deletedAt: Date = Date()) throws -> String {
        let sourceURL = vaultRoot.appendingRelativePath(relativePath)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw VaultError.notFound(relativePath)
        }
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)

        let trashedName = availableName(for: relativePath.lastComponent)
        let destination = trashDirectory.appending(path: trashedName)
        try fm.moveItem(at: sourceURL, to: destination)

        let info = TrashInfo(originalPath: relativePath, deletedAt: deletedAt)
        let data = try Self.makeEncoder().encode(info)
        try AtomicFile.write(data, to: sidecarURL(forTrashedName: trashedName))
        return trashedName
    }

    /// Delete Audio (AUD-1): moves the entry's audio file and waveform cache
    /// into the trash as one restorable item and marks the transcript's
    /// frontmatter `audio_deleted`. The transcript layers stay in place — the
    /// entry becomes a plain note. Returns the item's name in the trash.
    @discardableResult
    func trashEntryAudio(atEntryPath entryPath: RelativePath, deletedAt: Date = Date()) throws -> String {
        let entryURL = vaultRoot.appendingRelativePath(entryPath)
        let fileNames = ((try? fm.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard let audioName = VaultScanner.audioFile(in: fileNames) else {
            throw VaultError.notFound(entryPath.appendingComponent("audio"))
        }
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)

        let trashedName = availableName(for: "audio-" + entryPath.lastComponent)
        let wrapperURL = trashDirectory.appending(path: trashedName, directoryHint: .isDirectory)
        try fm.createDirectory(at: wrapperURL, withIntermediateDirectories: false)
        try fm.moveItem(
            at: entryURL.appending(path: audioName),
            to: wrapperURL.appending(path: audioName)
        )
        let waveformURL = WaveformData.url(inEntry: entryURL)
        if fm.fileExists(atPath: waveformURL.path) {
            try? fm.moveItem(at: waveformURL, to: wrapperURL.appending(path: WaveformData.fileName))
        }

        let info = TrashInfo(originalPath: entryPath, deletedAt: deletedAt, kind: .entryAudio)
        let data = try Self.makeEncoder().encode(info)
        try AtomicFile.write(data, to: sidecarURL(forTrashedName: trashedName))
        try setAudioDeletedFlag(true, inEntry: entryURL)
        return trashedName
    }

    func items() throws -> [TrashItem] {
        guard fm.fileExists(atPath: trashDirectory.path) else { return [] }
        let contents = try fm.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var items: [TrashItem] = []
        for url in contents where !url.lastPathComponent.hasSuffix(Self.sidecarSuffix) {
            let name = url.lastPathComponent
            let info = readInfo(forTrashedName: name)
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let kind = info?.kind ?? .item
            items.append(TrashItem(
                trashedName: name,
                originalPath: info?.originalPath ?? name,
                deletedAt: info?.deletedAt ?? modDate ?? Date(),
                isEntry: kind == .item && EntryFolderName(parsing: name) != nil,
                kind: kind
            ))
        }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Moves an item back to its original location (recreating parent folders).
    /// Returns the vault-relative path it was restored to.
    @discardableResult
    func restore(_ item: TrashItem) throws -> RelativePath {
        if item.kind == .entryAudio {
            return try restoreEntryAudio(item)
        }
        let sourceURL = trashDirectory.appending(path: item.trashedName)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw VaultError.notFound(item.trashedName)
        }

        var destPath: RelativePath = item.originalPath
        let parent = destPath.parentRelativePath
        if !parent.isEmpty {
            try fm.createDirectory(
                at: vaultRoot.appendingRelativePath(parent),
                withIntermediateDirectories: true
            )
        }
        // If something new occupies the original path, restore under a suffixed name.
        var candidate = destPath
        var counter = 2
        while fm.fileExists(atPath: vaultRoot.appendingRelativePath(candidate).path) {
            candidate = parent.appendingComponent("\(destPath.lastComponent)-\(counter)")
            counter += 1
        }
        destPath = candidate

        try fm.moveItem(at: sourceURL, to: vaultRoot.appendingRelativePath(destPath))
        try? fm.removeItem(at: sidecarURL(forTrashedName: item.trashedName))
        return destPath
    }

    /// Puts a trashed audio item's files back into their entry folder and
    /// clears the `audio_deleted` flag, fully reversing `trashEntryAudio`.
    private func restoreEntryAudio(_ item: TrashItem) throws -> RelativePath {
        let wrapperURL = trashDirectory.appending(path: item.trashedName, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: wrapperURL.path) else {
            throw VaultError.notFound(item.trashedName)
        }
        let entryURL = vaultRoot.appendingRelativePath(item.originalPath)
        try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)

        let names = ((try? fm.contentsOfDirectory(atPath: wrapperURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        for name in names {
            let destination = entryURL.appending(path: name)
            if fm.fileExists(atPath: destination.path) {
                // The entry re-acquired a same-named file meanwhile. A stale
                // waveform cache is not worth a duplicate (it rebuilds from
                // audio); a conflicting audio file restores under a suffix.
                if name == WaveformData.fileName { continue }
                let suffixed = availableFileName(name, inDirectory: entryURL)
                try fm.moveItem(at: wrapperURL.appending(path: name),
                                to: entryURL.appending(path: suffixed))
            } else {
                try fm.moveItem(at: wrapperURL.appending(path: name), to: destination)
            }
        }
        try setAudioDeletedFlag(false, inEntry: entryURL)
        try? fm.removeItem(at: wrapperURL)
        try? fm.removeItem(at: sidecarURL(forTrashedName: item.trashedName))
        return item.originalPath
    }

    func deletePermanently(_ item: TrashItem) throws {
        let url = trashDirectory.appending(path: item.trashedName)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try? fm.removeItem(at: sidecarURL(forTrashedName: item.trashedName))
    }

    /// Deletes items older than the retention window. Returns how many were purged.
    @discardableResult
    func purge(olderThanDays days: Int = TrashStore.retentionDays, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        var purged = 0
        for item in try items() where item.deletedAt < cutoff {
            try deletePermanently(item)
            purged += 1
        }
        return purged
    }

    // MARK: - Helpers

    func sidecarURL(forTrashedName name: String) -> URL {
        trashDirectory.appending(path: name + Self.sidecarSuffix)
    }

    func readInfo(forTrashedName name: String) -> TrashInfo? {
        guard let data = try? Data(contentsOf: sidecarURL(forTrashedName: name)) else { return nil }
        return try? Self.makeDecoder().decode(TrashInfo.self, from: data)
    }

    /// First non-colliding name inside the trash for an incoming item.
    func availableName(for name: String) -> String {
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: trashDirectory.appending(path: candidate).path) {
            candidate = "\(name)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// First non-colliding file name inside `directory`, suffixing before the
    /// extension (`audio.m4a` → `audio-2.m4a`).
    private func availableFileName(_ name: String, inDirectory directory: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: directory.appending(path: candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// Writes the `audio_deleted` frontmatter flag, creating a minimal
    /// `transcript.md` when the entry has none (an untranscribed import must
    /// still record why its audio is gone).
    private func setAudioDeletedFlag(_ deleted: Bool, inEntry entryURL: URL) throws {
        let transcriptURL = TranscriptFile.url(inEntry: entryURL)
            ?? entryURL.appending(path: TranscriptFile.defaultName)
        var doc: FrontmatterDocument
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            doc = FrontmatterDocument.parse(text)
        } else {
            guard deleted else { return }
            doc = FrontmatterDocument(fields: [], body: "")
            doc.created = EntryFolderName(parsing: entryURL.lastPathComponent)?.date
        }
        guard doc.audioDeleted != deleted else { return }
        doc.audioDeleted = deleted
        try AtomicFile.write(doc.serialized(), to: transcriptURL)
    }
}
