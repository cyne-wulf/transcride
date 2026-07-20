import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var indicatorController: GlobalRecordingIndicatorController?
    private var menuBarItemController: MenuBarItemController?
    private var editorTerminationInFlight = false

    func configure(model: AppModel) {
        Self.model = model
        if indicatorController == nil {
            indicatorController = GlobalRecordingIndicatorController(model: model)
        }
        if menuBarItemController == nil {
            menuBarItemController = MenuBarItemController(model: model)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            if !AppWindowPresenter.showExistingMainWindow() {
                sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        indicatorController?.shutdown()
        menuBarItemController?.shutdown()
        Self.model?.shutdownGlobalRecordingControls()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard !editorTerminationInFlight else { return .terminateLater }

        let recordingIsActive = model.recorder.state == .recording
            || model.recorder.state == .paused
        if !recordingIsActive {
            guard model.editorLifecycleCoordinator.hasActiveParticipant else {
                return .terminateNow
            }
            editorTerminationInFlight = true
            Task { @MainActor in
                let saved = await model.editorLifecycleCoordinator.prepare(
                    for: .applicationTermination
                )
                self.editorTerminationInFlight = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }

        let extending = model.recorder.extensionSession != nil
        let replacing: Bool
        if case .replacementTake? = model.recorder.sessionTarget {
            replacing = true
        } else {
            replacing = false
        }
        let alert = NSAlert()
        alert.messageText = replacing
            ? "Finish the Replacement Take Before Quitting?"
            : (extending ? "Finish Extending Before Quitting?" : "Finish Recording Before Quitting?")
        alert.informativeText = replacing
            ? "Stop and Keep Take saves the attempt as incomplete. Quit and Recover Later leaves the crash-safe take untouched and offers it for review next launch; it is never baked automatically."
            : extending
            ? "Stop and Finish appends the captured extension safely before Transcride quits. Quit and Recover Later leaves the crash-safe segment untouched and offers recovery next launch."
            : "Stop and Save finalizes the recording before Transcride quits. Quit and Recover Later leaves the crash-safe journal untouched and restores it next launch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: replacing
            ? "Stop, Keep Take, and Quit"
            : (extending ? "Stop, Finish, and Quit" : "Stop, Save, and Quit"))
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit and Recover Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            editorTerminationInFlight = true
            Task { @MainActor in
                await model.stopRecording()
                let saved = await model.editorLifecycleCoordinator.prepare(
                    for: .applicationTermination
                )
                self.editorTerminationInFlight = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            editorTerminationInFlight = true
            Task { @MainActor in
                let saved = await model.editorLifecycleCoordinator.prepare(
                    for: .applicationTermination
                )
                self.editorTerminationInFlight = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}
