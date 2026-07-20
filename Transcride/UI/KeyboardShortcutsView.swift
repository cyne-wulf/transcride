import SwiftUI

/// In-app reference reached from Help → Keyboard Shortcuts.
struct KeyboardShortcutsCommands: Commands {
    static let windowID = "keyboard-shortcuts"

    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(
                AppShortcutMenu.title(
                    "Keyboard Shortcuts…",
                    action: .showKeyboardShortcuts,
                    model: model
                )
            ) {
                model.performAppCommand(.showKeyboardShortcuts)
            }
            .appShortcutMenu(.showKeyboardShortcuts, model: model)
        }
    }
}

struct KeyboardShortcutsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var receivesEscape: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.title2.weight(.semibold))

            Text("This reference follows your current Keybinds settings, including alternate assignments.")
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .padding(.bottom, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    shortcutSection("Global Controls", rows: globalRecordingRows)

                    ForEach(AppShortcutCategory.allCases) { category in
                        shortcutSection(category.title, rows: appRows(in: category))
                    }

                    shortcutSection("Fixed Navigation", rows: fixedNavigationRows)
                }
            }
        }
        .padding(28)
        .frame(width: 660, height: 680, alignment: .topLeading)
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
            let chord = model.globalShortcutPreferences.bindings[action] ?? nil
            var detail = "Works from other apps while Transcride is running."
            if !model.globalShortcutPreferences.isEnabled {
                detail += " Global controls are currently disabled."
            } else if case .failed(let message) =
                        model.globalShortcutService.statuses[action] ?? .disabled {
                detail += " Registration issue: \(message)"
            }
            return ShortcutRow(
                bindings: chord.map {
                    [ShortcutBindingDisplay(slot: nil, glyph: $0.glyphDescription)]
                } ?? [ShortcutBindingDisplay(slot: nil, glyph: "Not set")],
                title: action.title,
                detail: detail,
                scope: .global
            )
        }
    }

    private func appRows(in category: AppShortcutCategory) -> [ShortcutRow] {
        AppShortcutAction.allCases
            .filter { $0.category == category }
            .map { action in
                let bindingSet = model.appShortcutPreferences.bindingSet(for: action)
                var bindings: [ShortcutBindingDisplay] = []
                if let primary = bindingSet.primary {
                    bindings.append(
                        ShortcutBindingDisplay(
                            slot: AppShortcutSlot.primary.title,
                            glyph: primary.glyphDescription
                        )
                    )
                }
                if let alternate = bindingSet.alternate {
                    bindings.append(
                        ShortcutBindingDisplay(
                            slot: AppShortcutSlot.alternate.title,
                            glyph: alternate.glyphDescription
                        )
                    )
                }
                if bindings.isEmpty {
                    bindings = [ShortcutBindingDisplay(slot: nil, glyph: "Not set")]
                }

                let warnings = AppShortcutSlot.allCases.compactMap { slot -> String? in
                    let status = model.appShortcutPreferences.validationStatus(
                        for: action,
                        slot: slot,
                        globalBindings: model.assignedGlobalShortcutBindings
                    )
                    switch status {
                    case .available, .unassigned:
                        return nil
                    default:
                        return status.message.map { "\(slot.title): \($0)" }
                    }
                }
                let warningDetail = warnings.isEmpty
                    ? ""
                    : " Assignment warning: \(warnings.joined(separator: " "))"

                return ShortcutRow(
                    bindings: bindings,
                    title: action.title,
                    detail: action.detail + warningDetail,
                    scope: .inApp
                )
            }
    }

    private var fixedNavigationRows: [ShortcutRow] {
        [
            ShortcutRow(
                bindings: [.init(slot: nil, glyph: "Esc")],
                title: "Cancel or leave the current mode",
                detail: "Sheets, dialogs, and active workflows keep standard Escape behavior.",
                scope: .native
            ),
            ShortcutRow(
                bindings: [.init(slot: nil, glyph: "↩ / Tab")],
                title: "Confirm and move focus",
                detail: "Return and Tab stay native to controls and dialogs.",
                scope: .native
            ),
            ShortcutRow(
                bindings: [.init(slot: nil, glyph: "↑ / ↓")],
                title: "Move through lists",
                detail: "Plain Up and Down remain native list navigation.",
                scope: .native
            ),
            ShortcutRow(
                bindings: [.init(slot: nil, glyph: "⌫")],
                title: "Delete text or the focused item",
                detail: "Unmodified Delete remains owned by the focused native control.",
                scope: .native
            ),
        ]
    }

    private func shortcutSection(
        _ title: String,
        rows: [ShortcutRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 198) }
                    shortcutRow(row)
                        .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func shortcutRow(_ row: ShortcutRow) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .trailing, spacing: 5) {
                ForEach(Array(row.bindings.enumerated()), id: \.offset) { _, binding in
                    HStack(spacing: 6) {
                        if let slot = binding.slot {
                            Text(slot)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(binding.glyph)
                            .font(.system(.callout, design: .rounded, weight: .medium))
                            .padding(.horizontal, 7)
                            .frame(minWidth: 48, minHeight: 26)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                    }
                }
            }
            .frame(width: 180, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(row.title)
                    Text(row.scope.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(row.scope.foregroundStyle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            row.scope.backgroundStyle,
                            in: Capsule()
                        )
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityDescription)
    }
}

private enum ShortcutScope {
    case inApp
    case global
    case native

    var title: String {
        switch self {
        case .inApp: "In App"
        case .global: "Global"
        case .native: "Fixed"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .inApp: .secondary
        case .global: .accentColor
        case .native: .secondary
        }
    }

    var backgroundStyle: Color {
        switch self {
        case .inApp: .secondary.opacity(0.12)
        case .global: .accentColor.opacity(0.12)
        case .native: .secondary.opacity(0.12)
        }
    }
}

private struct ShortcutBindingDisplay {
    let slot: String?
    let glyph: String
}

private struct ShortcutRow {
    let bindings: [ShortcutBindingDisplay]
    let title: String
    let detail: String
    let scope: ShortcutScope

    var accessibilityDescription: String {
        let assignments = bindings.map { binding in
            [binding.slot, binding.glyph].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ")
        return "\(assignments): \(title). \(scope.title). \(detail)"
    }
}
