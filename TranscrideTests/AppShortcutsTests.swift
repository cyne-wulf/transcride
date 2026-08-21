import Foundation
import Testing

@Suite("App shortcut catalog, preferences, and matching")
struct AppShortcutsTests {
    // MARK: - Catalog

    @Test func actionIDsAreUniqueAndStable() {
        let ids = AppShortcutAction.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        // Persistence IDs must never drift; spot-check load-bearing ones.
        #expect(AppShortcutAction.moveNote.rawValue == "moveNote")
        #expect(AppShortcutAction.extendRecording.rawValue == "extendRecording")
        #expect(AppShortcutAction.moveToRecentlyDeleted.rawValue == "moveToRecentlyDeleted")
        #expect(AppShortcutAction.clipUndo.rawValue == "clipUndo")
    }

    @Test func catalogCoversEveryTranscrideCommandGroup() {
        let byCategory = Dictionary(grouping: AppShortcutAction.allCases, by: \.category)
        #expect(byCategory[.recordingFile]?.count == 5)
        #expect(byCategory[.notesEntry]?.count == 21)
        #expect(byCategory[.playback]?.count == 19)
        #expect(byCategory[.libraryView]?.count == 13)
        #expect(byCategory[.appHelp]?.count == 2)
        for action in AppShortcutAction.allCases {
            #expect(!action.title.isEmpty)
        }
    }

    @Test func defaultsPreserveEveryExistingBinding() {
        let prefs = AppShortcutPreferences.defaults

        // Move Note is the one new default: ⌥M.
        #expect(prefs.chord(for: .moveNote) == ShortcutChord(keyCode: 46, modifiers: [.option]))
        #expect(prefs.chord(for: .moveNote)?.glyphDescription == "⌥M")

        // E / ⌘⇧R for Extend, ⌘⌫ / ⇧⌫ for Recently Deleted.
        #expect(prefs.chord(for: .extendRecording, slot: .primary)
                == ShortcutChord(keyCode: 14, modifiers: []))
        #expect(prefs.chord(for: .extendRecording, slot: .alternate)
                == ShortcutChord(keyCode: 15, modifiers: [.command, .shift]))
        #expect(prefs.chord(for: .moveToRecentlyDeleted, slot: .primary)
                == ShortcutChord(keyCode: 51, modifiers: [.command]))
        #expect(prefs.chord(for: .moveToRecentlyDeleted, slot: .alternate)
                == ShortcutChord(keyCode: 51, modifiers: [.shift]))

        // Long-standing chords stay put.
        #expect(prefs.chord(for: .newRecording)?.glyphDescription == "⌘N")
        #expect(prefs.chord(for: .startStopRecording)?.glyphDescription == "⇧Space")
        #expect(prefs.chord(for: .pauseOrPlaybackToggle)?.glyphDescription == "Space")
        #expect(prefs.chord(for: .editOrSaveNote)?.glyphDescription == "⌘E")
        #expect(prefs.chord(for: .copyAsMarkdown)?.glyphDescription == "⇧⌘C")
        #expect(prefs.chord(for: .trimAudio)?.glyphDescription == "T")
        #expect(prefs.chord(for: .replaceAudio)?.glyphDescription == "R")
        #expect(prefs.chord(for: .toggleSkipSilence)?.glyphDescription == "S")
        #expect(prefs.chord(for: .enterZenMode)?.glyphDescription == "Z")
        #expect(prefs.chord(for: .clipUndo)?.glyphDescription == "⌘Z")
        #expect(prefs.chord(for: .clipRedo)?.glyphDescription == "⇧⌘Z")
        #expect(prefs.chord(for: .findInNote)?.glyphDescription == "⌘F")
        #expect(prefs.chord(for: .searchVault)?.glyphDescription == "⇧⌘F")
        #expect(prefs.chord(for: .previousFolder)?.glyphDescription == "⌥↑")
        #expect(prefs.chord(for: .nextFolder)?.glyphDescription == "⌥↓")

        // Previously unbound commands stay unbound.
        for action: AppShortcutAction in [
            .renameEntry, .duplicateEntry, .toggleLayer, .retranscribe,
            .compressAudio, .restoreOriginalAudio, .renameSpeakers, .deleteAudio,
            .revealInFinder, .shareAudio, .openInObsidian,
            .sortByDate, .sortByDuration, .sortByTitle, .sortByRecentlyEdited,
            .goToVaultRoot, .goToFavorites, .goToRecentlyDeleted,
            .showTranscriptionQueue, .showAbout,
        ] {
            #expect(prefs.binding(for: action).chords.isEmpty, "\(action) should be unbound")
        }
    }

    @Test func defaultChordsNeverCollideLocallyOrWithGlobalDefaults() {
        var seen: Set<ShortcutChord> = []
        for action in AppShortcutAction.allCases {
            for chord in action.defaultBinding.chords {
                #expect(seen.insert(chord).inserted, "duplicate default: \(chord.glyphDescription)")
            }
        }
        #expect(!seen.contains(.defaultToggleRecording))
        #expect(!seen.contains(.defaultPauseResume))
    }

    @Test func defaultChordsAllReportActiveStatus() {
        let prefs = AppShortcutPreferences.defaults
        let globals = GlobalShortcutPreferences.defaults.bindings.values.compactMap { $0 }
        for action in AppShortcutAction.allCases {
            for slot in AppShortcutSlot.allCases
            where prefs.chord(for: action, slot: slot) != nil {
                #expect(
                    prefs.status(for: action, slot: slot, globalChords: globals) == .active,
                    "\(action)/\(slot) default should be active"
                )
            }
        }
    }

    // MARK: - Persistence

    @Test func preferencesRoundTrip() throws {
        var prefs = AppShortcutPreferences.defaults
        prefs.bindings[.moveNote] = AppShortcutBinding(
            primary: ShortcutChord(keyCode: 11, modifiers: [.command, .option])
        )
        prefs.bindings[.trimAudio] = AppShortcutBinding() // explicitly cleared
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppShortcutPreferences.self, from: data)
        #expect(decoded == prefs)
        #expect(decoded.binding(for: .trimAudio).chords.isEmpty)
    }

    @Test func decodingDropsUnknownActionsAndFillsMissingWithDefaults() throws {
        // A payload from a hypothetical newer build: one unknown action, and
        // most known actions missing entirely.
        let payload = """
        {"version":1,"bindings":{"someFutureAction":{"primary":{"keyCode":5,"modifiers":1}},\
        "moveNote":{"primary":{"keyCode":11,"modifiers":3}}}}
        """
        let decoded = try JSONDecoder().decode(
            AppShortcutPreferences.self, from: Data(payload.utf8)
        )
        #expect(decoded.chord(for: .moveNote)
                == ShortcutChord(keyCode: 11, modifiers: [.command, .option]))
        // Missing actions get their defaults.
        #expect(decoded.binding(for: .extendRecording) == AppShortcutAction.extendRecording.defaultBinding)
        #expect(decoded.bindings.count == AppShortcutAction.allCases.count)
    }

    @Test func storeLoadsSavesAndResets() throws {
        let suiteName = "AppShortcutsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == .defaults)

        var changed = AppShortcutPreferences.defaults
        changed.bindings[.moveNote] = AppShortcutBinding(
            primary: ShortcutChord(keyCode: 11, modifiers: [.option])
        )
        AppShortcutPreferencesStore.save(changed, defaults: defaults)
        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == changed)

        AppShortcutPreferencesStore.save(.defaults, defaults: defaults)
        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == .defaults)
    }

    @Test func corruptedStorePayloadFallsBackToDefaults() throws {
        let suiteName = "AppShortcutsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: AppShortcutPreferencesStore.defaultsKey)
        #expect(AppShortcutPreferencesStore.load(defaults: defaults) == .defaults)
    }

    // MARK: - Validation

    @Test func validationAcceptsBareLocalKeys() {
        let prefs = AppShortcutPreferences.defaults
        let bareY = ShortcutChord(keyCode: 16, modifiers: [])
        #expect(prefs.validation(settingChord: bareY, for: .showAbout, slot: .primary) == .valid)
    }

    @Test func validationRejectsModifierOnlyChords() {
        let prefs = AppShortcutPreferences.defaults
        let modifierOnly = ShortcutChord(
            keyCode: ShortcutChord.modifierOnlyKeyCode, modifiers: [.command]
        )
        #expect(prefs.validation(
            settingChord: modifierOnly, for: .moveNote, slot: .primary
        ) == .modifierOnly)
    }

    @Test func validationRejectsReservedNativeKeys() {
        let prefs = AppShortcutPreferences.defaults
        let reserved: [ShortcutChord] = [
            ShortcutChord(keyCode: 36, modifiers: []),            // Return
            ShortcutChord(keyCode: 36, modifiers: [.command]),    // ⌘Return still structural
            ShortcutChord(keyCode: 48, modifiers: []),            // Tab
            ShortcutChord(keyCode: 53, modifiers: []),            // Escape
            ShortcutChord(keyCode: 51, modifiers: []),            // bare Delete
            ShortcutChord(keyCode: 125, modifiers: []),           // plain ↓
            ShortcutChord(keyCode: 126, modifiers: [.shift]),     // ⇧↑ still list-owned
            ShortcutChord(keyCode: 12, modifiers: [.command]),    // ⌘Q
            ShortcutChord(keyCode: 8, modifiers: [.command]),     // ⌘C
            ShortcutChord(keyCode: 43, modifiers: [.command]),    // ⌘,
        ]
        for chord in reserved {
            let result = prefs.validation(settingChord: chord, for: .showAbout, slot: .primary)
            guard case .reserved = result else {
                Issue.record("\(chord.glyphDescription) should be reserved, got \(result)")
                continue
            }
        }
        // Modified arrows and deletes remain assignable.
        #expect(AppShortcutReservedKeys.reservedReason(
            for: ShortcutChord(keyCode: 126, modifiers: [.option])
        ) == nil)
        #expect(AppShortcutReservedKeys.reservedReason(
            for: ShortcutChord(keyCode: 51, modifiers: [.shift])
        ) == nil)
    }

    @Test func validationRejectsLocalDuplicates() {
        let prefs = AppShortcutPreferences.defaults
        // ⌘E belongs to Edit/Save Note.
        let commandE = ShortcutChord(keyCode: 14, modifiers: [.command])
        #expect(prefs.validation(
            settingChord: commandE, for: .moveNote, slot: .primary
        ) == .duplicate(.editOrSaveNote))
        // Re-recording the same chord into its own slot is fine.
        #expect(prefs.validation(
            settingChord: commandE, for: .editOrSaveNote, slot: .primary
        ) == .valid)
        // Primary and alternate of one action may not collide either.
        #expect(prefs.validation(
            settingChord: commandE, for: .editOrSaveNote, slot: .alternate
        ) == .duplicate(.editOrSaveNote))
    }

    @Test func validationRejectsGlobalConflicts() {
        let prefs = AppShortcutPreferences.defaults
        let globals = GlobalShortcutPreferences.defaults.bindings
        #expect(prefs.validation(
            settingChord: .defaultToggleRecording,
            for: .moveNote, slot: .primary,
            globalBindings: globals
        ) == .conflictsWithGlobal(.toggleRecording))
        #expect(prefs.validation(
            settingChord: ShortcutChord(keyCode: 11, modifiers: [.option]),
            for: .moveNote, slot: .primary,
            globalBindings: globals
        ) == .valid)
    }

    @Test func persistedConflictsAreDisabledAndFlagged() {
        var prefs = AppShortcutPreferences.defaults
        // A local binding that now equals a global chord: global wins.
        prefs.bindings[.moveNote] = AppShortcutBinding(primary: .defaultToggleRecording)
        #expect(prefs.status(
            for: .moveNote, slot: .primary, globalChords: [.defaultToggleRecording]
        ) == .disabled("Disabled: the global shortcut ⌥R takes precedence."))

        // Corrupted persistence: two actions sharing one chord disable both.
        let chord = ShortcutChord(keyCode: 11, modifiers: [.command])
        prefs.bindings[.renameEntry] = AppShortcutBinding(primary: chord)
        prefs.bindings[.duplicateEntry] = AppShortcutBinding(primary: chord)
        guard case .disabled? = prefs.status(for: .renameEntry, slot: .primary),
              case .disabled? = prefs.status(for: .duplicateEntry, slot: .primary) else {
            Issue.record("ambiguous persisted bindings must be disabled")
            return
        }

        // Unbound slots have no status; healthy bindings are active.
        #expect(prefs.status(for: .showAbout, slot: .primary) == nil)
        #expect(prefs.status(for: .editOrSaveNote, slot: .primary) == .active)
    }

    // MARK: - Modifier normalization

    @Test func cocoaFlagNormalizationKeepsRealModifiersAndDropsImplicitOnes() {
        let command: UInt = 1 << 20
        let option: UInt = 1 << 19
        let control: UInt = 1 << 18
        let shift: UInt = 1 << 17
        let numericPad: UInt = 1 << 21
        let function: UInt = 1 << 23

        #expect(ShortcutModifiers(cocoaFlags: command | shift) == [.command, .shift])
        #expect(ShortcutModifiers(cocoaFlags: option | control) == [.option, .control])
        #expect(ShortcutModifiers(cocoaFlags: numericPad | function) == [])
        #expect(ShortcutModifiers(cocoaFlags: option | numericPad | function) == [.option])
    }

    // MARK: - Event matching

    private let defaults = AppShortcutPreferences.defaults

    @Test func matcherResolvesPrimaryAndAlternateBindings() {
        // E (primary) and ⌘⇧R (alternate) both reach Extend Recording.
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 14, modifiers: [], isTextEditing: false, preferences: defaults
        ) == .extendRecording)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 15, modifiers: [.command, .shift], isTextEditing: false,
            preferences: defaults
        ) == .extendRecording)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 46, modifiers: [.option], isTextEditing: false, preferences: defaults
        ) == .moveNote)
        // Keypad digit alternate.
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 87, modifiers: [], isTextEditing: false, preferences: defaults
        ) == .playbackJump5)
        // Unbound chord matches nothing.
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 16, modifiers: [.command, .option], isTextEditing: false,
            preferences: defaults
        ) == nil)
    }

    @Test func bareKeysNeverFireWhileTextIsEditing() {
        for (keyCode, modifiers): (UInt16, ShortcutModifiers) in [
            (14, []), (15, []), (17, []), (1, []), (6, []), (49, []), (49, [.shift]),
        ] {
            #expect(AppShortcutEventMatcher.action(
                forKeyCode: keyCode, modifiers: modifiers, isTextEditing: true,
                preferences: defaults
            ) == nil)
        }
        // Modified chords still fire while editing…
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 3, modifiers: [.command], isTextEditing: true, preferences: defaults
        ) == .findInNote)
    }

    @Test func undoRedoDeleteAndFolderNavigationDeferToTextEditingEvenThoughModified() {
        // ⌘Z/⌘⇧Z, ⌘⌫/⇧⌫, and ⌥↑/⌥↓ (paragraph navigation) stay with text.
        for (keyCode, modifiers): (UInt16, ShortcutModifiers) in [
            (6, [.command]), (6, [.command, .shift]), (51, [.command]), (51, [.shift]),
            (126, [.option]), (125, [.option]),
        ] {
            #expect(AppShortcutEventMatcher.action(
                forKeyCode: keyCode, modifiers: modifiers, isTextEditing: true,
                preferences: defaults
            ) == nil)
            #expect(AppShortcutEventMatcher.action(
                forKeyCode: keyCode, modifiers: modifiers, isTextEditing: false,
                preferences: defaults
            ) != nil)
        }
    }

    @Test func globalChordsOutrankLocalBindings() {
        var prefs = AppShortcutPreferences.defaults
        prefs.bindings[.moveNote] = AppShortcutBinding(primary: .defaultToggleRecording)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 15, modifiers: [.option], isTextEditing: false,
            preferences: prefs, globalChords: [.defaultToggleRecording]
        ) == nil)
        // Without the global registration the local binding resolves.
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 15, modifiers: [.option], isTextEditing: false,
            preferences: prefs
        ) == .moveNote)
    }

    @Test func ambiguousPersistedChordsNeverDispatch() {
        var prefs = AppShortcutPreferences.defaults
        let chord = ShortcutChord(keyCode: 11, modifiers: [.command])
        prefs.bindings[.renameEntry] = AppShortcutBinding(primary: chord)
        prefs.bindings[.duplicateEntry] = AppShortcutBinding(primary: chord)
        #expect(AppShortcutEventMatcher.action(
            forKeyCode: 11, modifiers: [.command], isTextEditing: false, preferences: prefs
        ) == nil)
    }

    @Test func glyphsFollowMacOSModifierOrder() {
        let chord = ShortcutChord(keyCode: 46, modifiers: [.command, .option, .control, .shift])
        #expect(chord.glyphDescription == "⌃⌥⇧⌘M")
        #expect(ShortcutChord(keyCode: 44, modifiers: [.command, .shift]).glyphDescription == "⇧⌘/")
    }
}
