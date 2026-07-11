import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model,
              model.recorder.state == .recording || model.recorder.state == .paused
        else { return .terminateNow }

        let extending = model.recorder.extensionSession != nil
        let alert = NSAlert()
        alert.messageText = extending ? "Finish Extending Before Quitting?" : "Finish Recording Before Quitting?"
        alert.informativeText = extending
            ? "Stop and Finish appends the captured extension safely before Transcride quits. Quit and Recover Later leaves the crash-safe segment untouched and offers recovery next launch."
            : "Stop and Save finalizes the recording before Transcride quits. Quit and Recover Later leaves the crash-safe journal untouched and restores it next launch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: extending ? "Stop, Finish, and Quit" : "Stop, Save, and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit and Recover Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await model.stopRecording()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
