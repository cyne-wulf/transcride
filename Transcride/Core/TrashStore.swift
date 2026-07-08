import Foundation

/// Sidecar written next to each trashed item, recording where it came from.
struct TrashInfo: Codable, Equatable, Sendable {
    /// Vault-relative path the item lived at before deletion (including its name).
    var originalPath: String
    var deletedAt: Date
}

/// One item sitting in `<vault>/.trash/`.
struct TrashItem: Identifiable, Hashable, Sendable {
    /// The item's folder/file name inside `.trash` (may carry a collision suffix).
    var trashedName: String
    var originalPath: String
    var deletedAt: Date
    var isEntry: Bool

    var id: String { trashedName }

    var displayName: String {
        if isEntry, let name = EntryFolderName(parsing: trashedName),
           let slug = name.slug {
            return slug.split(separator: "-").joined(separator: " ").capitalized
        }
        return originalPath.lastComponent
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
            items.append(TrashItem(
                trashedName: name,
                originalPath: info?.originalPath ?? name,
                deletedAt: info?.deletedAt ?? modDate ?? Date(),
                isEntry: EntryFolderName(parsing: name) != nil
            ))
        }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Moves an item back to its original location (recreating parent folders).
    /// Returns the vault-relative path it was restored to.
    @discardableResult
    func restore(_ item: TrashItem) throws -> RelativePath {
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
}
