import Foundation
import Testing
@testable import Transcride

@Suite("App command dispatch and Quick Move integration", .serialized)
@MainActor
struct AppCommandIntegrationTests {
    private static let entryName = "transcride-2026-07-01T10-00-00-field-notes"

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-cmd-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        let entry = root.appending(path: "Journal/\(Self.entryName)")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Field Notes\"\ncreated: 2026-07-01T10:00:00+00:00\n---\nBody.\n",
            to: entry.appending(path: "Field Notes.md")
        )
        try fm.createDirectory(
            at: root.appending(path: "Projects"), withIntermediateDirectories: true
        )
        return root
    }

    private func makeReadyModel(vault: URL) async -> AppModel {
        let model = AppModel()
        await model.openVault(at: vault, isSecurityScoped: false, saveBookmark: false)
        return model
    }

    @Test func availabilityGatesCommandsBeforeAVaultOpens() {
        let model = AppModel()
        defer { model.shutdownGlobalRecordingControls() }
        #expect(!model.isAppCommandEnabled(.newRecording))
        #expect(!model.isAppCommandEnabled(.searchVault))
        #expect(!model.isAppCommandEnabled(.moveNote))
        #expect(model.isAppCommandEnabled(.showAbout))
        #expect(model.isAppCommandEnabled(.showKeyboardShortcuts))
        // Dispatch respects the same gate instead of half-performing.
        #expect(!model.performAppCommand(.searchVault) || model.isVaultSearchPresented == false)
    }

    /// The store writes the app's real defaults (tests run in the app host);
    /// snapshot and restore whatever the user had.
    private func preservingStoredAppShortcuts(_ body: () -> Void) {
        let key = AppShortcutPreferencesStore.defaultsKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func liveRemappingUpdatesMenusAndMatchingWithoutRelaunch() {
        preservingStoredAppShortcuts { liveRemappingBody() }
    }

    private func liveRemappingBody() {
        let model = AppModel()
        defer { model.shutdownGlobalRecordingControls() }

        // ⌥M resolves to Move Note out of the box and appears as a menu key.
        #expect(model.menuShortcut(for: .moveNote) != nil)
        var prefs = model.appShortcutPreferences
        let newChord = ShortcutChord(keyCode: 11, modifiers: [.command, .option]) // ⌘⌥B
        #expect(prefs.validation(
            settingChord: newChord, for: .moveNote, slot: .primary,
            globalBindings: model.globalShortcutPreferences.bindings
        ) == .valid)
        prefs.bindings[.moveNote] = AppShortcutBinding(primary: newChord)
        model.updateAppShortcutPreferences(prefs)

        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 11, modifiers: [.command, .option], isTextEditing: false,
            preferences: model.appShortcutPreferences,
            globalChords: model.configuredGlobalChords
        ) == .moveNote)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 46, modifiers: [.option], isTextEditing: false,
            preferences: model.appShortcutPreferences,
            globalChords: model.configuredGlobalChords
        ) == nil)

        // Round-trips through the store, then Reset restores ⌥M.
        #expect(AppShortcutPreferencesStore.load().chord(for: .moveNote) == newChord)
        model.resetAppShortcutPreferences()
        #expect(model.appShortcutPreferences == .defaults)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 46, modifiers: [.option], isTextEditing: false,
            preferences: model.appShortcutPreferences,
            globalChords: model.configuredGlobalChords
        ) == .moveNote)
    }

    @Test func globalRegistrationIsUntouchedByLocalRemapping() {
        preservingStoredAppShortcuts {
            let model = AppModel()
            defer { model.shutdownGlobalRecordingControls() }
            let globalBefore = model.globalShortcutPreferences
            var prefs = model.appShortcutPreferences
            prefs.bindings[.showAbout] = AppShortcutBinding(
                primary: ShortcutChord(keyCode: 16, modifiers: [.command, .option])
            )
            model.updateAppShortcutPreferences(prefs)
            #expect(model.globalShortcutPreferences == globalBefore)
        }
    }

    @Test func quickMoveMovesRepointsAndFollowsSelection() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let model = await makeReadyModel(vault: vault)
        defer { model.shutdownGlobalRecordingControls() }

        #expect(model.phase == .ready)
        let entryPath = "Journal/\(Self.entryName)"
        model.sidebarSelection = .folder("Journal")
        model.selectedEntryID = entryPath
        #expect(model.selectedEntry != nil)
        #expect(model.isAppCommandEnabled(.moveNote))

        #expect(model.presentQuickMove())
        #expect(model.isQuickMovePresented)
        let destinations = model.quickMoveDestinations
        // Vault Root first; the current parent (Journal) is excluded.
        #expect(destinations.first?.isVaultRoot == true)
        #expect(!destinations.map(\.path).contains("Journal"))
        let projects = try #require(destinations.first { $0.path == "Projects" })

        await model.performQuickMove(to: projects)

        let newPath = "Projects/\(Self.entryName)"
        #expect(model.quickMoveErrorMessage == nil)
        #expect(!model.isQuickMovePresented)
        #expect(model.selectedEntryID == newPath)
        #expect(model.snapshot?.entry(withID: newPath) != nil)
        #expect(model.snapshot?.entry(withID: entryPath) == nil)
        // The sidebar context is untouched; the detail follows the note.
        #expect(model.sidebarSelection == .folder("Journal"))
        #expect(FileManager.default.fileExists(
            atPath: vault.appending(path: newPath + "/Field Notes.md").path
        ))
    }

    @Test func quickMoveCollisionKeepsPickerOpenWithInlineError() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // Occupy the destination with a same-named entry.
        let occupied = vault.appending(path: "Projects/\(Self.entryName)")
        try FileManager.default.createDirectory(
            at: occupied, withIntermediateDirectories: true
        )
        try AtomicFile.write("keep", to: occupied.appending(path: "existing.md"))

        let model = await makeReadyModel(vault: vault)
        defer { model.shutdownGlobalRecordingControls() }
        let entryPath = "Journal/\(Self.entryName)"
        model.selectedEntryID = entryPath
        #expect(model.presentQuickMove())
        let projects = try #require(
            model.quickMoveDestinations.first { $0.path == "Projects" }
        )

        await model.performQuickMove(to: projects)

        #expect(model.isQuickMovePresented)
        #expect(model.quickMoveErrorMessage?.contains("already exists") == true)
        // Nothing moved and nothing was overwritten.
        #expect(model.snapshot?.entry(withID: entryPath) != nil)
        #expect(try String(
            contentsOf: occupied.appending(path: "existing.md"), encoding: .utf8
        ) == "keep")
    }

    @Test func quickMoveToVanishedDestinationExplainsAndStaysOpen() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let model = await makeReadyModel(vault: vault)
        defer { model.shutdownGlobalRecordingControls() }
        model.selectedEntryID = "Journal/\(Self.entryName)"
        #expect(model.presentQuickMove())
        let projects = try #require(
            model.quickMoveDestinations.first { $0.path == "Projects" }
        )
        // The folder disappears between listing and moving.
        try FileManager.default.removeItem(at: vault.appending(path: "Projects"))

        await model.performQuickMove(to: projects)

        #expect(model.isQuickMovePresented)
        #expect(model.quickMoveErrorMessage?.contains("no longer exists") == true)
    }

    @Test func quickMoveIsBlockedWithoutASelectedNote() {
        let model = AppModel()
        defer { model.shutdownGlobalRecordingControls() }
        #expect(model.quickMoveBlockReason() != nil)
        #expect(!model.presentQuickMove())
        #expect(!model.isQuickMovePresented)
    }

    // MARK: - Live-recording capture guard

    /// Exact-equality guards let the user delete, move or rename an *ancestor
    /// folder* of a live recording. The journal then rides into `.trash` and
    /// Empty Trash destroys the only copy of the audio.
    @Test(arguments: [
        // (operation target, live recording path, should block)
        ("Journal/transcride-2026-07-01T10-00-00", "Journal/transcride-2026-07-01T10-00-00", true),
        ("Journal", "Journal/transcride-2026-07-01T10-00-00", true),
        ("Work/2026", "Work/2026/Q3/transcride-2026-07-01T10-00-00", true),
        ("", "Journal/transcride-2026-07-01T10-00-00", true),
        // The classic separator bug: a sibling folder sharing a prefix.
        ("Journal2", "Journal/transcride-2026-07-01T10-00-00", false),
        ("Journ", "Journal/transcride-2026-07-01T10-00-00", false),
        // Unrelated siblings, and a descendant of the entry (never a target).
        ("Projects", "Journal/transcride-2026-07-01T10-00-00", false),
        ("Journal/transcride-2026-07-01T10-00-01", "Journal/transcride-2026-07-01T10-00-00", false),
    ] as [(String, String, Bool)])
    func ancestorFoldersOfALiveRecordingAreBlocked(
        target: String, live: String, blocked: Bool
    ) {
        #expect(
            AppModel.operationCapturesLiveRecording(target: target, liveEntryPath: live)
                == blocked
        )
    }

    @Test func nothingIsBlockedWhileNoRecordingIsLive() {
        #expect(!AppModel.operationCapturesLiveRecording(target: "", liveEntryPath: nil))
        #expect(!AppModel.operationCapturesLiveRecording(
            target: "Journal", liveEntryPath: nil
        ))
    }

    // MARK: - External change intersection

    /// Any write anywhere in the vault used to reload the open entry's whole
    /// transcript (full JSON decode, timing repair, word-map rebuild).
    @Test func externalChangeReloadIsLimitedToTheOpenEntry() {
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let open = "Journal/transcride-2026-07-01T10-00-00"
        func touches(_ paths: [String]) -> Bool {
            AppModel.externalChange(paths, touchesEntryAt: open, inVault: vault)
        }
        // The entry folder, and a file inside it.
        #expect(touches(["/tmp/vault/Journal/transcride-2026-07-01T10-00-00"]))
        #expect(touches(["/tmp/vault/Journal/transcride-2026-07-01T10-00-00/Note.md"]))
        // An ancestor folder: a folder rename arrives as an event on the folder.
        #expect(touches(["/tmp/vault/Journal"]))
        // Unrelated entries — including one whose path shares a prefix.
        #expect(!touches(["/tmp/vault/Journal/transcride-2026-07-01T10-00-01/Note.md"]))
        #expect(!touches(["/tmp/vault/Journal2/transcride-2026-07-01T10-00-00"]))
        #expect(!touches(["/tmp/vault/Projects/transcride-2026-08-01T10-00-00/Note.md"]))
        // One hit among misses still counts.
        #expect(touches([
            "/tmp/vault/Projects/transcride-2026-08-01T10-00-00/Note.md",
            "/tmp/vault/Journal/transcride-2026-07-01T10-00-00/Note.md",
        ]))
        // Unknown extent is treated as "everything", matching the index.
        #expect(touches([]))
    }

    // MARK: - Transcription queue path tracking

    /// A rename or move mid-transcription used to leave the running item
    /// pointing at the old path; the write threw `.notFound`, which read as
    /// "entry deleted", and the finished transcription was silently dropped.
    @Test func queueItemPathFollowsRenamesAndFolderMoves() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let service = VaultService(rootURL: vault)
        let queue = TranscriptionQueue(vaultRoot: vault, service: service)
        defer { queue.shutdown() }

        let original = "Journal/\(Self.entryName)"
        queue.enqueue(entryRelativePath: original, source: "test")
        let itemID = try #require(queue.items.first?.id)
        #expect(queue.currentPath(forItemID: itemID) == original)

        // An entry rename (auto-title or manual).
        let renamed = "Journal/transcride-2026-07-01T10-00-00-new-title"
        queue.repointItems(from: original, to: renamed)
        #expect(queue.currentPath(forItemID: itemID) == renamed)

        // A folder rename above it: descendants follow by prefix.
        queue.repointItems(from: "Journal", to: "Field Notes")
        #expect(queue.currentPath(forItemID: itemID)
            == "Field Notes/transcride-2026-07-01T10-00-00-new-title")

        // A sibling folder sharing a prefix must not be dragged along.
        queue.repointItems(from: "Field", to: "Moved")
        #expect(queue.currentPath(forItemID: itemID)
            == "Field Notes/transcride-2026-07-01T10-00-00-new-title")
    }

    /// The entry-folder timestamp is the stable identity, so an *external*
    /// rename that never reaches `repointItems` is still recoverable.
    @Test func externallyRenamedEntryIsFoundByItsTimestampIdentity() throws {
        let original = "Journal/\(Self.entryName)"
        let renamedInFinder = "Archive/transcride-2026-07-01T10-00-00-renamed-by-hand"
        #expect(EntryIdentity.sameEntry(original, renamedInFinder))
        #expect(!EntryIdentity.sameEntry(
            original, "Archive/transcride-2026-07-01T10-00-01-other"
        ))
    }
}
