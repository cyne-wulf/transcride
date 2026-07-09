import SwiftUI

/// In-app reference reached from Help → Keyboard Shortcuts.
struct KeyboardShortcutsCommands: Commands {
    static let windowID = "keyboard-shortcuts"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts…") {
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.title2.weight(.semibold))

            Text("Quick controls for recording and navigating Transcride.")
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    shortcutSection("Recording", rows: [
                        ShortcutRow(
                            keys: ["⇧", "Space"],
                            title: "Start or stop recording",
                            detail: "Available throughout the app."
                        ),
                        ShortcutRow(
                            keys: ["Space"],
                            title: "Pause or resume recording",
                            detail: "When no recording is active, controls playback instead."
                        ),
                    ])

                    shortcutSection("Zen Mode", rows: [
                        ShortcutRow(
                            keys: ["Z"],
                            title: "Enter Zen mode",
                            detail: "Text fields keep normal typing behavior."
                        ),
                        ShortcutRow(
                            keys: ["esc"],
                            title: "Leave Zen mode",
                            detail: "Stop the recording first."
                        ),
                    ])

                    shortcutSection("Library", rows: [
                        ShortcutRow(
                            keys: ["⌘", "⇧", "I"],
                            title: "Import audio",
                            detail: "Choose one or more supported audio or video files."
                        ),
                        ShortcutRow(
                            keys: ["⇧", "⌫"],
                            title: "Move selected entry to Recently Deleted",
                            detail: "The entry remains restorable for 30 days."
                        ),
                    ])
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 520, alignment: .topLeading)
    }

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
        .accessibilityLabel("\(row.keys.joined(separator: " plus ")): \(row.title). \(row.detail)")
    }
}

private struct ShortcutRow {
    let keys: [String]
    let title: String
    let detail: String
}
