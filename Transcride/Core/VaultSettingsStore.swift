import Foundation

/// Per-vault preferences stored at `.transcride/settings.json` (beside the
/// transcription queue), so a vault carries its own policy when moved between
/// machines. Missing file, missing fields, or corrupt JSON all fall back to
/// defaults — the file is regenerated on the next write.
struct VaultSettings: Codable, Equatable, Sendable {
    var schema: Int?
    var trashRetentionDays: Int?

    enum CodingKeys: String, CodingKey {
        case schema
        case trashRetentionDays = "trash_retention_days"
    }
}

struct VaultSettingsStore: Sendable {
    static let fileName = "settings.json"
    static let schemaVersion = 1

    /// Recently Deleted retention window (SET-2); `TrashStore.retentionDays`
    /// remains the historical default for vaults that never configured one.
    static let defaultTrashRetentionDays = TrashStore.retentionDays
    static let trashRetentionChoices = [7, 14, 30, 60, 90]

    let vaultRoot: URL

    var fileURL: URL {
        vaultRoot
            .appending(path: TranscriptionQueueStore.directoryName, directoryHint: .isDirectory)
            .appending(path: Self.fileName)
    }

    func load() -> VaultSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(VaultSettings.self, from: data) else {
            return VaultSettings()
        }
        return settings
    }

    func save(_ settings: VaultSettings) throws {
        var settings = settings
        settings.schema = Self.schemaVersion
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(settings), to: fileURL)
    }

    // MARK: - Trash retention

    func trashRetentionDays() -> Int {
        guard let days = load().trashRetentionDays, days >= 1 else {
            return Self.defaultTrashRetentionDays
        }
        return days
    }

    func setTrashRetentionDays(_ days: Int) throws {
        var settings = load()
        settings.trashRetentionDays = max(1, days)
        try save(settings)
    }
}
