import Foundation
import Testing

@Suite("Persistent clip edit undo and redo")
struct ClipEditHistoryTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "transcride-clip-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: TrashStore.directoryName),
            withIntermediateDirectories: true
        )
        return root
    }

    private func addTrashName(_ name: String, to root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: TrashStore.directoryName).appending(path: name),
            withIntermediateDirectories: true
        )
    }

    @Test func historySurvivesRelaunchAndTransfersBetweenStacks() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try addTrashName("before-trim", to: root)
        try addTrashName("before-replace", to: root)
        let path = "transcride-2026-07-12T10-00-00-history"

        let store = ClipEditHistoryStore(vaultRoot: root)
        try store.record(
            operation: .trim, entryPath: path,
            versionTrashedName: "before-trim",
            existingTrashNames: ["before-trim"]
        )
        try store.record(
            operation: .replace, entryPath: path,
            versionTrashedName: "before-replace",
            existingTrashNames: ["before-trim", "before-replace"]
        )

        // A fresh value simulates app relaunch; both commands remain.
        let relaunched = ClipEditHistoryStore(vaultRoot: root)
        var history = relaunched.history(
            for: path, existingTrashNames: ["before-trim", "before-replace"]
        )
        #expect(history.undo.map(\.operation) == [.trim, .replace])
        #expect(history.redo.isEmpty)

        try addTrashName("after-replace", to: root)
        _ = try relaunched.completeSwap(
            direction: .undo,
            entryPath: path,
            restoredVersionName: "before-replace",
            displacedVersionName: "after-replace",
            existingTrashNames: ["before-trim", "before-replace", "after-replace"]
        )
        history = relaunched.history(
            for: path, existingTrashNames: ["before-trim", "after-replace"]
        )
        #expect(history.undo.map(\.versionTrashedName) == ["before-trim"])
        #expect(history.redo.map(\.versionTrashedName) == ["after-replace"])
    }

    @Test func newMutationInvalidatesRedoAndMissingVersionsArePruned() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "transcride-2026-07-12T11-00-00-branch"
        for name in ["old", "current", "new"] { try addTrashName(name, to: root) }
        let store = ClipEditHistoryStore(vaultRoot: root)
        try store.record(
            operation: .compress, entryPath: path, versionTrashedName: "old",
            existingTrashNames: ["old"]
        )
        _ = try store.completeSwap(
            direction: .undo, entryPath: path,
            restoredVersionName: "old", displacedVersionName: "current",
            existingTrashNames: ["old", "current"]
        )
        try store.record(
            operation: .extend, entryPath: path, versionTrashedName: "new",
            existingTrashNames: ["current", "new"]
        )
        var history = store.history(
            for: path, existingTrashNames: ["current", "new"]
        )
        #expect(history.redo.isEmpty)
        #expect(history.undo.map(\.versionTrashedName) == ["new"])

        try FileManager.default.removeItem(
            at: root.appending(path: TrashStore.directoryName).appending(path: "new")
        )
        history = store.history(for: path, existingTrashNames: ["current"])
        #expect(history.undo.isEmpty)
        #expect(history.redo.isEmpty)
    }

    @Test func movingFolderRekeysDescendantHistoriesWithoutTouchingPrefixSibling() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["inbox-version", "nested-version", "sibling-version", "stale-destination"] {
            try addTrashName(name, to: root)
        }
        let store = ClipEditHistoryStore(vaultRoot: root)
        let entry = "Inbox/transcride-2026-07-12T12-00-00-entry"
        let nestedEntry = "Inbox/Nested/transcride-2026-07-12T13-00-00-nested"
        let prefixSibling = "Inboxish/transcride-2026-07-12T14-00-00-sibling"
        let destination = "Archive/Inbox/transcride-2026-07-12T12-00-00-entry"
        try store.record(
            operation: .trim, entryPath: entry, versionTrashedName: "inbox-version",
            existingTrashNames: ["inbox-version"]
        )
        try store.record(
            operation: .extend, entryPath: nestedEntry, versionTrashedName: "nested-version",
            existingTrashNames: ["nested-version"]
        )
        try store.record(
            operation: .replace, entryPath: prefixSibling, versionTrashedName: "sibling-version",
            existingTrashNames: ["sibling-version"]
        )
        try store.record(
            operation: .compress, entryPath: destination,
            versionTrashedName: "stale-destination",
            existingTrashNames: ["stale-destination"]
        )

        try store.repointEntries(under: "Inbox", to: "Archive/Inbox")

        let allNames: Set<String> = [
            "inbox-version", "nested-version", "sibling-version", "stale-destination",
        ]
        #expect(store.history(for: entry, existingTrashNames: allNames).undo.isEmpty)
        #expect(store.history(
            for: "Archive/Inbox/transcride-2026-07-12T12-00-00-entry",
            existingTrashNames: allNames
        ).undo.map(\.versionTrashedName) == ["inbox-version"])
        #expect(store.history(
            for: "Archive/Inbox/Nested/transcride-2026-07-12T13-00-00-nested",
            existingTrashNames: allNames
        ).undo.map(\.versionTrashedName) == ["nested-version"])
        #expect(store.history(
            for: prefixSibling, existingTrashNames: allNames
        ).undo.map(\.versionTrashedName) == ["sibling-version"])
    }
}
