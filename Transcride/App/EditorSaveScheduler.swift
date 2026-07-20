import Foundation

/// One ordered writer for the mounted editor. Autosave, explicit save,
/// lifecycle transitions, conflict resolution, and recovery all enqueue here;
/// no caller may derive a disk revision while an earlier writer is unresolved.
@MainActor
final class EditorSaveScheduler {
    enum Source: String, Sendable {
        case autosave
        case explicitSave
        case transition
        case conflictResolution
        case recovery
    }

    struct Ticket: Equatable, Sendable {
        var identity: EditorDocumentIdentity
        var generation: Int
        var body: String
        var source: Source
    }

    private var tail: Task<Bool, Never>?
    private(set) var pendingCount = 0

    @discardableResult
    func enqueue(
        _ ticket: Ticket,
        operation: @escaping @MainActor (Ticket) async -> Bool
    ) async -> Bool {
        pendingCount += 1
        defer { pendingCount -= 1 }
        let predecessor = tail
        let task = Task { @MainActor in
            _ = await predecessor?.value
            return await operation(ticket)
        }
        tail = task
        return await task.value
    }

    func drain() async -> Bool {
        await tail?.value ?? true
    }
}

enum EditorSaveLineage {
    /// Rebases a newer local buffer derived from `savedInput` onto the exact
    /// disk body produced by an older in-flight save. Workbench persistence
    /// uses this before publishing the new disk baseline.
    static func rebaseNewerBody(
        savedInput: String,
        newerBody: String,
        savedDiskBody: String
    ) -> EditorThreeWayMergeResult {
        EditorBodyMerger.merge(
            base: savedInput,
            mine: newerBody,
            external: savedDiskBody
        )
    }
}

struct EditorExternalReloadAdmissionState: Equatable, Sendable {
    var identity: EditorDocumentIdentity
    var generation: Int
    var body: String
    var baselineBody: String
    var needsSave: Bool

    var isDurablyCurrent: Bool {
        !needsSave && body == baselineBody
    }
}

/// A watcher reload may be requested while an older save is awaiting disk.
/// The save can succeed and rebase a newer buffer in memory, but that is not
/// sufficient permission to reload. Keep draining the production save path
/// until the exact latest generation is also the acknowledged disk baseline.
@MainActor
enum EditorExternalReloadAdmission {
    static func saveLatest(
        maximumAttempts: Int = 16,
        currentState: @escaping @MainActor () -> EditorExternalReloadAdmissionState?,
        save: @escaping @MainActor (EditorExternalReloadAdmissionState) async -> Bool
    ) async -> Bool {
        for _ in 0..<maximumAttempts {
            guard let before = currentState() else { return false }
            if before.isDurablyCurrent {
                // No suspension between these reads: this is the final
                // generation/body check immediately before reload admission.
                return currentState() == before
            }
            guard await save(before), let after = currentState() else { return false }
            if after.isDurablyCurrent {
                // A keystroke delivered while `save` awaited changes this
                // value and forces another pass instead of admitting reload.
                if currentState() == after { return true }
            }
        }
        return false
    }
}
