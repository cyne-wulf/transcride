import SwiftUI

/// The complete Transcride-owned menu catalog. Menu clicks and key events both
/// enter AppModel's shared dispatcher and use the same availability decision.
/// Native App/Edit/Window items and Debug testing commands remain outside the
/// remappable catalog by design.
struct AppCommands: Commands {
    let model: AppModel

    private var ready: Bool { model.phase == .ready }

    var body: some Commands {
        fileCommands
        undoRedoCommands
        editCommands
        entryCommands
        playbackCommands
        viewCommands
#if DEBUG
        testingCommands
#endif
    }

    // MARK: - Shared menu presentation

    private func commandButton(
        _ action: AppShortcutAction,
        title: String? = nil
    ) -> some View {
        let resolvedTitle = title ?? action.title
        return Button(
            AppShortcutMenu.title(resolvedTitle, action: action, model: model)
        ) {
            model.performAppCommand(action)
        }
        .appShortcutMenu(action, model: model)
        .disabled(!model.isAppCommandEnabled(action))
    }

    private func commandToggle(
        _ action: AppShortcutAction,
        title: String,
        isOn: Bool
    ) -> some View {
        Toggle(
            AppShortcutMenu.title(title, action: action, model: model),
            isOn: Binding(
                get: { isOn },
                set: { _ in model.performAppCommand(action) }
            )
        )
        .appShortcutMenu(action, model: model)
        .disabled(!model.isAppCommandEnabled(action))
    }

    private func editorCommandButton(
        _ title: String,
        action: AppModel.EditorCommandAction,
        enabled: Bool
    ) -> some View {
        Button(title) {
            model.requestWorkbenchAction(.editorCommand(action))
        }
        .disabled(!enabled)
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

    // MARK: - File

    /// Replacing `.newItem` also removes SwiftUI's default New Window item:
    /// Transcride is a one-window app and New Recording owns this command.
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            commandButton(.newRecording)
            commandButton(
                .toggleRecording,
                title: model.recorder.isActive ? "Stop Recording" : "Start Recording"
            )

            Divider()

            commandButton(.importAudio)
            commandButton(.newFolder)

            Divider()

            commandButton(.exportMarkdown)
            commandButton(.shareAudio)
            if model.vaultHasObsidianConfig {
                commandButton(.openInObsidian)
            }
        }
    }

    // MARK: - Edit → Find

    private var undoRedoCommands: some Commands {
        CommandGroup(replacing: .undoRedo) {
            commandButton(
                .undoClipEdit,
                title: model.editorInputOwnsInput ? "Undo Editor Change" : "Undo Clip Edit"
            )
            commandButton(
                .redoClipEdit,
                title: model.editorInputOwnsInput ? "Redo Editor Change" : "Redo Clip Edit"
            )
        }
    }

    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                commandButton(.findInNote)
                editorCommandButton(
                    "Replace…",
                    action: .replace,
                    enabled: model.workbenchUIState.editorCanReplace
                )
                .keyboardShortcut("f", modifiers: [.command, .option])
                commandButton(.searchVault)
            }

            Menu("Markdown Formatting") {
                editorCommandButton(
                    "Bold",
                    action: .bold,
                    enabled: model.workbenchUIState.editorCanReplace
                )
                .keyboardShortcut("b", modifiers: .command)
                editorCommandButton(
                    "Italic",
                    action: .italic,
                    enabled: model.workbenchUIState.editorCanReplace
                )
                .keyboardShortcut("i", modifiers: .command)
                editorCommandButton(
                    "Link",
                    action: .link,
                    enabled: model.workbenchUIState.editorCanReplace
                )
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }

    // MARK: - Entry

    private var entryCommands: some Commands {
        CommandMenu("Entry") {
            commandButton(
                .toggleFavorite,
                title: model.selectedEntry?.favorite == true ? "Unfavorite" : "Favorite"
            )
            commandButton(.renameEntry)
            commandButton(.duplicateEntry)
            commandButton(.moveNote)
            commandButton(.moveToRecentlyDeleted)

            Divider()

            commandButton(
                .extendRecording,
                title: model.recorder.extensionSession == nil
                    ? "Extend Recording" : "Finish Extension"
            )
            commandButton(
                .editOrSaveNote,
                title: model.workbenchUIState.isEditing ? "Save Note" : "Edit Note"
            )
            commandButton(.copyMarkdown)
            commandButton(
                .toggleTranscriptLayer,
                title: model.workbenchUIState.viewedLayerIsOriginal
                    ? "Show Edited Layer" : "Show Original Layer"
            )

            Divider()

            commandButton(.retranscribe)
            commandButton(
                .trimAudio,
                title: model.trimModeActive ? "Cancel Trim" : "Trim Audio…"
            )
            commandButton(.replaceAudio)
            commandButton(.compressAudio)
            commandButton(.restoreOriginalAudio)

            if model.workbenchUIState.hasDetectedSpeakers {
                commandToggle(
                    .toggleSpeakerDetection,
                    title: "Detect Speakers",
                    isOn: model.workbenchUIState.speakerDetectionEnabled
                )
            }
            commandButton(.renameSpeakers)
            commandButton(.deleteAudio)

            Divider()

            commandButton(.showInfo)
            commandButton(.revealInFinder)
        }
    }

    // MARK: - Playback

    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            commandButton(
                .togglePausePlayback,
                title: pausePlaybackTitle
            )
            commandButton(
                .skipBackward,
                title: "Back \(model.player.skipIntervalMenuLabel)"
            )
            commandButton(
                .skipForward,
                title: "Forward \(model.player.skipIntervalMenuLabel)"
            )

            Menu("Jump To") {
                commandButton(.jump0)
                commandButton(.jump1)
                commandButton(.jump2)
                commandButton(.jump3)
                commandButton(.jump4)
                commandButton(.jump5)
                commandButton(.jump6)
                commandButton(.jump7)
                commandButton(.jump8)
                commandButton(.jump9)
            }

            Divider()

            commandButton(.decreasePlaybackSpeed)
            commandButton(.increasePlaybackSpeed)
            commandButton(.resetPlaybackSpeed)

            Divider()

            commandToggle(
                .toggleSkipSilence,
                title: "Skip Silence",
                isOn: model.player.skipSilence
            )
            commandButton(.enterZenMode)
        }
    }

    private var pausePlaybackTitle: String {
        switch model.recorder.state {
        case .recording: "Pause Recording"
        case .paused: "Resume Recording"
        case .idle: model.player.isPlaying ? "Pause Playback" : "Play"
        case .finalizing: "Pause / Resume"
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(before: .sidebar) {
            Menu("Editor") {
                Button("Increase Font Size") {
                    var preferences = model.editorPreferences
                    preferences.stepFontSize(by: 1)
                    model.updateEditorPreferences(preferences)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.editorPreferences.fontSize >= EditorPreferences.maximumFontSize)

                Button("Decrease Font Size") {
                    var preferences = model.editorPreferences
                    preferences.stepFontSize(by: -1)
                    model.updateEditorPreferences(preferences)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.editorPreferences.fontSize <= EditorPreferences.minimumFontSize)

                Button("Actual Font Size") {
                    var preferences = model.editorPreferences
                    preferences.fontSize = EditorPreferences.defaultFontSize
                    model.updateEditorPreferences(preferences)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Menu("Editor Width") {
                    ForEach(EditorWidthPreset.allCases) { width in
                        Toggle(width.title, isOn: Binding(
                            get: { model.editorPreferences.width == width },
                            set: { enabled in
                                guard enabled else { return }
                                var preferences = model.editorPreferences
                                preferences.width = width
                                model.updateEditorPreferences(preferences)
                            }
                        ))
                    }
                }

                Toggle("Center Edited Prose", isOn: Binding(
                    get: { model.editorPreferences.editedAlignment == .center },
                    set: { centered in
                        var preferences = model.editorPreferences
                        preferences.editedAlignment = centered ? .center : .left
                        model.updateEditorPreferences(preferences)
                    }
                ))
                Toggle("Focus Mode", isOn: Binding(
                    get: { model.editorPreferences.focusMode },
                    set: { enabled in
                        var preferences = model.editorPreferences
                        preferences.focusMode = enabled
                        model.updateEditorPreferences(preferences)
                    }
                ))
            }

            Divider()

            commandButton(.previousFolder)
            commandButton(.nextFolder)

            Divider()

            Menu("Sort Entries By") {
                commandButton(.sortByDate)
                commandButton(.sortByDuration)
                commandButton(.sortByTitle)
                commandButton(.sortByRecentlyEdited)
            }

            Divider()

            commandButton(.goToVaultRoot)
            commandButton(.goToFavorites)
            commandButton(.goToRecentlyDeleted)

            Divider()

            commandButton(.showTranscriptionQueue)
        }
    }
}
