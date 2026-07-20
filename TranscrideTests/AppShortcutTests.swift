import Foundation
import Testing

@Suite("App shortcuts")
struct AppShortcutTests {
    @Test func catalogHasStableUniqueActionIDsAndAllCategories() {
        let expectedIDs: Set<String> = [
            "recording.new", "recording.start-stop", "recording.pause-playback",
            "file.import-audio", "file.new-folder",
            "entry.favorite", "entry.rename", "entry.duplicate", "entry.move-note",
            "entry.move-to-recently-deleted", "entry.extend", "entry.edit-save",
            "entry.copy-markdown", "entry.toggle-layer", "entry.retranscribe",
            "entry.trim", "entry.replace", "entry.compress", "entry.restore-original",
            "toggleSpeakerDetection", "entry.rename-speakers",
            "entry.delete-audio", "entry.info", "entry.reveal",
            "entry.export-markdown", "entry.share-audio", "entry.open-in-obsidian",
            "playback.clip-undo", "playback.clip-redo", "playback.skip-back",
            "playback.skip-forward", "playback.jump-0", "playback.jump-1",
            "playback.jump-2", "playback.jump-3", "playback.jump-4",
            "playback.jump-5", "playback.jump-6", "playback.jump-7",
            "playback.jump-8", "playback.jump-9", "playback.speed-down",
            "playback.speed-up", "playback.speed-reset", "playback.skip-silence",
            "playback.zen", "library.find-in-note", "library.search-vault",
            "library.previous-folder", "library.next-folder", "library.sort-date",
            "library.sort-duration", "library.sort-title",
            "library.sort-recently-edited", "library.vault-root",
            "library.favorites", "library.recently-deleted",
            "library.transcription-queue", "app.about", "help.keyboard-shortcuts",
        ]
        let actions = AppShortcutAction.allCases
        #expect(Set(actions.map(\.rawValue)) == expectedIDs)
        #expect(actions.count == expectedIDs.count)
        #expect(Set(actions.map(\.category)) == Set(AppShortcutCategory.allCases))
    }

    @Test func defaultsCoverEveryActionAndPreserveEstablishedBindings() {
        let preferences = AppShortcutPreferences.defaults
        #expect(preferences.bindings.count == AppShortcutAction.allCases.count)
        #expect(preferences[.newRecording, .primary] == chord(45, .command))
        #expect(preferences[.toggleRecording, .primary] == chord(49, .shift))
        #expect(preferences[.togglePausePlayback, .primary] == chord(49))
        #expect(preferences[.importAudio, .primary] == chord(34, [.command, .shift]))
        #expect(preferences[.newFolder, .primary] == chord(45, [.command, .shift]))
        #expect(preferences[.toggleFavorite, .primary] == chord(2, .command))
        #expect(preferences[.moveNote, .primary] == chord(46, .option))
        #expect(preferences.bindingSet(for: .moveToRecentlyDeleted) == .init(
            primary: chord(51, .command), alternate: chord(51, .shift)
        ))
        #expect(preferences.bindingSet(for: .extendRecording) == .init(
            primary: chord(14), alternate: chord(15, [.command, .shift])
        ))
        #expect(preferences[.editOrSaveNote, .primary] == chord(14, .command))
        #expect(preferences[.copyMarkdown, .primary] == chord(8, [.command, .shift]))
        #expect(preferences[.trimAudio, .primary] == chord(17))
        #expect(preferences[.replaceAudio, .primary] == chord(15))
        #expect(preferences[.showInfo, .primary] == chord(34, .command))
        #expect(preferences[.exportMarkdown, .primary] == chord(14, [.command, .shift]))
        #expect(preferences[.undoClipEdit, .primary] == chord(6, .command))
        #expect(preferences[.redoClipEdit, .primary] == chord(6, [.command, .shift]))
        #expect(preferences[.skipBackward, .primary] == chord(123))
        #expect(preferences[.skipForward, .primary] == chord(124))
        #expect(preferences[.decreasePlaybackSpeed, .primary] == chord(33))
        #expect(preferences[.increasePlaybackSpeed, .primary] == chord(30))
        #expect(preferences[.resetPlaybackSpeed, .primary] == chord(42))
        #expect(preferences[.toggleSkipSilence, .primary] == chord(1))
        #expect(preferences[.enterZenMode, .primary] == chord(6))
        #expect(preferences[.findInNote, .primary] == chord(3, .command))
        #expect(preferences[.searchVault, .primary] == chord(3, [.command, .shift]))
        #expect(preferences[.previousFolder, .primary] == chord(126, .option))
        #expect(preferences[.nextFolder, .primary] == chord(125, .option))
        #expect(preferences[.showKeyboardShortcuts, .primary] == chord(
            44, [.command, .shift]
        ))

        let expectedUnbound: Set<AppShortcutAction> = [
            .renameEntry, .duplicateEntry, .toggleTranscriptLayer, .retranscribe,
            .compressAudio, .restoreOriginalAudio, .toggleSpeakerDetection,
            .renameSpeakers, .deleteAudio, .revealInFinder, .shareAudio,
            .openInObsidian, .sortByDate, .sortByDuration, .sortByTitle,
            .sortByRecentlyEdited, .goToVaultRoot, .goToFavorites,
            .goToRecentlyDeleted, .showTranscriptionQueue, .showAbout,
        ]
        let actualUnbound = Set(AppShortcutAction.allCases.filter {
            preferences.bindingSet(for: $0).orderedChords.isEmpty
        })
        #expect(actualUnbound == expectedUnbound)
    }

    @Test func digitJumpsPreserveTopRowAndKeypadAlternates() {
        let expected: [(AppShortcutAction, UInt32, UInt32, Double, Int)] = [
            (.jump0, 29, 82, 0, 0), (.jump1, 18, 83, 0.1, 1),
            (.jump2, 19, 84, 0.2, 2), (.jump3, 20, 85, 0.3, 3),
            (.jump4, 21, 86, 0.4, 4), (.jump5, 23, 87, 0.5, 5),
            (.jump6, 22, 88, 0.6, 6), (.jump7, 26, 89, 0.7, 7),
            (.jump8, 28, 91, 0.8, 8), (.jump9, 25, 92, 1, 9),
        ]
        let preferences = AppShortcutPreferences.defaults
        for (action, topRow, keypad, fraction, digit) in expected {
            #expect(preferences[action, .primary] == chord(topRow))
            #expect(preferences[action, .alternate] == chord(keypad))
            #expect(action.playbackFraction == fraction)
            #expect(preferences[action, .alternate]?.glyphDescription == "Keypad \(digit)")
        }
    }

    @Test func glyphsUseMacModifierOrderAndIdentifyPhysicalKeypadKeys() {
        #expect(chord(15, [.command, .shift, .option, .control]).glyphDescription == "⌃⌥⇧⌘R")
        #expect(chord(82).glyphDescription == "Keypad 0")
        #expect(chord(999).glyphDescription == "Key 999")
    }

    @Test func localValidationAcceptsBareKeysAndRejectsStructuralAndNativeChords() {
        #expect(ShortcutReservation.localReason(for: chord(14)) == nil)
        #expect(ShortcutReservation.localReason(for: chord(6, .command)) == nil)
        #expect(ShortcutReservation.localReason(for: chord(45, .command)) == nil)

        for fixed in [
            chord(53), chord(53, .option), chord(36), chord(36, .command),
            chord(48), chord(48, .shift), chord(76, .option),
            chord(125), chord(126), chord(51), chord(117), chord(12, .command),
            chord(5, .command), chord(5, [.command, .shift]),
            chord(47, .command), chord(49, [.control, .command]),
            chord(2, [.command, .option]), chord(50, .command),
        ] {
            #expect(ShortcutReservation.localReason(for: fixed) != nil)
        }
        #expect(ShortcutReservation.localReason(for: chord(125, .option)) == nil)
        #expect(ShortcutReservation.localReason(for: chord(51, .shift)) == nil)
        #expect(ShortcutReservation.localReason(for: chord(51, .command)) == nil)
    }

    @Test func validationReportsDuplicateAppAndGlobalAssignments() {
        var preferences = AppShortcutPreferences.defaults
        let move = try! #require(preferences[.moveNote, .primary])

        preferences[.moveNote, .alternate] = move
        #expect(preferences.validationStatus(
            for: .moveNote, slot: .primary
        ) == .duplicateWithinAction)
        #expect(preferences.validationStatus(
            for: .moveNote, slot: .alternate
        ) == .duplicateWithinAction)

        preferences[.moveNote, .alternate] = nil
        preferences[.renameEntry, .primary] = move
        #expect(preferences.validationStatus(
            for: .moveNote, slot: .primary
        ) == .conflictsWithApp(.renameEntry))
        #expect(preferences.validationStatus(
            for: .renameEntry, slot: .primary
        ) == .conflictsWithApp(.moveNote))
        #expect(!preferences.activeBindings().contains { $0.action == .moveNote })
        #expect(!preferences.activeBindings().contains { $0.action == .renameEntry })

        preferences[.renameEntry, .primary] = nil
        let globals = [move: "Start / Stop & Save Recording"]
        #expect(preferences.validationStatus(
            for: .moveNote, slot: .primary, globalBindings: globals
        ) == .conflictsWithGlobal("Start / Stop & Save Recording"))
        #expect(!preferences.activeBindings(globalBindings: globals).contains {
            $0.action == .moveNote
        })
    }

    @Test func modifierOnlyAndReservedCandidatesRemainPersistedButInactive() {
        var preferences = AppShortcutPreferences.defaults
        preferences[.renameEntry, .primary] = ShortcutChord(
            keyCode: ShortcutChord.modifierOnlyKeyCode,
            modifiers: .command
        )
        preferences[.duplicateEntry, .primary] = chord(12, .command)
        #expect(preferences.validationStatus(
            for: .renameEntry, slot: .primary
        ) == .modifierOnly)
        guard case .reserved = preferences.validationStatus(
            for: .duplicateEntry, slot: .primary
        ) else {
            Issue.record("Expected Command-Q to remain stored but reserved")
            return
        }
        #expect(!preferences.activeBindings().contains { binding in
            binding.action == .renameEntry || binding.action == .duplicateEntry
        })
    }

    @Test func preferencesRoundTripClearsSlotsAndMergesNewCatalogEntries() throws {
        var preferences = AppShortcutPreferences.defaults
        preferences[.moveNote, .primary] = nil
        preferences[.renameEntry, .alternate] = chord(38, [.command, .option])
        let restored = try JSONDecoder().decode(
            AppShortcutPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        #expect(restored == preferences)
        #expect(restored[.moveNote, .primary] == nil)
        #expect(restored[.renameEntry, .alternate] == chord(38, [.command, .option]))

        let partial = AppShortcutPreferences(
            bindings: [.moveNote: .init(primary: nil, alternate: chord(38))]
        )
        let merged = try JSONDecoder().decode(
            AppShortcutPreferences.self,
            from: JSONEncoder().encode(partial)
        )
        #expect(merged.bindings.count == AppShortcutAction.allCases.count)
        #expect(merged[.moveNote, .primary] == nil)
        #expect(merged[.moveNote, .alternate] == chord(38))
        #expect(merged[.newRecording, .primary] == chord(45, .command))
    }

    @Test func preferencesStoreDefaultsRoundTripsAndRejectsFutureVersions() throws {
        let suite = "AppShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == .defaults)
        var changed = AppShortcutPreferences.defaults
        changed[.moveNote, .primary] = chord(38, [.command, .option])
        AppShortcutPreferencesStore.save(changed, defaults: defaults)
        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == changed)

        changed.version = AppShortcutPreferences.currentVersion + 1
        AppShortcutPreferencesStore.save(changed, defaults: defaults)
        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == .defaults)
    }

    @Test func matcherHonorsAlternatesTextFocusCaptureAndGlobalPrecedence() {
        let preferences = AppShortcutPreferences.defaults
        #expect(match(14, preferences: preferences) == .extendRecording)
        #expect(match(15, [.command, .shift], preferences: preferences) == .extendRecording)
        #expect(match(83, preferences: preferences) == .jump1)

        #expect(match(14, preferences: preferences, editable: true) == nil)
        #expect(match(49, .shift, preferences: preferences, editable: true) == nil)
        #expect(match(6, .command, preferences: preferences, editable: true) == nil)
        #expect(match(51, .command, preferences: preferences, editable: true) == nil)
        #expect(match(15, [.command, .shift], preferences: preferences, editable: true)
                == .extendRecording)
        #expect(match(46, .option, preferences: preferences, editable: true) == .moveNote)
        #expect(match(14, preferences: preferences, capture: true) == nil)

        let move = chord(46, .option)
        #expect(match(
            46, .option, preferences: preferences,
            globals: [move: "Global recording"]
        ) == nil)
    }

    @Test func defaultBindingsAreAllUnambiguousAndActive() {
        let preferences = AppShortcutPreferences.defaults
        let globals = Dictionary(uniqueKeysWithValues:
            GlobalShortcutAction.allCases.compactMap { action in
                (GlobalShortcutPreferences.defaults.bindings[action] ?? nil).map {
                    ($0, action.title)
                }
            }
        )
        let assignedCount = preferences.bindings.values.reduce(0) {
            $0 + $1.orderedChords.count
        }
        #expect(preferences.activeBindings(globalBindings: globals).count == assignedCount)
    }

    @Test func sharedTypesDecodeAndReencodeLegacyGlobalPreferenceJSON() throws {
        let legacy = LegacyGlobalPreferences(
            version: 4,
            isEnabled: false,
            showsMenuBarItem: false,
            showsBackgroundIndicator: true,
            backgroundIndicatorRetention: .fiveMinutes,
            bindings: [
                .toggleRecording: LegacyGlobalChord(
                    keyCode: 12, modifiers: LegacyGlobalModifiers(rawValue: 2)
                ),
                .pauseResumeRecording: nil,
            ]
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let current = try JSONDecoder().decode(
            GlobalShortcutPreferences.self, from: legacyData
        )
        #expect(current.version == 4)
        #expect(!current.isEnabled)
        #expect(!current.showsMenuBarItem)
        #expect(current.showsBackgroundIndicator)
        #expect(current.backgroundIndicatorRetention == .fiveMinutes)
        #expect((current.bindings[.toggleRecording] ?? nil) == chord(12, .option))
        #expect((current.bindings[.pauseResumeRecording] ?? nil) == nil)

        // Enum-keyed dictionaries encode as an alternating JSON array whose
        // element order is intentionally unspecified. Prove wire compatibility
        // by decoding the current encoder's output through the legacy schema
        // instead of comparing that incidental order.
        let legacyRoundTrip = try JSONDecoder().decode(
            LegacyGlobalPreferences.self,
            from: JSONEncoder().encode(current)
        )
        #expect(legacyRoundTrip.version == legacy.version)
        #expect(legacyRoundTrip.isEnabled == legacy.isEnabled)
        #expect(legacyRoundTrip.showsMenuBarItem == legacy.showsMenuBarItem)
        #expect(
            legacyRoundTrip.showsBackgroundIndicator
                == legacy.showsBackgroundIndicator
        )
        #expect(
            legacyRoundTrip.backgroundIndicatorRetention
                == legacy.backgroundIndicatorRetention
        )
        let roundTripToggle = legacyRoundTrip.bindings[.toggleRecording] ?? nil
        let legacyToggle = legacy.bindings[.toggleRecording] ?? nil
        #expect(roundTripToggle?.keyCode == legacyToggle?.keyCode)
        #expect(
            roundTripToggle?.modifiers.rawValue
                == legacyToggle?.modifiers.rawValue
        )
        #expect((legacyRoundTrip.bindings[.pauseResumeRecording] ?? nil) == nil)
    }

    @Test func globalValidationKeepsModifierRuleAndRejectsReservedChords() {
        #expect(chord(15).validation == .requiresNonShiftModifier)
        #expect(chord(15, .shift).validation == .requiresNonShiftModifier)
        guard case .reserved = chord(12, .command).validation else {
            Issue.record("Expected Command-Q to be reserved globally")
            return
        }
        #expect(chord(15, .option).validation == .valid)
    }

    private func chord(
        _ keyCode: UInt32,
        _ modifiers: ShortcutModifiers = []
    ) -> ShortcutChord {
        ShortcutChord(keyCode: keyCode, modifiers: modifiers)
    }

    private func match(
        _ keyCode: UInt16,
        _ modifiers: ShortcutModifiers = [],
        preferences: AppShortcutPreferences,
        globals: [ShortcutChord: String] = [:],
        editable: Bool = false,
        capture: Bool = false
    ) -> AppShortcutAction? {
        AppShortcutMatcher.action(
            forKeyCode: keyCode,
            modifiers: modifiers,
            preferences: preferences,
            globalBindings: globals,
            editableTextHasFocus: editable,
            captureOwnsInput: capture
        )
    }
}

private struct LegacyGlobalModifiers: OptionSet, Codable {
    let rawValue: UInt32
}

private struct LegacyGlobalChord: Codable {
    var keyCode: UInt32
    var modifiers: LegacyGlobalModifiers
}

private struct LegacyGlobalPreferences: Codable {
    var version: Int
    var isEnabled: Bool
    var showsMenuBarItem: Bool
    var showsBackgroundIndicator: Bool
    var backgroundIndicatorRetention: BackgroundIndicatorRetention
    var bindings: [GlobalShortcutAction: LegacyGlobalChord?]
}
