import Foundation
import Testing

@Suite("Vault settings and retention")
struct VaultSettingsStoreTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultsToThirtyDaysWhenUnconfigured() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultSettingsStore(vaultRoot: root)
        #expect(store.trashRetentionDays() == 30)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func retentionRoundTripsThroughTheFile() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultSettingsStore(vaultRoot: root)

        try store.setTrashRetentionDays(7)
        #expect(store.trashRetentionDays() == 7)
        // A fresh store (relaunch) reads the same value from disk.
        #expect(VaultSettingsStore(vaultRoot: root).trashRetentionDays() == 7)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"trash_retention_days\" : 7"))
    }

    @Test func corruptOrInvalidSettingsFallBackToDefault() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultSettingsStore(vaultRoot: root)

        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.trashRetentionDays() == 30)

        try store.save(VaultSettings(trashRetentionDays: 0))
        #expect(store.trashRetentionDays() == 30)
    }

    @Test func purgeHonorsTheConfiguredWindow() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryRelPath = "transcride-2026-07-01T10-00-00-old"
        try FileManager.default.createDirectory(
            at: root.appendingRelativePath(entryRelPath), withIntermediateDirectories: true
        )
        let trash = TrashStore(vaultRoot: root)
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 3600)
        try trash.trashItem(atRelativePath: entryRelPath, deletedAt: tenDaysAgo)

        let store = VaultSettingsStore(vaultRoot: root)

        // Default 30-day window keeps a 10-day-old item.
        #expect(try trash.purge(olderThanDays: store.trashRetentionDays()) == 0)
        #expect(try trash.items().count == 1)

        // A 7-day window purges it.
        try store.setTrashRetentionDays(7)
        #expect(try trash.purge(olderThanDays: store.trashRetentionDays()) == 1)
        #expect(try trash.items().isEmpty)
    }
}
