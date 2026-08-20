import SwiftUI

extension ShortcutChord {
    /// SwiftUI menu key equivalent for this chord. Bare and shift-only chords
    /// return nil: they stay monitor-owned so a menu equivalent can never
    /// steal keys from text editing.
    var menuKeyEquivalent: KeyboardShortcut? {
        guard !yieldsToTextEditing else { return nil }
        guard let key = Self.keyEquivalent(for: keyCode) else { return nil }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    private static func keyEquivalent(for keyCode: UInt32) -> KeyEquivalent? {
        switch keyCode {
        case 49: return .space
        case 51: return .delete
        case 117: return .deleteForward
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default: break
        }
        let characters: [UInt32: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: ".", 50: "`",
        ]
        guard let character = characters[keyCode] else { return nil }
        return KeyEquivalent(character)
    }
}

extension AppModel {
    /// The binding a menu item displays: the primary when it is menu-safe and
    /// active, otherwise a menu-safe active alternate (so a command whose
    /// primary is a monitor-owned bare key still shows its modified chord).
    func menuShortcut(for action: AppShortcutAction) -> KeyboardShortcut? {
        guard !action.defersToTextEditingWhenModified else { return nil }
        for slot in AppShortcutSlot.allCases {
            guard let chord = appShortcutPreferences.chord(for: action, slot: slot),
                  appShortcutPreferences.status(
                      for: action, slot: slot, globalChords: configuredGlobalChords
                  ) == .active,
                  let equivalent = chord.menuKeyEquivalent
            else { continue }
            return equivalent
        }
        return nil
    }
}
