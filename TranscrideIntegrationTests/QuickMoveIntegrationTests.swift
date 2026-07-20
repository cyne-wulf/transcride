import Foundation
import Testing
@testable import Transcride

@Suite("Quick Move app integration", .serialized)
@MainActor
struct QuickMoveIntegrationTests {
    @Test func editorGateCollisionMoveSelectionQueueAndSearchStayCoherent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.vault) }
        try await exerciseMove(fixture)
    }

    private func exerciseMove(_ fixture: Fixture) async throws {
        let model = AppModel()
        defer {
            model.transcriptionQueue?.shutdown()
            model.shutdownGlobalRecordingControls()
        }

        await model.openVault(
            at: fixture.vault,
            isSecurityScoped: false,
            saveBookmark: false
        )
        model.sidebarSelection = .folder("Inbox")
        model.selectedEntryID = fixture.sourcePath

        let indexReady = await eventually { model.searchIndexState == .ready }
        #expect(indexReady)
        model.presentVaultSearch()
        model.updateVaultSearchQuery(fixture.searchTerm)
        model.retryVaultSearch()
        let oldPathIndexed = await eventually {
            !model.vaultSearchIsRunning
                && Set(model.vaultSearchResults.map(\.entryPath)) == [fixture.sourcePath]
        }
        #expect(oldPathIndexed)

        model.workbenchUIState.isEditing = true
        model.requestQuickMove()
        #expect(!model.isQuickMovePresented)
        #expect(model.quickMovePreparationEntryPath == fixture.sourcePath)
        if case .finishEditingForQuickMove? = model.workbenchActionRequest {
            // Expected typed editor handshake.
        } else {
            Issue.record("Quick Move must request a final editor save first")
        }

        model.completeQuickMovePreparation(for: fixture.sourcePath, saved: false)
        #expect(model.quickMovePreparationEntryPath == nil)
        #expect(!model.isQuickMovePresented)
        #expect(model.quickMoveEntry == nil)

        model.requestQuickMove()
        model.completeQuickMovePreparation(for: fixture.sourcePath, saved: true)
        model.workbenchUIState.isEditing = false
        #expect(model.isQuickMovePresented)
        #expect(model.quickMoveEntryPath == fixture.sourcePath)
        #expect(model.quickMoveEntry?.relativePath == fixture.sourcePath)

        let collisionURL = fixture.vault.appendingRelativePath(fixture.destinationPath)
        try FileManager.default.createDirectory(
            at: collisionURL,
            withIntermediateDirectories: false
        )
        try AtomicFile.write("occupant", to: collisionURL.appending(path: "marker.txt"))

        let collision = await model.moveEntry(
            atRelativePath: fixture.sourcePath,
            toFolder: "Archive"
        )
        if case .failure(.destinationCollision(let name, let folder)) = collision {
            #expect(name == fixture.entryName)
            #expect(folder == "Archive")
        } else {
            Issue.record("Expected a typed destination collision")
        }
        #expect(model.isQuickMovePresented)
        #expect(model.selectedEntryID == fixture.sourcePath)
        #expect(model.snapshot?.entry(withID: fixture.sourcePath) != nil)
        #expect(model.transcriptionQueue?.items.first?.entryRelativePath == fixture.sourcePath)
        #expect(FileManager.default.fileExists(
            atPath: fixture.vault.appendingRelativePath(fixture.sourcePath).path
        ))
        try FileManager.default.removeItem(at: collisionURL)

        let moved = await model.moveEntry(
            atRelativePath: fixture.sourcePath,
            toFolder: "Archive"
        )
        #expect(try moved.get().movedPath == fixture.destinationPath)
        #expect(model.snapshot?.entry(withID: fixture.sourcePath) == nil)
        #expect(model.snapshot?.entry(withID: fixture.destinationPath) != nil)
        #expect(model.selectedEntryID == fixture.destinationPath)
        #expect(model.selectedEntry?.relativePath == fixture.destinationPath)
        #expect(model.quickMoveEntryPath == fixture.destinationPath)
        #expect(model.quickMoveEntry?.relativePath == fixture.destinationPath)
        #expect(model.sidebarSelection == .folder("Inbox"))
        #expect(!model.displayedEntries.contains { $0.relativePath == fixture.destinationPath })
        #expect(model.transcriptionQueue?.items.first?.entryRelativePath == fixture.destinationPath)
        #expect(
            TranscriptionQueueStore.load(fromVault: fixture.vault)
                .first?.entryRelativePath == fixture.destinationPath
        )
        #expect(!FileManager.default.fileExists(
            atPath: fixture.vault.appendingRelativePath(fixture.sourcePath).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.vault.appendingRelativePath(fixture.destinationPath).path
        ))
        #expect(try Data(
            contentsOf: fixture.vault
                .appendingRelativePath(fixture.destinationPath)
                .appending(path: "payload.bin")
        ) == Data([0xCA, 0xFE, 0xBA, 0xBE]))

        let newPathIndexed = await eventually {
            !model.vaultSearchIsRunning
                && Set(model.vaultSearchResults.map(\.entryPath)) == [fixture.destinationPath]
        }
        #expect(newPathIndexed)
    }

    private struct Fixture {
        var vault: URL
        var entryName: String
        var sourcePath: RelativePath
        var destinationPath: RelativePath
        var searchTerm: String
    }

    private func makeFixture() throws -> Fixture {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "TranscrideQuickMoveIntegration-\(UUID().uuidString)")
        let entryName = "transcride-2026-07-17T06-30-00-move-integration"
        let sourcePath = "Inbox/\(entryName)"
        let destinationPath = "Archive/\(entryName)"
        let searchTerm = "quickmoveintegrationsentinel"
        let entryURL = vault.appendingRelativePath(sourcePath)
        try FileManager.default.createDirectory(
            at: entryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: vault.appending(path: "Archive"),
            withIntermediateDirectories: true
        )

        var document = FrontmatterDocument(fields: [], body: "\n\(searchTerm)\n")
        document.title = "Move Integration"
        try AtomicFile.write(
            document.serialized(),
            to: entryURL.appending(path: TranscriptFile.defaultName)
        )
        try AtomicFile.write(
            Data([0xCA, 0xFE, 0xBA, 0xBE]),
            to: entryURL.appending(path: "payload.bin")
        )
        try TranscriptionQueueStore.save(
            [
                TranscriptionQueueItem(
                    entryRelativePath: sourcePath,
                    modelID: "integration-model",
                    source: "integration",
                    createdAt: .now,
                    state: .failed,
                    errorMessage: "Intentional failed item"
                ),
            ],
            toVault: vault
        )
        return Fixture(
            vault: vault,
            entryName: entryName,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            searchTerm: searchTerm
        )
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@Suite("App shortcut dispatcher integration", .serialized)
@MainActor
struct AppShortcutDispatcherIntegrationTests {
    @Test func liveBindingsAlternatesCaptureAndResetUseOneDispatcher() async throws {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "TranscrideShortcutIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let defaults = UserDefaults.standard
        let originalAppData = defaults.data(forKey: AppShortcutPreferencesStore.defaultsKey)
        let model = AppModel()
        defer {
            model.setShortcutCaptureOwnsInput(false)
            model.shutdownGlobalRecordingControls()
            if let originalAppData {
                defaults.set(originalAppData, forKey: AppShortcutPreferencesStore.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppShortcutPreferencesStore.defaultsKey)
            }
        }
        await model.openVault(at: vault, isSecurityScoped: false, saveBookmark: false)

        model.globalShortcutService.apply(model.globalShortcutPreferences)
        let globalPreferencesBefore = model.globalShortcutPreferences
        let globalStatusesBefore = model.globalShortcutService.statuses
        let primary = ShortcutChord(keyCode: 12, modifiers: []) // Q
        let alternate = ShortcutChord(keyCode: 11, modifiers: .option) // Option-B
        var preferences = model.appShortcutPreferences
        preferences[.goToFavorites, .primary] = primary
        preferences[.goToFavorites, .alternate] = alternate
        model.updateAppShortcutPreferences(preferences)

        #expect(model.globalShortcutPreferences == globalPreferencesBefore)
        #expect(model.globalShortcutService.statuses == globalStatusesBefore)
        #expect(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: false
        ) == .goToFavorites)
        #expect(model.appShortcutAction(
            forKeyCode: 11,
            modifiers: .option,
            editableTextHasFocus: false
        ) == .goToFavorites)
        #expect(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: true
        ) == nil)
        #expect(
            AppShortcutMenu.title("Favorites", action: .goToFavorites, model: model)
                .contains(primary.glyphDescription)
        )

        let routedAction = try #require(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: false
        ))
        model.performAppCommand(routedAction)
        #expect(await eventually { model.sidebarSelection == .favorites })
        #expect(!model.isAppCommandEnabled(.moveNote))

        model.setShortcutCaptureOwnsInput(true)
        #expect(model.shortcutCaptureOwnsInput)
        #expect(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: false
        ) == nil)
        #expect(model.globalShortcutPreferences == globalPreferencesBefore)
        model.setShortcutCaptureOwnsInput(false)
        #expect(model.globalShortcutService.statuses == globalStatusesBefore)
        #expect(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: false
        ) == .goToFavorites)

        preferences[.goToFavorites, .primary] = nil
        model.updateAppShortcutPreferences(preferences)
        #expect(model.appShortcutAction(
            forKeyCode: 12,
            modifiers: [],
            editableTextHasFocus: false
        ) == nil)
        #expect(model.appShortcutAction(
            forKeyCode: 11,
            modifiers: .option,
            editableTextHasFocus: false
        ) == .goToFavorites)
        #expect(
            AppShortcutMenu.title("Favorites", action: .goToFavorites, model: model)
                == "Favorites"
        )

        model.resetAppShortcutPreferences()
        #expect(model.appShortcutPreferences == .defaults)
        #expect(model.appShortcutAction(
            forKeyCode: 11,
            modifiers: .option,
            editableTextHasFocus: false
        ) == nil)
        #expect(model.globalShortcutPreferences == globalPreferencesBefore)
        #expect(model.globalShortcutService.statuses == globalStatusesBefore)
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
