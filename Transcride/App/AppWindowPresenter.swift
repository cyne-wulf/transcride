import AppKit
import SwiftUI

/// Identifies and presents Transcride's one main workbench window. Auxiliary
/// Settings, About, and keyboard-help windows must never satisfy an "Open
/// Transcride" request from a background control surface.
@MainActor
enum AppWindowPresenter {
    static let mainWindowSceneID = "transcride-main-window"
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier(mainWindowSceneID)

    private static var openWindowAction: OpenWindowAction?
    private static var openSettingsAction: OpenSettingsAction?

    static func configureSceneActions(
        openWindow: OpenWindowAction,
        openSettings: OpenSettingsAction
    ) {
        openWindowAction = openWindow
        openSettingsAction = openSettings
    }

    @discardableResult
    static func showExistingMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == mainWindowIdentifier
        }) else { return false }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func openMainWindow() {
        guard !showExistingMainWindow() else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let openWindowAction else {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(
                NSApp, hasVisibleWindows: false
            )
            return
        }
        openWindowAction(id: mainWindowSceneID)
        DispatchQueue.main.async {
            _ = showExistingMainWindow()
        }
    }

    static func openSettings() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// Captures scene-level actions for AppKit-owned surfaces such as the status
/// item. Retaining these actions lets Open Transcride recreate a WindowGroup
/// window after its previous window has been fully closed.
struct AppSceneActionBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppWindowPresenter.configureSceneActions(
                    openWindow: openWindow,
                    openSettings: openSettings
                )
            }
    }
}

/// SwiftUI does not expose the backing NSWindow directly. This zero-size bridge
/// gives the workbench window a stable identifier as soon as it is attached.
struct MainWindowIdentityView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        identifyWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        identifyWindow(for: nsView)
    }

    private func identifyWindow(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.identifier = AppWindowPresenter.mainWindowIdentifier
        }
    }
}
