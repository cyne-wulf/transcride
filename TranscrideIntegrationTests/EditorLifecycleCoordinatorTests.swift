import AppKit
import Foundation
import Testing
@testable import Transcride

@Suite("Editor lifecycle coordinator", .serialized)
@MainActor
struct EditorLifecycleCoordinatorTests {
    @Test func nativeFindAndEditMenuUndoRedoRouteToMountedEditorOwnership() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 1)
        defer { fixture.cleanup() }
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        model.selectedEntryID = fixture.entryPaths[0]
        model.workbenchUIState.editorReady = true
        model.workbenchUIState.hasContent = true
        model.setEditorInputOwnsInput(true)

        let findRevision = model.inNoteFindRequestRevision
        model.performAppCommand(.findInNote)
        #expect(model.inNoteFindRequestRevision == findRevision + 1)

        model.performAppCommand(.undoClipEdit)
        if case .editorCommand(.undo)? = model.workbenchActionRequest {
            // Routed through the same mounted-host command seam as key input.
        } else {
            Issue.record("Native Undo did not route to CodeMirror")
        }
        model.performAppCommand(.redoClipEdit)
        if case .editorCommand(.redo)? = model.workbenchActionRequest {
            // Routed through the same mounted-host command seam as key input.
        } else {
            Issue.record("Native Redo did not route to CodeMirror")
        }
    }

    @Test func delayedOlderIntentCannotCommitAfterNewerDestination() async {
        let coordinator = EditorLifecycleCoordinator()
        let participant = SuspendedParticipant(path: "A", documentID: "doc-a")
        coordinator.register(participant)

        let older = Task { await coordinator.prepare(for: .entryChange("B")) }
        await participant.waitForPrepareCount(1)
        let newer = Task { await coordinator.prepare(for: .entryChange("C")) }

        participant.resumeNext(with: true)
        #expect(await older.value == false)
        await participant.waitForPrepareCount(2)
        participant.resumeNext(with: true)
        #expect(await newer.value)
        #expect(participant.reasons == [.entryChange("B"), .entryChange("C")])
    }

    @Test func disappearingParticipantPreparesOnlyItselfAfterReplacementRegisters() async {
        let coordinator = EditorLifecycleCoordinator()
        let old = ImmediateParticipant(path: "A", documentID: "doc-a")
        let replacement = ImmediateParticipant(path: "B", documentID: "doc-b")
        coordinator.register(old)
        coordinator.register(replacement)

        #expect(await coordinator.prepare(
            for: .workbenchTeardown,
            participant: old
        ))
        #expect(old.reasons == [.workbenchTeardown])
        #expect(replacement.reasons.isEmpty)
        #expect(coordinator.activeEntryPath == "B")
    }

    @Test func dirtyOldParticipantIsFrozenAndRetainedWhenReplacementRegisteredFirst() async {
        let coordinator = EditorLifecycleCoordinator()
        var oldOwner: CallbackParticipant? = CallbackParticipant(
            path: "A",
            documentID: "dirty-a"
        )
        weak var releasedOldOwner = oldOwner
        var frozeDirtyOld = false
        oldOwner?.onPrepare = { reason in
            #expect(reason == .workbenchTeardown)
            frozeDirtyOld = true
            return false
        }
        coordinator.register(oldOwner!)

        let replacement = ImmediateParticipant(path: "B", documentID: "clean-b")
        coordinator.register(replacement)
        #expect(!(await coordinator.prepare(
            for: .workbenchTeardown,
            participant: oldOwner!
        )))
        oldOwner = nil

        #expect(frozeDirtyOld)
        #expect(releasedOldOwner != nil)
        #expect(releasedOldOwner?.reasons == [.workbenchTeardown])
        #expect(replacement.reasons.isEmpty)
        #expect(coordinator.activeEntryPath == "B")
        #expect(coordinator.hasRetainedFailedTeardown)

        let retainedOld = try! #require(releasedOldOwner)
        retainedOld.onPrepare = { _ in true }
        #expect(await coordinator.prepare(
            for: .workbenchTeardown,
            participant: retainedOld
        ))
        coordinator.unregister(retainedOld)
        #expect(!coordinator.hasRetainedFailedTeardown)
    }

    @Test func failedTeardownRetainsDirtyParticipantAfterViewOwnerReleasesIt() async {
        let coordinator = EditorLifecycleCoordinator()
        var owner: CallbackParticipant? = CallbackParticipant(path: "A", documentID: "dirty-a")
        weak var releasedOwner = owner
        owner?.onPrepare = { _ in false }
        let participant = try! #require(owner)
        coordinator.register(participant)

        #expect(!(await coordinator.prepare(
            for: .workbenchTeardown,
            participant: participant
        )))
        owner = nil
        #expect(releasedOwner != nil)
        #expect(coordinator.hasRetainedFailedTeardown)
        #expect(coordinator.activeEntryPath == "A")

        releasedOwner?.onPrepare = { _ in true }
        #expect(await coordinator.prepare(
            for: .workbenchTeardown,
            participant: participant
        ))
        coordinator.unregister(participant)
        #expect(!coordinator.hasRetainedFailedTeardown)
    }

    @Test func sameDocumentRemapAdvancesIdentityAtomically() {
        let coordinator = EditorLifecycleCoordinator()
        let participant = ImmediateParticipant(path: "Folder/A", documentID: "stable")
        coordinator.register(participant)
        let previous = participant.editorDocumentIdentity

        #expect(coordinator.remapActiveDocument(
            expectedOldPath: "Folder/A",
            to: "Archive/A"
        ))
        #expect(participant.editorDocumentIdentity.path == "Archive/A")
        #expect(participant.editorDocumentIdentity.documentID == previous.documentID)
        #expect(participant.editorDocumentIdentity.vaultID == previous.vaultID)
        #expect(participant.editorDocumentIdentity.generation == previous.generation + 1)
        #expect(!coordinator.remapActiveDocument(
            expectedOldPath: "Folder/A",
            to: "Wrong/A"
        ))
    }

    @Test func rapidProductionSelectionUsesLatestDestination() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 3)
        defer { fixture.cleanup() }
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        let paths = fixture.entryPaths
        model.selectedEntryID = paths[0]
        let participant = SuspendedParticipant(path: paths[0], documentID: "stable-a")
        model.editorLifecycleCoordinator.register(participant)

        model.requestEntrySelection(paths[1])
        await participant.waitForPrepareCount(1)
        model.requestEntrySelection(paths[2])
        participant.resumeNext(with: true)
        await participant.waitForPrepareCount(2)
        participant.resumeNext(with: true)

        #expect(await eventually { model.selectedEntryID == paths[2] })
        #expect(model.selectedEntryID != paths[1])
    }

    @Test func rapidVaultReplacementCompletesInRequestOrderWithNewestVaultActive() async throws {
        let first = try AppLifecycleFixture(entryCount: 1)
        let second = try AppLifecycleFixture(entryCount: 1)
        let third = try AppLifecycleFixture(entryCount: 1)
        defer {
            first.cleanup()
            second.cleanup()
            third.cleanup()
        }
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: first.root, isSecurityScoped: false, saveBookmark: false)

        let openSecond = Task { @MainActor in
            await model.openVault(at: second.root, isSecurityScoped: false, saveBookmark: false)
        }
        await Task.yield()
        let openThird = Task { @MainActor in
            await model.openVault(at: third.root, isSecurityScoped: false, saveBookmark: false)
        }
        await openSecond.value
        await openThird.value

        let activeServiceRoot = await model.serviceForTesting?.rootURL
        #expect(model.vaultURL?.standardizedFileURL == third.root.standardizedFileURL)
        #expect(activeServiceRoot?.standardizedFileURL == third.root.standardizedFileURL)
        #expect(model.snapshot?.allEntries.map(\.relativePath) == third.entryPaths)
    }

    @Test func dirtyDuplicateImportAndFilterHideWaitForPersistence() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 1)
        defer { fixture.cleanup() }
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        let sourcePath = fixture.entryPaths[0]
        model.sidebarSelection = .folder("")
        model.selectedEntryID = sourcePath
        let participant = CallbackParticipant(path: sourcePath, documentID: "stable-source")
        participant.onPrepare = { _ in
            try fixture.writeBody("dirty-before-transition\r\n", at: participant.editorDocumentIdentity.path)
            return true
        }
        model.editorLifecycleCoordinator.register(participant)

        let source = try #require(model.snapshot?.entry(withID: sourcePath))
        await model.duplicateEntry(source)
        let duplicatePath = try #require(model.selectedEntryID)
        #expect(duplicatePath != sourcePath)
        #expect(try fixture.readBody(at: duplicatePath) == "dirty-before-transition\r\n")

        model.selectedEntryID = sourcePath
        participant.rebindEditorDocument(to: EditorDocumentIdentity(
            vaultID: "vault",
            documentID: "stable-source",
            path: sourcePath,
            generation: participant.editorDocumentIdentity.generation + 1
        ))
        let audioURL = try fixture.makeWaveFile()
        await model.importFiles([audioURL])
        let importedPath = try #require(model.selectedEntryID)
        #expect(importedPath != sourcePath)
        #expect(try fixture.readBody(at: sourcePath) == "dirty-before-transition\r\n")

        model.selectedEntryID = sourcePath
        participant.rebindEditorDocument(to: EditorDocumentIdentity(
            vaultID: "vault",
            documentID: "stable-source",
            path: sourcePath,
            generation: participant.editorDocumentIdentity.generation + 1
        ))
        model.requestSidebarSelection(.favorites)
        #expect(await eventually { model.selectedEntryID == nil })
        #expect(try fixture.readBody(at: sourcePath) == "dirty-before-transition\r\n")
        #expect(participant.reasons.count >= 3)
    }

    @Test func selectedRenameAndMoveRebindBeforeLaterAutosave() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 1, parent: "Inbox")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "Archive"),
            withIntermediateDirectories: true
        )
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        let originalPath = fixture.entryPaths[0]
        model.selectedEntryID = originalPath
        let participant = CallbackParticipant(path: originalPath, documentID: "stable-entry")
        model.editorLifecycleCoordinator.register(participant)

        let originalEntry = try #require(model.snapshot?.entry(withID: originalPath))
        await model.renameEntry(originalEntry, toTitle: "Renamed Entry")
        let renamedPath = participant.editorDocumentIdentity.path
        #expect(renamedPath != originalPath)
        #expect(model.selectedEntryID == renamedPath)

        let moveResult = await model.moveEntry(atRelativePath: renamedPath, toFolder: "Archive")
        let movedPath = try moveResult.get().movedPath
        #expect(participant.editorDocumentIdentity.path == movedPath)
        #expect(model.selectedEntryID == movedPath)

        let current = try fixture.readDocument(at: movedPath)
        let save = await model.compareAndSaveTranscriptBody(
            "autosaved-at-new-path\r\n",
            expectedRevision: EditorBodyRevision(body: current.body),
            markHandEdited: true,
            clearHandEdited: false,
            atEntryPath: participant.editorDocumentIdentity.path
        )
        guard case .saved? = save else {
            Issue.record("Expected autosave at rebound path")
            return
        }
        #expect(try fixture.readBody(at: movedPath) == "autosaved-at-new-path\r\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingRelativePath(originalPath).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingRelativePath(renamedPath).path))
    }

    @Test func unrelatedExternalPathDoesNotInvalidateSelectedEditor() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 2)
        defer { fixture.cleanup() }
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        let selected = fixture.entryPaths[0]
        model.selectedEntryID = selected
        let selectedRevision = model.selectedEntryExternalRevision

        await model.handleExternalVaultChangeForTesting(
            service: try #require(model.serviceForTesting),
            absolutePaths: [fixture.root.appendingRelativePath(fixture.entryPaths[1]).path]
        )
        #expect(model.selectedEntryExternalRevision == selectedRevision)

        await model.handleExternalVaultChangeForTesting(
            service: try #require(model.serviceForTesting),
            absolutePaths: [fixture.root.appendingRelativePath(selected).path]
        )
        #expect(model.selectedEntryExternalRevision == selectedRevision + 1)
    }

    @Test func ancestorRenameMoveAndDeleteUseDescendantBarrierAndRemap() async throws {
        let fixture = try AppLifecycleFixture(entryCount: 1, parent: "Parent/Child")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "Archive"),
            withIntermediateDirectories: true
        )
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }
        await model.openVault(at: fixture.root, isSecurityScoped: false, saveBookmark: false)
        let original = fixture.entryPaths[0]
        model.selectedEntryID = original
        let participant = CallbackParticipant(path: original, documentID: "stable-nested")
        model.editorLifecycleCoordinator.register(participant)

        await model.renameFolder(at: "Parent", to: "Renamed")
        let renamed = original.replacingOccurrences(of: "Parent/", with: "Renamed/")
        #expect(model.selectedEntryID == renamed)
        #expect(participant.editorDocumentIdentity.path == renamed)

        await model.moveItem(atRelativePath: "Renamed", toFolder: "Archive")
        let moved = "Archive/" + renamed
        #expect(model.selectedEntryID == moved)
        #expect(participant.editorDocumentIdentity.path == moved)

        participant.onPrepare = { _ in false }
        await model.deleteItem(atRelativePath: "Archive/Renamed")
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingRelativePath(moved).path
        ))
        #expect(model.selectedEntryID == moved)

        participant.onPrepare = { _ in true }
        await model.deleteItem(atRelativePath: "Archive/Renamed")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appending(path: "Archive/Renamed").path
        ))
        #expect(model.selectedEntryID == nil)
    }

    @Test func mainWindowCloseIsVetoedUntilParticipantDurabilitySucceeds() async {
        let model = AppModel()
        defer {
            model.shutdownGlobalRecordingControls()
            AppTerminationDelegate.model = nil
        }
        AppTerminationDelegate.model = model
        let participant = CallbackParticipant(path: "A", documentID: "stable-a")
        participant.onPrepare = { _ in false }
        model.editorLifecycleCoordinator.register(participant)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        AppWindowPresenter.installCloseGate(on: window)
        window.orderFront(nil)

        window.performClose(nil)
        #expect(await eventually {
            participant.reasons.count == 1
                && model.errorMessage?.contains("stayed open") == true
        })
        #expect(window.isVisible)
        #expect(model.errorMessage?.contains("stayed open") == true)

        participant.onPrepare = { _ in true }
        window.performClose(nil)
        #expect(await eventually { !window.isVisible })
        #expect(participant.reasons.count == 2)
    }

    @Test func autosaveNewEditAndTransitionShareOneExactOrderedTail() async {
        let scheduler = EditorSaveScheduler()
        let identity = EditorDocumentIdentity(
            vaultID: "vault",
            documentID: "stable",
            path: "A",
            generation: 1
        )
        var events: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await scheduler.enqueue(.init(
                identity: identity,
                generation: 1,
                body: "X",
                source: .autosave
            )) { ticket in
                events.append("start-\(ticket.body)")
                await withCheckedContinuation { releaseFirst = $0 }
                events.append("finish-\(ticket.body)")
                return true
            }
        }
        #expect(await eventually { events == ["start-X"] })

        let second = Task { @MainActor in
            await scheduler.enqueue(.init(
                identity: identity,
                generation: 2,
                body: "Y",
                source: .autosave
            )) { ticket in
                events.append("start-\(ticket.body)")
                events.append("finish-\(ticket.body)")
                return true
            }
        }
        #expect(await eventually { scheduler.pendingCount == 2 })
        let transition = Task { @MainActor in
            await scheduler.enqueue(.init(
                identity: identity,
                generation: 2,
                body: "Y",
                source: .transition
            )) { ticket in
                events.append("transition-\(ticket.body)")
                return true
            }
        }
        #expect(await eventually { scheduler.pendingCount == 3 })
        releaseFirst?.resume()

        #expect(await first.value)
        #expect(await second.value)
        #expect(await transition.value)
        #expect(events == ["start-X", "finish-X", "start-Y", "finish-Y", "transition-Y"])
        #expect(await scheduler.drain())
        #expect(scheduler.pendingCount == 0)
    }
}

@MainActor
private final class ImmediateParticipant: EditorTransitionParticipant {
    var editorDocumentIdentity: EditorDocumentIdentity
    private(set) var reasons: [EditorTransitionReason] = []

    init(path: RelativePath, documentID: String) {
        editorDocumentIdentity = EditorDocumentIdentity(
            vaultID: "vault",
            documentID: documentID,
            path: path,
            generation: 1
        )
    }

    func prepareForEditorTransition(_ reason: EditorTransitionReason) async -> Bool {
        reasons.append(reason)
        return true
    }

    func rebindEditorDocument(to identity: EditorDocumentIdentity) {
        editorDocumentIdentity = identity
    }
}

@MainActor
private final class SuspendedParticipant: EditorTransitionParticipant {
    var editorDocumentIdentity: EditorDocumentIdentity
    private(set) var reasons: [EditorTransitionReason] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    init(path: RelativePath, documentID: String) {
        editorDocumentIdentity = EditorDocumentIdentity(
            vaultID: "vault",
            documentID: documentID,
            path: path,
            generation: 1
        )
    }

    func prepareForEditorTransition(_ reason: EditorTransitionReason) async -> Bool {
        reasons.append(reason)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func rebindEditorDocument(to identity: EditorDocumentIdentity) {
        editorDocumentIdentity = identity
    }

    func waitForPrepareCount(_ count: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while reasons.count < count, clock.now < deadline {
            await Task.yield()
        }
    }

    func resumeNext(with result: Bool) {
        continuations.removeFirst().resume(returning: result)
    }
}

@MainActor
private final class CallbackParticipant: EditorTransitionParticipant {
    var editorDocumentIdentity: EditorDocumentIdentity
    var onPrepare: (EditorTransitionReason) async throws -> Bool = { _ in true }
    private(set) var reasons: [EditorTransitionReason] = []

    init(path: RelativePath, documentID: String) {
        editorDocumentIdentity = EditorDocumentIdentity(
            vaultID: "vault",
            documentID: documentID,
            path: path,
            generation: 1
        )
    }

    func prepareForEditorTransition(_ reason: EditorTransitionReason) async -> Bool {
        reasons.append(reason)
        return (try? await onPrepare(reason)) ?? false
    }

    func rebindEditorDocument(to identity: EditorDocumentIdentity) {
        editorDocumentIdentity = identity
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private struct AppLifecycleFixture: @unchecked Sendable {
    let root: URL
    let entryPaths: [RelativePath]

    init(entryCount: Int, parent: RelativePath = "") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "TranscrideLifecycleIntegration-\(UUID().uuidString)")
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                at: root.appendingRelativePath(parent),
                withIntermediateDirectories: true
            )
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var paths: [RelativePath] = []
        for index in 0..<entryCount {
            let name = String(format: "transcride-2026-07-20T06-%02d-00-entry-%d", index, index)
            let path = parent.appendingComponent(name)
            let directory = root.appendingRelativePath(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var document = FrontmatterDocument(fields: [], body: "body-\(index)\r\n")
            document.title = "Entry \(index)"
            try AtomicFile.write(
                document.serialized(),
                to: directory.appending(path: TranscriptFile.fileName(forTitle: document.title))
            )
            paths.append(path)
        }
        entryPaths = paths
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func readDocument(at path: RelativePath) throws -> FrontmatterDocument {
        let directory = root.appendingRelativePath(path)
        let url = try #require(TranscriptFile.url(inEntry: directory))
        return FrontmatterDocument.parse(try String(contentsOf: url, encoding: .utf8))
    }

    func readBody(at path: RelativePath) throws -> String {
        try readDocument(at: path).body
    }

    func writeBody(_ body: String, at path: RelativePath) throws {
        let directory = root.appendingRelativePath(path)
        let url = try #require(TranscriptFile.url(inEntry: directory))
        var document = FrontmatterDocument.parse(try String(contentsOf: url, encoding: .utf8))
        document.body = body
        try AtomicFile.write(document.serialized(), to: url)
    }

    func makeWaveFile() throws -> URL {
        let url = root.appending(path: "import-fixture.wav")
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var bytes = Data()
        func appendASCII(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func appendLE16(_ value: UInt16) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
        }
        func appendLE32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
            bytes.append(UInt8((value >> 16) & 0xff))
            bytes.append(UInt8((value >> 24) & 0xff))
        }
        appendASCII("RIFF")
        appendLE32(36 + dataSize)
        appendASCII("WAVEfmt ")
        appendLE32(16)
        appendLE16(1)
        appendLE16(1)
        appendLE32(sampleRate)
        appendLE32(sampleRate * 2)
        appendLE16(2)
        appendLE16(16)
        appendASCII("data")
        appendLE32(dataSize)
        bytes.append(Data(repeating: 0, count: Int(dataSize)))
        try AtomicFile.write(bytes, to: url)
        return url
    }
}
