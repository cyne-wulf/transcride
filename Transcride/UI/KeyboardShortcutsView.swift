import SwiftUI

/// In-app reference reached from Help → Keyboard Shortcuts.
struct KeyboardShortcutsCommands: Commands {
    static let windowID = "keyboard-shortcuts"

    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts…") {
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut(model.menuShortcut(for: .showKeyboardShortcuts))
        }
    }
}

/// Readable shortcut reference. Every row is derived from the live App
/// Shortcuts and Global Controls preferences, so remapping in Settings →
/// Keybinds updates this window without a relaunch. Global rows are the only
/// ones that work outside Transcride; fixed structural keys are listed last.
struct KeyboardShortcutsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var receivesEscape: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.title2.weight(.semibold))

            Text("Quick controls for recording and navigating Transcride. Remap any of them in Settings → Keybinds.")
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    shortcutSection("Global Recording", rows: globalRecordingRows)
                    ForEach(AppShortcutCategory.allCases) { category in
                        let rows = appShortcutRows(in: category)
                        if !rows.isEmpty {
                            shortcutSection(category.title, rows: rows)
                        }
                    }
                    shortcutSection("Fixed Keys", rows: fixedRows)
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 620, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($receivesEscape)
        .onKeyPress(.escape) {
            dismissWindow(id: KeyboardShortcutsCommands.windowID)
            return .handled
        }
        .onExitCommand {
            dismissWindow(id: KeyboardShortcutsCommands.windowID)
        }
        .onAppear { receivesEscape = true }
    }

    private var globalRecordingRows: [ShortcutRow] {
        GlobalShortcutAction.allCases.map { action in
            let keys = (model.globalShortcutPreferences.bindings[action] ?? nil)
                .map { [$0.glyphDescription] } ?? ["Not set"]
            return ShortcutRow(
                keys: keys,
                title: action.title,
                detail: "Works from other apps while Transcride is running. Configure it in Settings → Keybinds → Global Controls."
            )
        }
    }

    /// Bound app-local actions, in catalog order. Chords shadowed by a global
    /// binding or another assignment are omitted — this window never implies
    /// a disabled chord works.
    private func appShortcutRows(in category: AppShortcutCategory) -> [ShortcutRow] {
        AppShortcutAction.allCases
            .filter { $0.category == category }
            .compactMap { action in
                let keys = AppShortcutSlot.allCases.compactMap { slot -> String? in
                    guard model.appShortcutPreferences.status(
                        for: action, slot: slot, globalChords: model.configuredGlobalChords
                    ) == .active else { return nil }
                    return model.appShortcutPreferences.chord(for: action, slot: slot)?
                        .glyphDescription
                }
                guard !keys.isEmpty else { return nil }
                return ShortcutRow(
                    keys: keys,
                    title: action.title,
                    detail: Self.details[action] ?? "Works only inside Transcride."
                )
            }
    }

    private var fixedRows: [ShortcutRow] {
        [
            ShortcutRow(
                keys: ["↑", "↓"],
                title: "Select previous or next clip",
                detail: "Plain Up and Down stay with list navigation and can't be remapped."
            ),
            ShortcutRow(
                keys: ["Esc"],
                title: "Close or cancel",
                detail: "Closes the frontmost popup or window, then exits an active trim, replacement, recording, or Zen mode."
            ),
        ]
    }

    private static let details: [AppShortcutAction: String] = [
        .newRecording: "Starts recording into the selected folder.",
        .startStopRecording: "Available throughout the app.",
        .pauseOrPlaybackToggle: "Pauses or resumes an active recording or extension. When idle, controls playback.",
        .importAudio: "Choose one or more supported audio or video files.",
        .newFolder: "Creates a folder inside the selected one.",
        .toggleFavorite: "Favorites collect under the sidebar's star filter.",
        .moveNote: "Moves the selected note to another folder without touching the mouse.",
        .moveToRecentlyDeleted: "Restorable until the retention window ends. Defers to text editing.",
        .extendRecording: "Starts extending the selected audio entry; press again to finish and append. Typing in an editor still works normally.",
        .editOrSaveNote: "Starts editing the Markdown layer; while editing, saves and finishes.",
        .copyAsMarkdown: "Copies the viewed layer without frontmatter.",
        .showSummary: "Shows the local AI summary layer; press again for the transcript.",
        .generateSummary: "Generates (or regenerates) the AI summary. Everything runs on this Mac.",
        .trimAudio: "Starts trimming the selected audio clip; press again or Esc to cancel without changing it.",
        .replaceAudio: "Starts Replace Audio for the selected clip. Typing in an editor still works normally.",
        .showInfo: "Created date, duration, engine, and location.",
        .exportMarkdown: "Writes the note as a clean .md file into a folder you choose.",
        .clipUndo: "Restores the selected clip's prior audio version. Text fields and the note editor keep native text undo.",
        .clipRedo: "Reapplies the selected clip's most recently undone audio version.",
        .skipBack: "Moves back by 1–60 seconds based on the clip's total duration, without changing clip selection.",
        .skipForward: "Moves forward by 1–60 seconds based on the clip's total duration, without changing clip selection.",
        .playbackJump0: "Jumps to the start of the track.",
        .playbackJump9: "Jumps to the end of the track.",
        .speedDown: "Steps down the speed ladder (0.5×–4×).",
        .speedUp: "Steps up the speed ladder (0.5×–4×).",
        .speedReset: "Returns to 1×.",
        .toggleSkipSilence: "Turns automatic silence skipping on or off throughout the app.",
        .enterZenMode: "Distraction-free recording. Space starts recording, then pauses and resumes it. Esc asks before discarding an active recording.",
        .findInNote: "Return and ⇧Return cycle matches; matches follow the viewed layer.",
        .findAndReplaceInNote: "Opens Find with a replace field. Replacing edits the Edited layer — the Original stays immutable.",
        .searchVault: "Every transcript, with fuzzy matching and filters.",
        .previousFolder: "Moves through the far-left sidebar without taking focus from the clip list.",
        .nextFolder: "Moves through the far-left sidebar without taking focus from the clip list.",
        .showKeyboardShortcuts: "Shows this window. Every action is also in the menu bar.",
    ]

    private func shortcutSection(_ title: String, rows: [ShortcutRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 128) }
                    shortcutRow(row)
                        .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func shortcutRow(_ row: ShortcutRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            HStack(spacing: 5) {
                ForEach(row.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .padding(.horizontal, 7)
                        .frame(minWidth: 30, minHeight: 26)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                }
            }
            .frame(width: 110, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.keys.joined(separator: " or ")): \(row.title). \(row.detail)")
    }
}

private struct ShortcutRow {
    let keys: [String]
    let title: String
    let detail: String
}
