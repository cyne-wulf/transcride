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
}
