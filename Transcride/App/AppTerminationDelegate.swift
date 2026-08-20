import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var indicatorController: GlobalRecordingIndicatorController?
    private var menuBarItemController: MenuBarItemController?

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

    /// Defense in depth for the shortcut-capture flag. `ShortcutCaptureField`
    /// already ends capture when its window resigns key, but that flag
    /// suppresses every app shortcut while it is set, so a capture control torn
    /// down in some way the view layer did not anticipate must never be able to
    /// disable the keyboard permanently. Idempotent in the normal path.
    func applicationDidResignActive(_ notification: Notification) {
        Self.model?.isShortcutCaptureActive = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        indicatorController?.shutdown()
        menuBarItemController?.shutdown()
        Self.model?.shutdownGlobalRecordingControls()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        if model.isRecordingStartInFlight || model.recorder.state == .finalizing {
            // Finalizing a long recording can take minutes, so an OK-only
            // "try again later" is not an acceptable answer to Quit: it leaves
            // the user with no way out but Force Quit. Offer to quit *after*
            // the save completes, and keep an immediate escape that is safe
            // because the crash-safe journal is still on disk.
            let starting = model.isRecordingStartInFlight
            let alert = NSAlert()
            alert.messageText = starting
                ? "Starting the Microphone…"
                : "Saving Your Recording…"
            alert.informativeText = starting
                ? "Transcride is still starting the microphone. Quit After Saving waits for it to settle and then quits."
                : "Transcride is writing the recording to disk, which can take a while for a long recording. Quit After Saving quits as soon as the file is safely written. Quit Now leaves the crash-safe journal untouched; Transcride restores the recording from it on the next launch."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Quit After Saving")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Now")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await model.stopRecordingForTermination()
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertThirdButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        guard model.recorder.state == .recording || model.recorder.state == .paused else {
            return .terminateNow
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
            Task { @MainActor in
                // Not `stopRecording()`: a stop already in flight would make
                // that call return instantly through the command gate's
                // repeat suppression, and the process would exit mid-encode.
                await model.stopRecordingForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            Task { @MainActor in
                await model.prepareActiveRecordingForDeferredRecovery()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}
