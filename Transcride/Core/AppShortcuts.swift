import Foundation

// MARK: - Shared chord types

/// Modifier set shared by app-local shortcuts and global hotkeys. Raw values
/// are the persisted wire format from the original global-shortcut store and
/// must never change.
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    static let requiredNonShift: Self = [.command, .option, .control]

    /// Device-independent Cocoa modifier-flag bits (NSEvent.ModifierFlags /
    /// CGEventFlags). Declared as plain constants so Core stays AppKit-free.
    private static let cocoaShift: UInt = 1 << 17
    private static let cocoaControl: UInt = 1 << 18
    private static let cocoaOption: UInt = 1 << 19
    private static let cocoaCommand: UInt = 1 << 20

    /// Normalizes raw Cocoa modifier flags: keeps ⌘⌥⌃⇧ and drops the
    /// implicit numeric-pad/function bits AppKit adds to arrows and keypad
    /// digits, which are not user-held modifiers.
    init(cocoaFlags: UInt) {
        var result: Self = []
        if cocoaFlags & Self.cocoaCommand != 0 { result.insert(.command) }
        if cocoaFlags & Self.cocoaOption != 0 { result.insert(.option) }
        if cocoaFlags & Self.cocoaControl != 0 { result.insert(.control) }
        if cocoaFlags & Self.cocoaShift != 0 { result.insert(.shift) }
        self = result
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var glyphs: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A physical key chord. Persisted as `keyCode` + `modifiers`, byte-compatible
/// with the original `GlobalShortcutChord` wire format.
struct ShortcutChord: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    /// Sentinel produced by capture views when only modifiers were pressed.
    static let modifierOnlyKeyCode = UInt32.max

    /// Bare and shift-only chords must never fire while an editable text view
    /// has focus — typing always wins those keys.
    var yieldsToTextEditing: Bool {
        modifiers.intersection(.requiredNonShift).isEmpty
    }

    func matches(keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool {
        self.keyCode == UInt32(keyCode) && self.modifiers == modifiers
    }

    var glyphDescription: String {
        modifiers.glyphs + Self.keyLabel(for: keyCode)
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "⌫",
            53: "Esc", 76: "⌤", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
            117: "⌦", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
            87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
            36: "↩",
        ]
        return labels[keyCode] ?? "Key \(keyCode)"
    }

    // Global recording defaults (⌥R / ⌥P), unchanged from milestone 8.
    static let defaultToggleRecording = Self(keyCode: 15, modifiers: [.option])
    static let defaultPauseResume = Self(keyCode: 35, modifiers: [.option])

    /// Global capture rule: a global hotkey needs a real key plus at least one
    /// non-Shift modifier.
    var globalCaptureValidation: GlobalShortcutValidation {
        if keyCode == Self.modifierOnlyKeyCode { return .modifierOnly }
        if modifiers.intersection(.requiredNonShift).isEmpty { return .requiresNonShiftModifier }
        return .valid
    }
}

// Existing global-shortcut code keeps compiling and persisting identically.
typealias GlobalShortcutModifiers = ShortcutModifiers
typealias GlobalShortcutChord = ShortcutChord

// MARK: - App-local shortcut catalog

enum AppShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case recordingFile
    case notesEntry
    case playback
    case libraryView
    case appHelp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordingFile: "Recording & Files"
        case .notesEntry: "Notes & Entries"
        case .playback: "Playback"
        case .libraryView: "Library & View"
        case .appHelp: "App & Help"
        }
    }
}

/// Every remappable Transcride-specific command. Raw values are stable
/// persistence IDs — never rename a case's raw value.
enum AppShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    // Recording & Files
    case newRecording
    case startStopRecording
    case pauseOrPlaybackToggle
    case importAudio
    case newFolder

    // Notes & Entries
    case toggleFavorite
    case renameEntry
    case duplicateEntry
    case moveNote
    case moveToRecentlyDeleted
    case extendRecording
    case editOrSaveNote
    case copyAsMarkdown
    case toggleLayer
    case retranscribe
    case trimAudio
    case replaceAudio
    case compressAudio
    case restoreOriginalAudio
    case renameSpeakers
    case deleteAudio
    case showInfo
    case revealInFinder
    case exportMarkdown
    case shareAudio
    case openInObsidian

    // Playback
    case clipUndo
    case clipRedo
    case skipBack
    case skipForward
    case playbackJump0
    case playbackJump1
    case playbackJump2
    case playbackJump3
    case playbackJump4
    case playbackJump5
    case playbackJump6
    case playbackJump7
    case playbackJump8
    case playbackJump9
    case speedDown
    case speedUp
    case speedReset
    case toggleSkipSilence
    case enterZenMode

    // Library & View
    case findInNote
    case searchVault
    case previousFolder
    case nextFolder
    case sortByDate
    case sortByDuration
    case sortByTitle
    case sortByRecentlyEdited
    case goToVaultRoot
    case goToFavorites
    case goToRecentlyDeleted
    case showTranscriptionQueue

    // App & Help
    case showAbout
    case showKeyboardShortcuts

    var id: String { rawValue }

    var category: AppShortcutCategory {
        switch self {
        case .newRecording, .startStopRecording, .pauseOrPlaybackToggle,
             .importAudio, .newFolder:
            .recordingFile
        case .toggleFavorite, .renameEntry, .duplicateEntry, .moveNote,
             .moveToRecentlyDeleted, .extendRecording, .editOrSaveNote,
             .copyAsMarkdown, .toggleLayer, .retranscribe, .trimAudio,
             .replaceAudio, .compressAudio, .restoreOriginalAudio,
             .renameSpeakers, .deleteAudio, .showInfo, .revealInFinder,
             .exportMarkdown, .shareAudio, .openInObsidian:
            .notesEntry
        case .clipUndo, .clipRedo, .skipBack, .skipForward,
             .playbackJump0, .playbackJump1, .playbackJump2, .playbackJump3,
             .playbackJump4, .playbackJump5, .playbackJump6, .playbackJump7,
             .playbackJump8, .playbackJump9,
             .speedDown, .speedUp, .speedReset, .toggleSkipSilence, .enterZenMode:
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
        case .startStopRecording: "Start / Stop Recording"
        case .pauseOrPlaybackToggle: "Pause Recording / Play–Pause"
        case .importAudio: "Import Audio…"
        case .newFolder: "New Folder…"
        case .toggleFavorite: "Favorite / Unfavorite"
        case .renameEntry: "Rename…"
        case .duplicateEntry: "Duplicate Entry"
        case .moveNote: "Move Note…"
        case .moveToRecentlyDeleted: "Move to Recently Deleted"
        case .extendRecording: "Extend Recording"
        case .editOrSaveNote: "Edit / Save Note"
        case .copyAsMarkdown: "Copy as Markdown"
        case .toggleLayer: "Toggle Original / Edited Layer"
        case .retranscribe: "Retranscribe…"
        case .trimAudio: "Trim Audio…"
        case .replaceAudio: "Replace Audio"
        case .compressAudio: "Compress Audio…"
        case .restoreOriginalAudio: "Restore Original Audio…"
        case .renameSpeakers: "Rename Speakers…"
        case .deleteAudio: "Delete Audio…"
        case .showInfo: "Show Info"
        case .revealInFinder: "Reveal in Finder"
        case .exportMarkdown: "Export Markdown…"
        case .shareAudio: "Share Audio…"
        case .openInObsidian: "Open in Obsidian"
        case .clipUndo: "Undo Clip Operation"
        case .clipRedo: "Redo Clip Operation"
        case .skipBack: "Skip Back"
        case .skipForward: "Skip Forward"
        case .playbackJump0: "Jump to Start"
        case .playbackJump1: "Jump to 10%"
        case .playbackJump2: "Jump to 20%"
        case .playbackJump3: "Jump to 30%"
        case .playbackJump4: "Jump to 40%"
        case .playbackJump5: "Jump to 50%"
        case .playbackJump6: "Jump to 60%"
        case .playbackJump7: "Jump to 70%"
        case .playbackJump8: "Jump to 80%"
        case .playbackJump9: "Jump to End"
        case .speedDown: "Slower Playback"
        case .speedUp: "Faster Playback"
        case .speedReset: "Normal Speed"
        case .toggleSkipSilence: "Toggle Skip Silence"
        case .enterZenMode: "Enter Zen Mode"
        case .findInNote: "Find in Note…"
        case .searchVault: "Search Vault…"
        case .previousFolder: "Previous Folder"
        case .nextFolder: "Next Folder"
        case .sortByDate: "Sort by Date"
        case .sortByDuration: "Sort by Duration"
        case .sortByTitle: "Sort by Title"
        case .sortByRecentlyEdited: "Sort by Recently Edited"
        case .goToVaultRoot: "Go to Vault Root"
        case .goToFavorites: "Go to Favorites"
        case .goToRecentlyDeleted: "Go to Recently Deleted"
        case .showTranscriptionQueue: "Transcription Queue"
        case .showAbout: "About Transcride"
        case .showKeyboardShortcuts: "Keyboard Shortcuts…"
        }
    }

    /// ⌘Z/⌘⇧Z, the delete chords, and ⌥↑/⌥↓ keep deferring to an editable
    /// text view even though they carry modifiers: native text undo/redo,
    /// text deletion, and Option-arrow paragraph navigation own them while
    /// typing.
    var defersToTextEditingWhenModified: Bool {
        switch self {
        case .clipUndo, .clipRedo, .moveToRecentlyDeleted,
             .previousFolder, .nextFolder:
            true
        default:
            false
        }
    }

    var defaultBinding: AppShortcutBinding {
        switch self {
        case .newRecording:
            AppShortcutBinding(primary: .init(keyCode: 45, modifiers: [.command]))
        case .startStopRecording:
            AppShortcutBinding(primary: .init(keyCode: 49, modifiers: [.shift]))
        case .pauseOrPlaybackToggle:
            AppShortcutBinding(primary: .init(keyCode: 49, modifiers: []))
        case .importAudio:
            AppShortcutBinding(primary: .init(keyCode: 34, modifiers: [.command, .shift]))
        case .newFolder:
            AppShortcutBinding(primary: .init(keyCode: 45, modifiers: [.command, .shift]))
        case .toggleFavorite:
            AppShortcutBinding(primary: .init(keyCode: 2, modifiers: [.command]))
        case .moveNote:
            AppShortcutBinding(primary: .init(keyCode: 46, modifiers: [.option]))
        case .moveToRecentlyDeleted:
            AppShortcutBinding(
                primary: .init(keyCode: 51, modifiers: [.command]),
                alternate: .init(keyCode: 51, modifiers: [.shift])
            )
        case .extendRecording:
            AppShortcutBinding(
                primary: .init(keyCode: 14, modifiers: []),
                alternate: .init(keyCode: 15, modifiers: [.command, .shift])
            )
        case .editOrSaveNote:
            AppShortcutBinding(primary: .init(keyCode: 14, modifiers: [.command]))
        case .copyAsMarkdown:
            AppShortcutBinding(primary: .init(keyCode: 8, modifiers: [.command, .shift]))
        case .trimAudio:
            AppShortcutBinding(primary: .init(keyCode: 17, modifiers: []))
        case .replaceAudio:
            AppShortcutBinding(primary: .init(keyCode: 15, modifiers: []))
        case .showInfo:
            AppShortcutBinding(primary: .init(keyCode: 34, modifiers: [.command]))
        case .exportMarkdown:
            AppShortcutBinding(primary: .init(keyCode: 14, modifiers: [.command, .shift]))
        case .clipUndo:
            AppShortcutBinding(primary: .init(keyCode: 6, modifiers: [.command]))
        case .clipRedo:
            AppShortcutBinding(primary: .init(keyCode: 6, modifiers: [.command, .shift]))
        case .skipBack:
            AppShortcutBinding(primary: .init(keyCode: 123, modifiers: []))
        case .skipForward:
            AppShortcutBinding(primary: .init(keyCode: 124, modifiers: []))
        case .playbackJump0:
            AppShortcutBinding(
                primary: .init(keyCode: 29, modifiers: []),
                alternate: .init(keyCode: 82, modifiers: [])
            )
        case .playbackJump1:
            AppShortcutBinding(
                primary: .init(keyCode: 18, modifiers: []),
                alternate: .init(keyCode: 83, modifiers: [])
            )
        case .playbackJump2:
            AppShortcutBinding(
                primary: .init(keyCode: 19, modifiers: []),
                alternate: .init(keyCode: 84, modifiers: [])
            )
        case .playbackJump3:
            AppShortcutBinding(
                primary: .init(keyCode: 20, modifiers: []),
                alternate: .init(keyCode: 85, modifiers: [])
            )
        case .playbackJump4:
            AppShortcutBinding(
                primary: .init(keyCode: 21, modifiers: []),
                alternate: .init(keyCode: 86, modifiers: [])
            )
        case .playbackJump5:
            AppShortcutBinding(
                primary: .init(keyCode: 23, modifiers: []),
                alternate: .init(keyCode: 87, modifiers: [])
            )
        case .playbackJump6:
            AppShortcutBinding(
                primary: .init(keyCode: 22, modifiers: []),
                alternate: .init(keyCode: 88, modifiers: [])
            )
        case .playbackJump7:
            AppShortcutBinding(
                primary: .init(keyCode: 26, modifiers: []),
                alternate: .init(keyCode: 89, modifiers: [])
            )
        case .playbackJump8:
            AppShortcutBinding(
                primary: .init(keyCode: 28, modifiers: []),
                alternate: .init(keyCode: 91, modifiers: [])
            )
        case .playbackJump9:
            AppShortcutBinding(
                primary: .init(keyCode: 25, modifiers: []),
                alternate: .init(keyCode: 92, modifiers: [])
            )
        case .speedDown:
            AppShortcutBinding(primary: .init(keyCode: 33, modifiers: []))
        case .speedUp:
            AppShortcutBinding(primary: .init(keyCode: 30, modifiers: []))
        case .speedReset:
            AppShortcutBinding(primary: .init(keyCode: 42, modifiers: []))
        case .toggleSkipSilence:
            AppShortcutBinding(primary: .init(keyCode: 1, modifiers: []))
        case .enterZenMode:
            AppShortcutBinding(primary: .init(keyCode: 6, modifiers: []))
        case .findInNote:
            AppShortcutBinding(primary: .init(keyCode: 3, modifiers: [.command]))
        case .searchVault:
            AppShortcutBinding(primary: .init(keyCode: 3, modifiers: [.command, .shift]))
        case .previousFolder:
            AppShortcutBinding(primary: .init(keyCode: 126, modifiers: [.option]))
        case .nextFolder:
            AppShortcutBinding(primary: .init(keyCode: 125, modifiers: [.option]))
        case .showKeyboardShortcuts:
            AppShortcutBinding(primary: .init(keyCode: 44, modifiers: [.command, .shift]))
        case .renameEntry, .duplicateEntry, .toggleLayer, .retranscribe,
             .compressAudio, .restoreOriginalAudio, .renameSpeakers,
             .deleteAudio, .revealInFinder, .shareAudio, .openInObsidian,
             .sortByDate, .sortByDuration, .sortByTitle, .sortByRecentlyEdited,
             .goToVaultRoot, .goToFavorites, .goToRecentlyDeleted,
             .showTranscriptionQueue, .showAbout:
            AppShortcutBinding()
        }
    }
}

// MARK: - Bindings and preferences

struct AppShortcutBinding: Codable, Hashable, Sendable {
    var primary: ShortcutChord?
    var alternate: ShortcutChord?

    init(primary: ShortcutChord? = nil, alternate: ShortcutChord? = nil) {
        self.primary = primary
        self.alternate = alternate
    }

    var chords: [ShortcutChord] {
        [primary, alternate].compactMap { $0 }
    }

    subscript(slot: AppShortcutSlot) -> ShortcutChord? {
        get {
            switch slot {
            case .primary: primary
            case .alternate: alternate
            }
        }
        set {
            switch slot {
            case .primary: primary = newValue
            case .alternate: alternate = newValue
            }
        }
    }
}

enum AppShortcutSlot: String, Codable, CaseIterable, Sendable {
    case primary
    case alternate

    var title: String {
        switch self {
        case .primary: "Primary"
        case .alternate: "Alternate"
        }
    }
}

enum AppShortcutValidation: Equatable, Sendable {
    case valid
    case modifierOnly
    case reserved(String)
    case duplicate(AppShortcutAction)
    case conflictsWithGlobal(GlobalShortcutAction)

    var message: String? {
        switch self {
        case .valid:
            nil
        case .modifierOnly:
            "Press a key together with modifiers."
        case .reserved(let reason):
            reason
        case .duplicate(let action):
            "Already assigned to \(action.title)."
        case .conflictsWithGlobal(let action):
            "Already assigned to the global \(action.title) shortcut."
        }
    }
}

/// Keys that stay native and structural: they can never be reassigned.
enum AppShortcutReservedKeys {
    private static let structuralKeyCodes: Set<UInt32> = [36, 76, 48, 53] // ↩, ⌤, Tab, Esc

    private static let systemChords: Set<ShortcutChord> = [
        ShortcutChord(keyCode: 12, modifiers: [.command]),            // ⌘Q Quit
        ShortcutChord(keyCode: 13, modifiers: [.command]),            // ⌘W Close
        ShortcutChord(keyCode: 13, modifiers: [.command, .shift]),    // ⌘⇧W
        ShortcutChord(keyCode: 13, modifiers: [.command, .option]),   // ⌘⌥W
        ShortcutChord(keyCode: 4, modifiers: [.command]),             // ⌘H Hide
        ShortcutChord(keyCode: 4, modifiers: [.command, .option]),    // ⌘⌥H Hide Others
        ShortcutChord(keyCode: 46, modifiers: [.command]),            // ⌘M Minimize
        ShortcutChord(keyCode: 46, modifiers: [.command, .option]),   // ⌘⌥M
        ShortcutChord(keyCode: 43, modifiers: [.command]),            // ⌘, Settings
        ShortcutChord(keyCode: 7, modifiers: [.command]),             // ⌘X Cut
        ShortcutChord(keyCode: 8, modifiers: [.command]),             // ⌘C Copy
        ShortcutChord(keyCode: 9, modifiers: [.command]),             // ⌘V Paste
        ShortcutChord(keyCode: 9, modifiers: [.command, .option, .shift]), // Paste & Match Style
        ShortcutChord(keyCode: 0, modifiers: [.command]),             // ⌘A Select All
    ]

    static func reservedReason(for chord: ShortcutChord) -> String? {
        if structuralKeyCodes.contains(chord.keyCode) {
            return "\(ShortcutChord.keyLabel(for: chord.keyCode)) is a structural key and stays native."
        }
        if chord.keyCode == 51 || chord.keyCode == 117, chord.modifiers.isEmpty {
            return "Unmodified Delete stays with text editing."
        }
        if chord.keyCode == 125 || chord.keyCode == 126,
           chord.modifiers.intersection(.requiredNonShift).isEmpty {
            return "Plain Up and Down stay with list navigation."
        }
        if systemChords.contains(chord) {
            return "\(chord.glyphDescription) belongs to macOS."
        }
        return nil
    }
}

enum AppShortcutBindingStatus: Equatable, Sendable {
    case active
    case disabled(String)
}

struct AppShortcutPreferences: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var bindings: [AppShortcutAction: AppShortcutBinding]

    init(
        version: Int = currentVersion,
        bindings: [AppShortcutAction: AppShortcutBinding]
    ) {
        self.version = version
        self.bindings = bindings
    }

    static let defaults = Self(bindings: Dictionary(
        uniqueKeysWithValues: AppShortcutAction.allCases.map { ($0, $0.defaultBinding) }
    ))

    private enum CodingKeys: String, CodingKey {
        case version
        case bindings
    }

    /// Tolerant decoding: unknown action IDs (from a newer build) are dropped,
    /// actions missing from the payload (added since it was written) get their
    /// defaults. An explicitly cleared binding stays cleared because it is
    /// present in the payload as an empty binding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let raw = try container.decode([String: AppShortcutBinding].self, forKey: .bindings)
        var decoded: [AppShortcutAction: AppShortcutBinding] = [:]
        for (key, binding) in raw {
            guard let action = AppShortcutAction(rawValue: key) else { continue }
            decoded[action] = binding
        }
        for action in AppShortcutAction.allCases where decoded[action] == nil {
            decoded[action] = action.defaultBinding
        }
        bindings = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        try container.encode(raw, forKey: .bindings)
    }

    func binding(for action: AppShortcutAction) -> AppShortcutBinding {
        bindings[action] ?? action.defaultBinding
    }

    func chord(for action: AppShortcutAction, slot: AppShortcutSlot = .primary) -> ShortcutChord? {
        binding(for: action)[slot]
    }

    /// Validates assigning `chord` to (`action`, `slot`) against the reserved
    /// list and every other local slot.
    func validation(
        settingChord chord: ShortcutChord,
        for action: AppShortcutAction,
        slot: AppShortcutSlot
    ) -> AppShortcutValidation {
        if chord.keyCode == ShortcutChord.modifierOnlyKeyCode { return .modifierOnly }
        if let reason = AppShortcutReservedKeys.reservedReason(for: chord) {
            return .reserved(reason)
        }
        for other in AppShortcutAction.allCases {
            let binding = self.binding(for: other)
            for otherSlot in AppShortcutSlot.allCases {
                if other == action, otherSlot == slot { continue }
                if binding[otherSlot] == chord { return .duplicate(other) }
            }
        }
        return .valid
    }

    /// Validation variant that also rejects chords owned by a global hotkey.
    func validation(
        settingChord chord: ShortcutChord,
        for action: AppShortcutAction,
        slot: AppShortcutSlot,
        globalBindings: [GlobalShortcutAction: ShortcutChord?]
    ) -> AppShortcutValidation {
        let base = validation(settingChord: chord, for: action, slot: slot)
        guard base == .valid else { return base }
        if let owner = globalBindings.first(where: { $0.value == chord })?.key {
            return .conflictsWithGlobal(owner)
        }
        return .valid
    }

    /// Status of a stored binding slot. Persisted chords that collide with a
    /// global binding or with another local slot are disabled — never silently
    /// dropped — so Settings can flag them visibly.
    func status(
        for action: AppShortcutAction,
        slot: AppShortcutSlot,
        globalChords: [ShortcutChord] = []
    ) -> AppShortcutBindingStatus? {
        guard let chord = binding(for: action)[slot] else { return nil }
        if globalChords.contains(chord) {
            return .disabled("Disabled: the global shortcut \(chord.glyphDescription) takes precedence.")
        }
        var owners = 0
        for other in AppShortcutAction.allCases {
            let binding = self.binding(for: other)
            for otherSlot in AppShortcutSlot.allCases where binding[otherSlot] == chord {
                owners += 1
            }
        }
        if owners > 1 {
            return .disabled("Disabled: \(chord.glyphDescription) is assigned more than once.")
        }
        if AppShortcutReservedKeys.reservedReason(for: chord) != nil {
            return .disabled("Disabled: \(chord.glyphDescription) is reserved.")
        }
        return .active
    }
}

// MARK: - Event matching

/// Pure keyboard-event → action resolution used by the app-wide key monitor.
enum AppShortcutEventMatcher {
    /// Returns the single action bound to the pressed chord, or nil when the
    /// chord is unbound, ambiguous (corrupted persistence), owned by a global
    /// hotkey, or deferred because editable text has focus.
    static func action(
        forKeyCode keyCode: UInt16,
        modifiers: ShortcutModifiers,
        isTextEditing: Bool,
        preferences: AppShortcutPreferences,
        globalChords: [ShortcutChord] = []
    ) -> AppShortcutAction? {
        var matched: [AppShortcutAction] = []
        var matchedChord: ShortcutChord?
        for action in AppShortcutAction.allCases {
            for chord in preferences.binding(for: action).chords
            where chord.matches(keyCode: keyCode, modifiers: modifiers) {
                matched.append(action)
                matchedChord = chord
            }
        }
        guard matched.count == 1, let action = matched.first, let chord = matchedChord else {
            return nil
        }
        if globalChords.contains(chord) { return nil }
        if AppShortcutReservedKeys.reservedReason(for: chord) != nil { return nil }
        if isTextEditing {
            if chord.yieldsToTextEditing { return nil }
            if action.defersToTextEditingWhenModified { return nil }
        }
        return action
    }
}

// MARK: - Persistence

enum AppShortcutPreferencesStore {
    static let defaultsKey = "appShortcutPreferencesV1"

    static func load(defaults: UserDefaults = .standard) -> AppShortcutPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(
                AppShortcutPreferences.self, from: data
              ),
              (1...AppShortcutPreferences.currentVersion).contains(preferences.version)
        else { return .defaults }
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
