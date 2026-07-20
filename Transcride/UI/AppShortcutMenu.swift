import SwiftUI

/// Bridges the physical-key shortcut model to SwiftUI menu presentation.
/// The local event monitor remains authoritative for every remappable command.
/// SwiftUI's menu equivalents are character-based rather than physical-key
/// based, so installing one would create a second, layout-dependent dispatch
/// path and could also preempt the shortcut-capture field.
@MainActor
enum AppShortcutMenu {
    static func activePrimary(
        for action: AppShortcutAction,
        model: AppModel
    ) -> ShortcutChord? {
        guard model.appShortcutPreferences.validationStatus(
            for: action,
            slot: .primary,
            globalBindings: model.assignedGlobalShortcutBindings
        ) == .available else { return nil }
        return model.appShortcutPreferences[action, .primary]
    }

    static func title(
        _ base: String,
        action: AppShortcutAction,
        model: AppModel
    ) -> String {
        guard let chord = activePrimary(for: action, model: model) else { return base }
        return "\(base)  \(chord.glyphDescription)"
    }
}

private struct AppShortcutMenuModifier: ViewModifier {
    let action: AppShortcutAction
    let model: AppModel

    func body(content: Content) -> some View {
        // Deliberately no `.keyboardShortcut`: AppModel's physical-key
        // matcher is the single keyboard dispatcher. The modifier still reads
        // the model so command declarations retain one uniform call site.
        _ = action
        _ = model
        return content
    }
}

extension View {
    func appShortcutMenu(
        _ action: AppShortcutAction,
        model: AppModel
    ) -> some View {
        modifier(AppShortcutMenuModifier(action: action, model: model))
    }
}
