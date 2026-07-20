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
    private static var closeGate: MainWindowCloseGate?

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

    /// Opens a named auxiliary SwiftUI scene even after the last workbench
    /// window has closed. The retained scene action outlives RootView, unlike
    /// an `onChange` observer embedded in that window's view hierarchy.
    static func openAuxiliaryWindow(id: String) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?(id: id)
    }

    static func installCloseGate(on window: NSWindow) {
        if closeGate?.window === window { return }
        let gate = MainWindowCloseGate(window: window, forwardingTo: window.delegate)
        closeGate = gate
        window.delegate = gate
    }
}

/// AppKit asks synchronously whether a window may close, while the editor's
/// acknowledged snapshot/save boundary is asynchronous. Veto the first close,
/// drain that exact participant, then replay the close only after durability
/// succeeds. A failed save/recovery therefore leaves the sole buffer mounted.
@MainActor
private final class MainWindowCloseGate: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    nonisolated(unsafe) private weak var forwardedDelegate: (any NSWindowDelegate)?
    private var preparationInFlight = false
    private var allowNextClose = false

    init(window: NSWindow, forwardingTo delegate: (any NSWindowDelegate)?) {
        self.window = window
        self.forwardedDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextClose {
            allowNextClose = false
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }
        if forwardedDelegate?.windowShouldClose?(sender) == false { return false }
        guard let model = AppTerminationDelegate.model,
              model.editorLifecycleCoordinator.hasActiveParticipant else { return true }
        guard !preparationInFlight else { return false }
        preparationInFlight = true
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            let prepared = await model.editorLifecycleCoordinator.prepare(
                for: .workbenchTeardown
            )
            self.preparationInFlight = false
            guard prepared else {
                model.errorMessage = "The window stayed open because the current note could not be saved or preserved for recovery."
                sender.makeKeyAndOrderFront(nil)
                return
            }
            self.allowNextClose = true
            sender.performClose(nil)
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
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
            guard let window = view.window else { return }
            window.identifier = AppWindowPresenter.mainWindowIdentifier
            AppWindowPresenter.installCloseGate(on: window)
        }
    }
}
