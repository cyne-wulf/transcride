import Foundation

// MARK: - Shared physical shortcut representation

/// Modifier bits shared by app-local shortcuts and Carbon global hotkeys.
/// Keep these raw values stable: the existing global-preference JSON stores
/// them directly.
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    static let requiredNonShift: Self = [.command, .option, .control]
}

/// A shortcut is stored by the physical macOS virtual key code rather than a
/// keyboard-layout-dependent character. Its encoded shape intentionally
/// matches the pre-existing `GlobalShortcutChord` wire format.
struct ShortcutChord: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    static let modifierOnlyKeyCode = UInt32.max

    var isModifierOnly: Bool { keyCode == Self.modifierOnlyKeyCode }

    var glyphDescription: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.keyLabel(for: keyCode)
        return result
    }

    func matches(keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool {
        self.keyCode == UInt32(keyCode) && self.modifiers == modifiers
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
            51: "⌫", 53: "Esc", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +",
            75: "Keypad /", 76: "Keypad ↩", 78: "Keypad −", 81: "Keypad =",
            82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
            86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
            91: "Keypad 8", 92: "Keypad 9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "Page Up",
            117: "⌦", 119: "End", 121: "Page Down", 122: "F1", 120: "F2",
            123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩",
        ]
        return labels[keyCode] ?? "Key \(keyCode)"
    }
}

// Source-compatible names keep the global shortcut service and its persisted
// JSON unchanged while both systems use the shared representation.
typealias GlobalShortcutModifiers = ShortcutModifiers
typealias GlobalShortcutChord = ShortcutChord

// MARK: - App shortcut catalog

enum AppShortcutCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case recordingFile
    case notesEntry
    case playback
    case libraryView
    case appHelp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordingFile: "Recording & File"
        case .notesEntry: "Notes & Entry"
        case .playback: "Playback"
        case .libraryView: "Library & View"
        case .appHelp: "App & Help"
        }
    }
}

/// Stable ids for every Transcride-owned command. Native App/Edit/Window
/// commands and structural dialog/list keys deliberately do not appear here.
enum AppShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case newRecording = "recording.new"
    case toggleRecording = "recording.start-stop"
    case togglePausePlayback = "recording.pause-playback"
    case importAudio = "file.import-audio"
    case newFolder = "file.new-folder"

    case toggleFavorite = "entry.favorite"
    case renameEntry = "entry.rename"
    case duplicateEntry = "entry.duplicate"
    case moveNote = "entry.move-note"
    case moveToRecentlyDeleted = "entry.move-to-recently-deleted"
    case extendRecording = "entry.extend"
    case editOrSaveNote = "entry.edit-save"
    case copyMarkdown = "entry.copy-markdown"
    case toggleTranscriptLayer = "entry.toggle-layer"
    case retranscribe = "entry.retranscribe"
    case trimAudio = "entry.trim"
    case replaceAudio = "entry.replace"
    case compressAudio = "entry.compress"
    case restoreOriginalAudio = "entry.restore-original"
    case toggleSpeakerDetection = "toggleSpeakerDetection"
    case renameSpeakers = "entry.rename-speakers"
    case deleteAudio = "entry.delete-audio"
    case showInfo = "entry.info"
    case revealInFinder = "entry.reveal"
    case exportMarkdown = "entry.export-markdown"
    case shareAudio = "entry.share-audio"
    case openInObsidian = "entry.open-in-obsidian"

    case undoClipEdit = "playback.clip-undo"
    case redoClipEdit = "playback.clip-redo"
    case skipBackward = "playback.skip-back"
    case skipForward = "playback.skip-forward"
    case jump0 = "playback.jump-0"
    case jump1 = "playback.jump-1"
    case jump2 = "playback.jump-2"
    case jump3 = "playback.jump-3"
    case jump4 = "playback.jump-4"
    case jump5 = "playback.jump-5"
    case jump6 = "playback.jump-6"
    case jump7 = "playback.jump-7"
    case jump8 = "playback.jump-8"
    case jump9 = "playback.jump-9"
    case decreasePlaybackSpeed = "playback.speed-down"
    case increasePlaybackSpeed = "playback.speed-up"
    case resetPlaybackSpeed = "playback.speed-reset"
    case toggleSkipSilence = "playback.skip-silence"
    case enterZenMode = "playback.zen"

    case findInNote = "library.find-in-note"
    case searchVault = "library.search-vault"
    case previousFolder = "library.previous-folder"
    case nextFolder = "library.next-folder"
    case sortByDate = "library.sort-date"
    case sortByDuration = "library.sort-duration"
    case sortByTitle = "library.sort-title"
    case sortByRecentlyEdited = "library.sort-recently-edited"
    case goToVaultRoot = "library.vault-root"
    case goToFavorites = "library.favorites"
    case goToRecentlyDeleted = "library.recently-deleted"
    case showTranscriptionQueue = "library.transcription-queue"

    case showAbout = "app.about"
    case showKeyboardShortcuts = "help.keyboard-shortcuts"

    var id: String { rawValue }

    var category: AppShortcutCategory {
        switch self {
        case .newRecording, .toggleRecording, .togglePausePlayback, .importAudio, .newFolder:
            .recordingFile
        case .toggleFavorite, .renameEntry, .duplicateEntry, .moveNote,
             .moveToRecentlyDeleted, .extendRecording, .editOrSaveNote,
             .copyMarkdown, .toggleTranscriptLayer, .retranscribe, .trimAudio,
             .replaceAudio, .compressAudio, .restoreOriginalAudio,
             .toggleSpeakerDetection, .renameSpeakers, .deleteAudio, .showInfo,
             .revealInFinder, .exportMarkdown, .shareAudio, .openInObsidian:
            .notesEntry
        case .undoClipEdit, .redoClipEdit, .skipBackward, .skipForward,
             .jump0, .jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7,
             .jump8, .jump9, .decreasePlaybackSpeed, .increasePlaybackSpeed,
             .resetPlaybackSpeed, .toggleSkipSilence, .enterZenMode:
            .playback
        case .findInNote, .searchVault, .previousFolder, .nextFolder,
             .sortByDate, .sortByDuration, .sortByTitle, .sortByRecentlyEdited,
             .goToVaultRoot, .goToFavorites, .goToRecentlyDeleted,
             .showTranscriptionQueue:
            .libraryView
        case .showAbout, .showKeyboardShortcuts:
            .appHelp
        }
    }

    var title: String {
        switch self {
        case .newRecording: "New Recording"
        case .toggleRecording: "Start / Stop Recording"
        case .togglePausePlayback: "Pause / Resume Recording or Playback"
        case .importAudio: "Import Audio…"
        case .newFolder: "New Folder…"
        case .toggleFavorite: "Favorite / Unfavorite"
        case .renameEntry: "Rename…"
        case .duplicateEntry: "Duplicate Entry"
        case .moveNote: "Move Note…"
        case .moveToRecentlyDeleted: "Move to Recently Deleted"
        case .extendRecording: "Extend Recording"
        case .editOrSaveNote: "Edit / Save Note"
        case .copyMarkdown: "Copy as Markdown"
        case .toggleTranscriptLayer: "Toggle Original / Edited Layer"
        case .retranscribe: "Retranscribe…"
        case .trimAudio: "Trim Audio…"
        case .replaceAudio: "Replace Audio…"
        case .compressAudio: "Compress Audio…"
        case .restoreOriginalAudio: "Restore Original Audio…"
        case .toggleSpeakerDetection: "Toggle Detect Speakers"
        case .renameSpeakers: "Rename Speakers…"
        case .deleteAudio: "Delete Audio…"
        case .showInfo: "Show Info"
        case .revealInFinder: "Reveal in Finder"
        case .exportMarkdown: "Export Markdown…"
        case .shareAudio: "Share Audio…"
        case .openInObsidian: "Open in Obsidian"
        case .undoClipEdit: "Undo Clip Operation"
        case .redoClipEdit: "Redo Clip Operation"
        case .skipBackward: "Skip Back"
        case .skipForward: "Skip Forward"
        case .jump0: "Jump to Start (0)"
        case .jump1: "Jump to 10% (1)"
        case .jump2: "Jump to 20% (2)"
        case .jump3: "Jump to 30% (3)"
        case .jump4: "Jump to 40% (4)"
        case .jump5: "Jump to 50% (5)"
        case .jump6: "Jump to 60% (6)"
        case .jump7: "Jump to 70% (7)"
        case .jump8: "Jump to 80% (8)"
        case .jump9: "Jump to End (9)"
        case .decreasePlaybackSpeed: "Slower Playback"
        case .increasePlaybackSpeed: "Faster Playback"
        case .resetPlaybackSpeed: "Reset Playback Speed"
        case .toggleSkipSilence: "Skip Silence"
        case .enterZenMode: "Zen Mode"
        case .findInNote: "Find in Note…"
        case .searchVault: "Search Vault…"
        case .previousFolder: "Previous Folder"
        case .nextFolder: "Next Folder"
        case .sortByDate: "Sort by Date"
        case .sortByDuration: "Sort by Duration"
        case .sortByTitle: "Sort by Title"
        case .sortByRecentlyEdited: "Sort by Recently Edited"
        case .goToVaultRoot: "Vault Root"
        case .goToFavorites: "Favorites"
        case .goToRecentlyDeleted: "Recently Deleted"
        case .showTranscriptionQueue: "Transcription Queue"
        case .showAbout: "About Transcride"
        case .showKeyboardShortcuts: "Keyboard Shortcuts…"
        }
    }

    var detail: String {
        switch self {
        case .toggleRecording: "Starts or saves the active recording."
        case .togglePausePlayback: "Pauses/resumes capture, or toggles playback while idle."
        case .moveNote: "Moves the selected note to an existing vault folder."
        case .moveToRecentlyDeleted: "Moves the selected note to recoverable Recently Deleted."
        case .undoClipEdit, .redoClipEdit: "Text editing keeps native undo and redo."
        case .previousFolder, .nextFolder: "Moves through the far-left library sidebar."
        default: "Available while Transcride is active."
        }
    }

    /// Even a modified remapping must defer to an editable text view for
    /// these commands. All other bare bindings defer automatically.
    var alwaysDefersToEditableText: Bool {
        switch self {
        case .undoClipEdit, .redoClipEdit, .moveToRecentlyDeleted,
             .showInfo, .findInNote:
            true
        default:
            false
        }
    }

    var playbackFraction: Double? {
        switch self {
        case .jump0: 0
        case .jump1: 0.1
        case .jump2: 0.2
        case .jump3: 0.3
        case .jump4: 0.4
        case .jump5: 0.5
        case .jump6: 0.6
        case .jump7: 0.7
        case .jump8: 0.8
        case .jump9: 1
        default: nil
        }
    }
}

enum AppShortcutSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case primary
    case alternate

    var id: String { rawValue }
    var title: String { self == .primary ? "Primary" : "Alternate" }
}

struct AppShortcutBindingSet: Codable, Equatable, Sendable {
    var primary: ShortcutChord?
    var alternate: ShortcutChord?

    init(primary: ShortcutChord? = nil, alternate: ShortcutChord? = nil) {
        self.primary = primary
        self.alternate = alternate
    }

    subscript(slot: AppShortcutSlot) -> ShortcutChord? {
        get { slot == .primary ? primary : alternate }
        set {
            if slot == .primary { primary = newValue }
            else { alternate = newValue }
        }
    }

    var orderedChords: [ShortcutChord] {
        [primary, alternate].compactMap { $0 }
    }
}

enum AppShortcutBindingStatus: Equatable, Sendable {
    case available
    case unassigned
    case modifierOnly
    case reserved(String)
    case duplicateWithinAction
    case conflictsWithApp(AppShortcutAction)
    case conflictsWithGlobal(String)

    var isAvailable: Bool { self == .available }

    var message: String? {
        switch self {
        case .available: nil
        case .unassigned: "Not set"
        case .modifierOnly: "Press a key, not only modifiers."
        case .reserved(let reason): reason
        case .duplicateWithinAction: "Primary and alternate shortcuts must differ."
        case .conflictsWithApp(let action): "Already assigned to \(action.title)."
        case .conflictsWithGlobal(let title): "Already assigned globally to \(title)."
        }
    }
}

struct AppShortcutPreferences: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var bindings: [AppShortcutAction: AppShortcutBindingSet]

    init(
        version: Int = currentVersion,
        bindings: [AppShortcutAction: AppShortcutBindingSet]
    ) {
        self.version = version
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case version, bindings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let decoded = try container.decodeIfPresent(
            [AppShortcutAction: AppShortcutBindingSet].self,
            forKey: .bindings
        ) ?? [:]
        var merged = Self.defaults.bindings
        for (action, binding) in decoded { merged[action] = binding }
        bindings = merged
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(bindings, forKey: .bindings)
    }

    subscript(action: AppShortcutAction, slot: AppShortcutSlot) -> ShortcutChord? {
        get { bindings[action]?[slot] }
        set {
            var binding = bindings[action] ?? AppShortcutBindingSet()
            binding[slot] = newValue
            bindings[action] = binding
        }
    }

    func bindingSet(for action: AppShortcutAction) -> AppShortcutBindingSet {
        bindings[action] ?? AppShortcutBindingSet()
    }

    func validationStatus(
        for action: AppShortcutAction,
        slot: AppShortcutSlot,
        globalBindings: [ShortcutChord: String] = [:]
    ) -> AppShortcutBindingStatus {
        guard let chord = self[action, slot] else { return .unassigned }
        return validationStatus(
            for: action,
            slot: slot,
            candidate: chord,
            globalBindings: globalBindings
        )
    }

    func validationStatus(
        for action: AppShortcutAction,
        slot: AppShortcutSlot,
        candidate chord: ShortcutChord,
        globalBindings: [ShortcutChord: String] = [:]
    ) -> AppShortcutBindingStatus {
        if chord.isModifierOnly { return .modifierOnly }
        if let reason = ShortcutReservation.localReason(for: chord) {
            return .reserved(reason)
        }

        let otherSlot: AppShortcutSlot = slot == .primary ? .alternate : .primary
        if self[action, otherSlot] == chord { return .duplicateWithinAction }

        for otherAction in AppShortcutAction.allCases where otherAction != action {
            if bindingSet(for: otherAction).orderedChords.contains(chord) {
                return .conflictsWithApp(otherAction)
            }
        }
        if let globalTitle = globalBindings[chord] {
            return .conflictsWithGlobal(globalTitle)
        }
        return .available
    }

    /// Only unambiguous, non-reserved bindings participate in event matching.
    /// Persisted conflicts are intentionally left in storage so Settings can
    /// display and let the user repair them.
    func activeBindings(
        globalBindings: [ShortcutChord: String] = [:]
    ) -> [(action: AppShortcutAction, chord: ShortcutChord)] {
        AppShortcutAction.allCases.flatMap { action in
            AppShortcutSlot.allCases.compactMap { slot in
                guard validationStatus(
                    for: action, slot: slot, globalBindings: globalBindings
                ) == .available,
                      let chord = self[action, slot] else { return nil }
                return (action, chord)
            }
        }
    }

    static let defaults: Self = {
        func chord(_ keyCode: UInt32, _ modifiers: ShortcutModifiers = []) -> ShortcutChord {
            ShortcutChord(keyCode: keyCode, modifiers: modifiers)
        }
        var bindings = Dictionary(
            uniqueKeysWithValues: AppShortcutAction.allCases.map {
                ($0, AppShortcutBindingSet())
            }
        )

        bindings[.newRecording] = .init(primary: chord(45, .command))
        bindings[.toggleRecording] = .init(primary: chord(49, .shift))
        bindings[.togglePausePlayback] = .init(primary: chord(49))
        bindings[.importAudio] = .init(primary: chord(34, [.command, .shift]))
        bindings[.newFolder] = .init(primary: chord(45, [.command, .shift]))
        bindings[.toggleFavorite] = .init(primary: chord(2, .command))
        bindings[.moveNote] = .init(primary: chord(46, .option))
        bindings[.moveToRecentlyDeleted] = .init(
            primary: chord(51, .command), alternate: chord(51, .shift)
        )
        bindings[.extendRecording] = .init(
            primary: chord(14), alternate: chord(15, [.command, .shift])
        )
        bindings[.editOrSaveNote] = .init(primary: chord(14, .command))
        bindings[.copyMarkdown] = .init(primary: chord(8, [.command, .shift]))
        bindings[.trimAudio] = .init(primary: chord(17))
        bindings[.replaceAudio] = .init(primary: chord(15))
        bindings[.showInfo] = .init(primary: chord(34, .command))
        bindings[.exportMarkdown] = .init(primary: chord(14, [.command, .shift]))
        bindings[.undoClipEdit] = .init(primary: chord(6, .command))
        bindings[.redoClipEdit] = .init(primary: chord(6, [.command, .shift]))
        bindings[.skipBackward] = .init(primary: chord(123))
        bindings[.skipForward] = .init(primary: chord(124))
        // Preserve both physical digit rows accepted by the existing key
        // monitor. Distinct labels keep the two slots understandable in
        // Settings even though both produce the same numeric character.
        bindings[.jump0] = .init(primary: chord(29), alternate: chord(82))
        bindings[.jump1] = .init(primary: chord(18), alternate: chord(83))
        bindings[.jump2] = .init(primary: chord(19), alternate: chord(84))
        bindings[.jump3] = .init(primary: chord(20), alternate: chord(85))
        bindings[.jump4] = .init(primary: chord(21), alternate: chord(86))
        bindings[.jump5] = .init(primary: chord(23), alternate: chord(87))
        bindings[.jump6] = .init(primary: chord(22), alternate: chord(88))
        bindings[.jump7] = .init(primary: chord(26), alternate: chord(89))
        bindings[.jump8] = .init(primary: chord(28), alternate: chord(91))
        bindings[.jump9] = .init(primary: chord(25), alternate: chord(92))
        bindings[.decreasePlaybackSpeed] = .init(primary: chord(33))
        bindings[.increasePlaybackSpeed] = .init(primary: chord(30))
        bindings[.resetPlaybackSpeed] = .init(primary: chord(42))
        bindings[.toggleSkipSilence] = .init(primary: chord(1))
        bindings[.enterZenMode] = .init(primary: chord(6))
        bindings[.findInNote] = .init(primary: chord(3, .command))
        bindings[.searchVault] = .init(primary: chord(3, [.command, .shift]))
        bindings[.previousFolder] = .init(primary: chord(126, .option))
        bindings[.nextFolder] = .init(primary: chord(125, .option))
        bindings[.showKeyboardShortcuts] = .init(
            primary: chord(44, [.command, .shift])
        )
        return Self(bindings: bindings)
    }()
}

enum AppShortcutPreferencesStore {
    static let defaultsKey = "appShortcutPreferencesV1"

    static func load(defaults: UserDefaults = .standard) -> AppShortcutPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              var preferences = try? JSONDecoder().decode(
                AppShortcutPreferences.self, from: data
              ),
              (1...AppShortcutPreferences.currentVersion).contains(preferences.version)
        else { return .defaults }
        preferences.version = AppShortcutPreferences.currentVersion
        return preferences
    }

    static func save(
        _ preferences: AppShortcutPreferences,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

// MARK: - Validation and pure event matching

enum ShortcutReservation {
    static func localReason(for chord: ShortcutChord) -> String? {
        if chord.isModifierOnly { return "Press a key, not only modifiers." }

        // Escape, Return, and Tab remain structural regardless of modifiers.
        // Up/Down and Delete are only fixed in their unmodified forms because
        // the established app defaults use Option-arrows and modified Delete.
        switch chord.keyCode {
        case 36, 48, 53, 76:
            return "That key keeps its native navigation or dialog behavior."
        default:
            break
        }

        if chord.modifiers.isEmpty {
            switch chord.keyCode {
            case 51, 117, 125, 126:
                return "That key keeps its native navigation or dialog behavior."
            default:
                break
            }
        }

        // App/Edit/Window and system-owned shortcuts stay native. The
        // Transcride defaults intentionally retain ⌘N, ⌘F, ⌘I, and ⌘Z.
        let reserved: Set<ShortcutChord> = [
            .init(keyCode: 12, modifiers: .command),                 // Quit
            .init(keyCode: 4, modifiers: .command),                  // Hide
            .init(keyCode: 4, modifiers: [.command, .option]),       // Hide Others
            .init(keyCode: 46, modifiers: .command),                 // Minimize
            .init(keyCode: 13, modifiers: .command),                 // Close
            .init(keyCode: 43, modifiers: .command),                 // Settings
            .init(keyCode: 7, modifiers: .command),                  // Cut
            .init(keyCode: 8, modifiers: .command),                  // Copy
            .init(keyCode: 9, modifiers: .command),                  // Paste
            .init(keyCode: 0, modifiers: .command),                  // Select All
            .init(keyCode: 31, modifiers: .command),                 // Open
            .init(keyCode: 1, modifiers: .command),                  // Save
            .init(keyCode: 35, modifiers: .command),                 // Print
            .init(keyCode: 17, modifiers: .command),                 // New tab
            .init(keyCode: 5, modifiers: .command),                  // Find next
            .init(keyCode: 5, modifiers: [.command, .shift]),        // Find previous
            .init(keyCode: 41, modifiers: .command),                 // Check spelling
            .init(keyCode: 41, modifiers: [.command, .shift]),       // Spelling panel
            .init(keyCode: 47, modifiers: .command),                 // Cancel operation
            .init(keyCode: 24, modifiers: .command),                 // Zoom in
            .init(keyCode: 27, modifiers: .command),                 // Zoom out
            .init(keyCode: 29, modifiers: .command),                 // Actual size
            .init(keyCode: 50, modifiers: .command),                 // Next window
            .init(keyCode: 50, modifiers: [.command, .shift]),       // Previous window
            .init(keyCode: 49, modifiers: .command),                 // Spotlight
            .init(keyCode: 49, modifiers: .control),                 // Input source
            .init(keyCode: 49, modifiers: [.control, .option]),      // Previous input source
            .init(keyCode: 49, modifiers: [.control, .command]),     // Character Viewer
            .init(keyCode: 48, modifiers: .command),                 // App switcher
            .init(keyCode: 53, modifiers: [.command, .option]),      // Force Quit
            .init(keyCode: 12, modifiers: [.control, .command]),     // Lock screen
            .init(keyCode: 2, modifiers: [.command, .option]),       // Show/hide Dock
            .init(keyCode: 2, modifiers: [.control, .command]),      // Look up selection
            .init(keyCode: 3, modifiers: [.control, .command]),      // Full screen
            .init(keyCode: 123, modifiers: .control),
            .init(keyCode: 124, modifiers: .control),
            .init(keyCode: 125, modifiers: .control),
            .init(keyCode: 126, modifiers: .control),
            .init(keyCode: 20, modifiers: [.command, .shift]),       // Screenshot
            .init(keyCode: 21, modifiers: [.command, .shift]),
            .init(keyCode: 23, modifiers: [.command, .shift]),
            .init(keyCode: 20, modifiers: [.control, .command, .shift]),
            .init(keyCode: 21, modifiers: [.control, .command, .shift]),
            .init(keyCode: 23, modifiers: [.control, .command, .shift]),
        ]
        return reserved.contains(chord)
            ? "That shortcut is reserved by macOS or a native app command."
            : nil
    }
}

struct AppShortcutMatcher {
    static func action(
        forKeyCode keyCode: UInt16,
        modifiers: ShortcutModifiers,
        preferences: AppShortcutPreferences,
        globalBindings: [ShortcutChord: String] = [:],
        editableTextHasFocus: Bool,
        captureOwnsInput: Bool
    ) -> AppShortcutAction? {
        guard !captureOwnsInput else { return nil }
        for binding in preferences.activeBindings(globalBindings: globalBindings) {
            guard binding.chord.matches(keyCode: keyCode, modifiers: modifiers) else {
                continue
            }
            // Bare and Shift-only chords represent typing/navigation input.
            // Modified clip undo/redo and entry deletion also stay with the
            // editor, while bindings such as Option-M deliberately remain app
            // commands so Move Note can flush and finish an active edit.
            let isTypingChord = binding.chord.modifiers
                .intersection(.requiredNonShift).isEmpty
            if editableTextHasFocus,
               (isTypingChord || binding.action.alwaysDefersToEditableText) {
                return nil
            }
            return binding.action
        }
        return nil
    }
}
