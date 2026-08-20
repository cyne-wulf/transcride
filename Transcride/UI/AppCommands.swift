import SwiftUI

/// The full menu bar (master PRD §7: "a menu bar with everything reachable").
/// Every item routes through `AppModel.performAppCommand`/`isAppCommandEnabled`
/// — the same dispatcher and availability calculation the app-wide key monitor
/// uses — so menus, shortcuts, and in-window controls can never drift apart.
///
/// Key equivalents come from the live App Shortcuts preferences. Bare and
/// focus-sensitive chords (Space, E, T, ⌘Z, ⌘⌫, …) stay monitor-owned: their
/// menu items carry no equivalent so a menu can never steal typing keys; the
/// Help → Keyboard Shortcuts window documents them.
struct AppCommands: Commands {
    let model: AppModel

    private var entry: Entry? { model.selectedEntry }
    private var ready: Bool { model.phase == .ready }

    var body: some Commands {
        fileCommands
        editCommands
        entryCommands
        playbackCommands
        viewCommands
#if DEBUG
        testingCommands
#endif
    }

#if DEBUG
    private var testingCommands: some Commands {
        CommandMenu("Testing") {
            Button("Force Next Extension Composition Failure") {
                AudioExtensionFailureInjector.shared.arm(.beforeComposition)
            }
            .disabled(!ready)

            Button("Force Next Extension Safe-Swap Failure") {
                AudioExtensionFailureInjector.shared.arm(.beforeSafeSwap)
            }
            .disabled(!ready)

            Button("Force Next Post-Swap Recovery") {
                AudioExtensionFailureInjector.shared.arm(.afterSafeSwap)
            }
            .disabled(!ready)

            Divider()

            Button("Force Next Replacement Render Failure") {
                model.armNextReplacementFailure(.beforeRender)
            }
            .disabled(!ready)

            Button("Force Next Replacement Safe-Swap Failure") {
                model.armNextReplacementFailure(.beforeSafeSwap)
            }
            .disabled(!ready)
        }
    }
#endif

    private func commandButton(
        _ title: String, _ action: AppShortcutAction
    ) -> some View {
        Button(title) {
            model.performAppCommand(action)
        }
        .keyboardShortcut(model.menuShortcut(for: action))
        .disabled(!model.isAppCommandEnabled(action))
    }

    // MARK: - File

    /// Replacing `.newItem` also drops SwiftUI's default "New Window ⌘N":
    /// Transcride is a one-window app and ⌘N belongs to New Recording (§7).
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            commandButton("New Recording", .newRecording)

            commandButton(
                (model.isRecordingStartInFlight || model.recorder.isStartingMicrophone)
                    ? "Starting Microphone…"
                    : (model.recorder.isActive ? "Stop Recording" : "Start Recording"),
                .startStopRecording
            )

            Button(model.recorder.state == .paused ? "Resume Recording" : "Pause Recording") {
                model.performAppCommand(.pauseOrPlaybackToggle)
            }
            .disabled(
                (model.recorder.state != .recording && model.recorder.state != .paused) ||
                    (model.recorder.state == .paused && !model.recorder.canResume)
            )

            Divider()

            commandButton("Import Audio…", .importAudio)
            commandButton("New Folder…", .newFolder)

            Divider()

            commandButton("Export Markdown…", .exportMarkdown)
            commandButton("Share Audio…", .shareAudio)

            if model.vaultHasObsidianConfig {
                commandButton("Open in Obsidian", .openInObsidian)
            }
        }
    }

    // MARK: - Edit → Find

    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                commandButton("Find in Note…", .findInNote)
                commandButton("Search Vault…", .searchVault)
            }
        }
    }

    // MARK: - Entry

    private var entryCommands: some Commands {
        CommandMenu("Entry") {
            commandButton(
                entry?.favorite == true ? "Unfavorite" : "Favorite",
                .toggleFavorite
            )
            commandButton("Rename…", .renameEntry)
            commandButton("Duplicate Entry", .duplicateEntry)
            commandButton("Move Note…", .moveNote)

            // ⌘⌫/⇧⌫ live in the key monitor (they must defer to text editing).
            commandButton("Move to Recently Deleted", .moveToRecentlyDeleted)

            Divider()

            commandButton("Extend Recording", .extendRecording)
            commandButton(
                model.workbenchUIState.isEditing ? "Save Note" : "Edit Note",
                .editOrSaveNote
            )
            commandButton("Copy as Markdown", .copyAsMarkdown)
            commandButton(
                model.workbenchUIState.viewedLayerIsOriginal
                    ? "Show Edited Layer" : "Show Original Layer",
                .toggleLayer
            )

            Divider()

            commandButton("Retranscribe…", .retranscribe)
            commandButton("Trim Audio…", .trimAudio)
            commandButton("Compress Audio…", .compressAudio)
            commandButton("Restore Original Audio…", .restoreOriginalAudio)
            commandButton("Rename Speakers…", .renameSpeakers)
            commandButton("Delete Audio…", .deleteAudio)

            Divider()

            commandButton("Show Info", .showInfo)
            commandButton("Reveal in Finder", .revealInFinder)
        }
    }

    // MARK: - Playback

    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            // Space, arrows, digits, [, ], and \ are monitor-owned bare keys
            // (see header note); their items carry no key equivalent.
            // Play/Pause drives the player directly: the recording-aware
            // pauseOrPlaybackToggle command would pause an active recording,
            // but this menu item is playback-only.
            Button(model.player.isPlaying ? "Pause" : "Play") {
                model.player.togglePlayPause()
            }
            .disabled(model.player.url == nil)

            commandButton("Back \(model.player.skipIntervalMenuLabel)", .skipBack)
            commandButton("Forward \(model.player.skipIntervalMenuLabel)", .skipForward)

            Divider()

            commandButton("Slower", .speedDown)
            commandButton("Faster", .speedUp)
            commandButton("Normal Speed", .speedReset)

            Divider()

            Toggle("Skip Silence", isOn: Binding(
                get: { model.player.skipSilence },
                set: { model.player.skipSilence = $0 }
            ))

            Divider()

            commandButton("Enter Zen Mode", .enterZenMode)
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(before: .sidebar) {
            Picker("Sort Entries By", selection: Binding(
                get: { model.entrySortOrder },
                set: { model.selectEntrySortOrder($0) }
            )) {
                ForEach(EntrySortOrder.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .disabled(!ready)

            Divider()

            commandButton("Go to Vault Root", .goToVaultRoot)
            commandButton("Go to Favorites", .goToFavorites)
            commandButton("Go to Recently Deleted", .goToRecentlyDeleted)

            Divider()

            commandButton("Transcription Queue", .showTranscriptionQueue)
        }
    }
}
