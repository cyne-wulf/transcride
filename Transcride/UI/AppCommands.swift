import SwiftUI

/// The full menu bar (master PRD §7: "a menu bar with everything reachable").
/// Every item routes through the same AppModel intents as the in-window
/// controls; sheets and prompts owned by views are reached via the request
/// pattern (`requestEntryAction` & friends).
///
/// Monitor-owned shortcuts (Space, Z, `[`, `]`, `\`, ⇧⌫, ⌘⌫) stay in AppModel's key
/// monitor — giving menu items those key equivalents would fire them while
/// the monitor deliberately defers to text editing. Their menu items carry no
/// equivalent; the Help → Keyboard Shortcuts window documents the keys.
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
    }

    // MARK: - File

    /// Replacing `.newItem` also drops SwiftUI's default "New Window ⌘N":
    /// Transcride is a one-window app and ⌘N belongs to New Recording (§7).
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                Task { await model.startRecording() }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!ready || model.recorder.isActive || model.recorder.state == .finalizing)

            Button(model.recorder.isActive ? "Stop Recording" : "Start Recording") {
                Task {
                    if model.recorder.isActive {
                        await model.stopRecording()
                    } else {
                        await model.startRecording()
                    }
                }
            }
            .keyboardShortcut(.space, modifiers: [.shift])
            .disabled(!ready || model.recorder.state == .finalizing)

            Button(model.recorder.state == .paused ? "Resume Recording" : "Pause Recording") {
                if model.recorder.state == .paused {
                    model.recorder.resume()
                } else {
                    model.recorder.pause()
                }
            }
            .disabled(model.recorder.state != .recording && model.recorder.state != .paused)

            Divider()

            Button("Import Audio…") {
                model.importViaPanel()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!ready)

            Button("New Folder…") {
                model.requestNewFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!ready)

            Divider()

            Button("Export Markdown…") {
                model.requestEntryAction(.exportMarkdown)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(entry?.hasTranscript != true)

            Button("Share Audio…") {
                if let entry { model.shareAudioFromMenu(for: entry) }
            }
            .disabled(entry?.hasAudio != true)

            if model.vaultHasObsidianConfig {
                Button("Open in Obsidian") {
                    if let entry { model.openInObsidian(entry: entry) }
                }
                .disabled(entry?.hasTranscript != true)
            }
        }
    }

    // MARK: - Edit → Find

    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find in Note…") {
                    model.requestInNoteFind()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!ready || entry == nil || model.isVaultSearchPresented)

                Button("Search Vault…") {
                    model.presentVaultSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!ready)
            }
        }
    }

    // MARK: - Entry

    private var entryCommands: some Commands {
        CommandMenu("Entry") {
            Button(entry?.favorite == true ? "Unfavorite" : "Favorite") {
                if let entry { Task { await model.toggleFavorite(for: entry) } }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(entry == nil)

            Button("Rename…") {
                model.requestRenameEntry()
            }
            .disabled(entry == nil)

            Button("Duplicate Entry") {
                if let entry { Task { await model.duplicateEntry(entry) } }
            }
            .disabled(entry == nil)

            // ⇧⌫ and ⌘⌫ live in the key monitor (they must defer to text editing).
            Button("Move to Recently Deleted") {
                if let entry {
                    Task { await model.deleteItem(atRelativePath: entry.relativePath) }
                }
            }
            .disabled(entry == nil || model.recorder.currentEntryPath == entry?.relativePath)

            Divider()

            Button(model.workbenchUIState.isEditing ? "Save Note" : "Edit Note") {
                model.requestWorkbenchAction(.editOrSave)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.workbenchUIState.canEditNote && !model.workbenchUIState.isEditing)

            Button("Copy as Markdown") {
                model.requestWorkbenchAction(.copyAsMarkdown)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.workbenchUIState.hasContent)

            Button(model.workbenchUIState.viewedLayerIsOriginal
                   ? "Show Edited Layer" : "Show Original Layer") {
                model.requestWorkbenchAction(.toggleLayer)
            }
            .disabled(!model.workbenchUIState.isForked || model.workbenchUIState.isEditing)

            Divider()

            Button("Retranscribe…") {
                model.requestEntryAction(.retranscribe)
            }
            .disabled(entry?.hasAudio != true)

            Button("Trim Audio…") {
                model.requestEntryAction(.trim)
            }
            .disabled(entry?.hasAudio != true)

            Button("Restore Original Audio…") {
                model.requestEntryAction(.restoreOriginalAudio)
            }
            .disabled(entry.map { model.originalAudioTrashItem(for: $0) == nil } ?? true)

            Button("Rename Speakers…") {
                model.requestWorkbenchAction(.renameSpeakers)
            }
            .disabled(!model.workbenchUIState.hasSpeakers || model.workbenchUIState.isEditing)

            Button("Delete Audio…") {
                model.requestEntryAction(.deleteAudio)
            }
            .disabled(entry?.hasAudio != true
                      || model.recorder.currentEntryPath == entry?.relativePath)

            Divider()

            Button("Show Info") {
                model.requestEntryAction(.showInfo)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(entry == nil)

            Button("Reveal in Finder") {
                if let entry { model.revealInFinder(relativePath: entry.relativePath) }
            }
            .disabled(entry == nil)
        }
    }

    // MARK: - Playback

    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            // Space, Left/Right Arrow, [, ], and \ are key-monitor shortcuts
            // (see header note).
            Button(model.player.isPlaying ? "Pause" : "Play") {
                model.player.togglePlayPause()
            }
            .disabled(model.player.url == nil)

            Button("Back 15 Seconds") {
                model.player.skip(-15)
            }
            .disabled(model.player.url == nil)

            Button("Forward 15 Seconds") {
                model.player.skip(15)
            }
            .disabled(model.player.url == nil)

            Divider()

            Button("Slower") {
                model.player.stepSpeed(-1)
            }
            .disabled(model.player.url == nil)

            Button("Faster") {
                model.player.stepSpeed(1)
            }
            .disabled(model.player.url == nil)

            Button("Normal Speed") {
                model.player.speed = 1.0
            }
            .disabled(model.player.url == nil)

            Divider()

            Toggle("Skip Silence", isOn: Binding(
                get: { model.player.skipSilence },
                set: { model.player.skipSilence = $0 }
            ))

            Divider()

            Button("Enter Zen Mode") {
                model.recorder.isZenMode = true
            }
            .disabled(!ready || model.recorder.isZenMode)
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

            Button("Go to Vault Root") {
                model.sidebarSelection = .folder("")
            }
            .disabled(!ready)

            Button("Go to Favorites") {
                model.sidebarSelection = .favorites
            }
            .disabled(!ready)

            Button("Go to Recently Deleted") {
                model.sidebarSelection = .recentlyDeleted
            }
            .disabled(!ready)

            Divider()

            Button("Transcription Queue") {
                model.requestQueuePopover()
            }
            .disabled(!ready)
        }
    }
}
