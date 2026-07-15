import AppKit
import Observation
import SwiftUI

@MainActor
final class GlobalRecordingIndicatorController: NSObject, NSWindowDelegate {
    private static let anchorDefaultsKey = "globalIndicatorScreenAnchorV1"
    private static let panelSize = CGSize(width: 72, height: 72)

    private let model: AppModel
    private let panel: GlobalRecordingPanel
    private var observers: [NSObjectProtocol] = []
    private var isRestoringPosition = false
    private var isDismissed = false
    private var wasCaptureActive = false
    private var lastAnnouncedState: String?

    init(model: AppModel) {
        self.model = model
        panel = GlobalRecordingPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: GlobalRecordingIndicatorView(
            model: model,
            onDismiss: { [weak self] in
                self?.isDismissed = true
                self?.panel.orderOut(nil)
            }
        ))
        panel.setContentSize(Self.panelSize)
        panel.setAccessibilityTitle("Transcride global recording status")

        restorePosition()
        installObservers()
        observeModel()
    }

    func shutdown() {
        panel.orderOut(nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoringPosition else { return }
        savePosition()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            let source: NotificationCenter = name == NSWorkspace.didWakeNotification ||
                name == NSWorkspace.sessionDidBecomeActiveNotification
                ? NSWorkspace.shared.notificationCenter : center
            observers.append(source.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.restorePosition()
                    self?.updateVisibility()
                    if name == NSWorkspace.didWakeNotification ||
                        name == NSWorkspace.sessionDidBecomeActiveNotification {
                        self?.model.globalShortcutService.apply(
                            self?.model.globalShortcutPreferences ?? .defaults
                        )
                    }
                }
            })
        }
        observers.append(center.addObserver(
            forName: .resetGlobalIndicatorPosition, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetPosition() }
        })
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.globalShortcutPreferences
            _ = model.globalRecordingPresentationState
            _ = model.isGlobalIndicatorRetentionActive
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateVisibility()
                self?.observeModel()
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let preferences = model.globalShortcutPreferences
        let presentationState = model.globalRecordingPresentationState
        let isCaptureActive = presentationState.isCaptureActive
        if isCaptureActive && !wasCaptureActive {
            isDismissed = false
        }
        wasCaptureActive = isCaptureActive
        let belongsToVisibleSession = presentationState.belongsToRecordingSession ||
            model.isGlobalIndicatorRetentionActive
        let shouldShow = preferences.isEnabled &&
            preferences.showsBackgroundIndicator &&
            belongsToVisibleSession &&
            !NSApp.isActive &&
            !isDismissed
        if shouldShow {
            if !panel.isVisible {
                restorePosition()
                panel.orderFrontRegardless()
            }
            announceStateChangeIfNeeded(presentationState)
        } else {
            panel.orderOut(nil)
        }
    }

    private func announceStateChangeIfNeeded(_ state: GlobalRecordingPresentationState) {
        let announcement: String
        let kind: String
        switch state {
        case .hidden:
            return
        case .ready:
            kind = "ready"; announcement = "Transcride ready to record"
        case .recording:
            kind = "recording"; announcement = "Transcride recording"
        case .paused:
            kind = "paused"; announcement = "Transcride recording paused"
        case .saving:
            kind = "saving"; announcement = "Transcride saving recording"
        case .saved:
            kind = "saved"; announcement = "Transcride recording saved"
        case .needsAttention(let message):
            kind = "attention"; announcement = "Transcride needs attention. \(message)"
        case .saveFailed(let message):
            kind = "failed"; announcement = "Transcride save failed. \(message)"
        case .unavailable(let message, _):
            kind = "unavailable"; announcement = "Transcride command unavailable. \(message)"
        }
        guard kind != lastAnnouncedState else { return }
        lastAnnouncedState = kind
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorDefaultsKey)
        restorePosition(anchor: GlobalIndicatorScreenAnchor(
            displayID: displayID(for: NSScreen.main), normalizedX: 0.97, normalizedY: 0.93
        ))
    }

    private func restorePosition() {
        let anchor: GlobalIndicatorScreenAnchor
        if let data = UserDefaults.standard.data(forKey: Self.anchorDefaultsKey),
           let decoded = try? JSONDecoder().decode(GlobalIndicatorScreenAnchor.self, from: data) {
            anchor = decoded
        } else {
            anchor = GlobalIndicatorScreenAnchor(
                displayID: displayID(for: NSScreen.main), normalizedX: 0.97, normalizedY: 0.93
            )
        }
        restorePosition(anchor: anchor)
    }

    private func restorePosition(anchor: GlobalIndicatorScreenAnchor) {
        let screen = NSScreen.screens.first { displayID(for: $0) == anchor.displayID }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        isRestoringPosition = true
        panel.setFrame(
            anchor.restoredFrame(size: Self.panelSize, visibleFrame: screen.visibleFrame),
            display: panel.isVisible
        )
        isRestoringPosition = false
        savePosition()
    }

    private func savePosition() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let anchor = GlobalIndicatorScreenAnchor.capture(
            frame: panel.frame,
            visibleFrame: screen.visibleFrame,
            displayID: displayID(for: screen)
        )
        if let data = try? JSONEncoder().encode(anchor) {
            UserDefaults.standard.set(data, forKey: Self.anchorDefaultsKey)
        }
    }

    private func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}

private final class GlobalRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct GlobalRecordingIndicatorView: View {
    @Bindable var model: AppModel
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var isHovering = false

    var body: some View {
        // Resolve recorder/vault readiness only when observed model state
        // changes. The animation clock below must not repeat permission,
        // device, and free-disk checks 24 times per second.
        let state = model.globalRecordingPresentationState
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
            ZStack(alignment: .topTrailing) {
                stateIcon(state, date: context.date)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                    .gesture(
                        // Fail the hold before macOS can interpret even a slow,
                        // deliberate movement as both a panel drag and a long press.
                        LongPressGesture(minimumDuration: 0.55, maximumDistance: 1)
                            .exclusively(before: TapGesture())
                            .onEnded { gesture in
                                switch gesture {
                                case .first:
                                    bringTranscrideForward()
                                case .second:
                                    Task { await model.toggleRecordingFromIndicator() }
                                }
                            }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: state))
                    .accessibilityHint("Click to start or stop recording. Hold to bring Transcride forward. Drag to move the indicator.")

                if isHovering {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.black.opacity(0.78), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide recording indicator")
                    .accessibilityLabel("Hide recording indicator")
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: GlobalRecordingPresentationState, date: Date) -> some View {
        switch state {
        case .recording:
            let phase = reduceMotion ? 0 : (date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.4) / 1.4)
            let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2
            ZStack {
                if !reduceMotion {
                    Circle().fill(.red.opacity(0.16 + wave * 0.18))
                        .scaleEffect(0.86 + wave * 0.14)
                }
                Circle().fill(.red).frame(width: 48, height: 48)
                if differentiateWithoutColor {
                    Circle().stroke(.primary, lineWidth: 2).frame(width: 48, height: 48)
                }
            }
        case .paused:
            ZStack {
                Circle().fill(.red).frame(width: 48, height: 48)
                Image(systemName: "pause.fill").foregroundStyle(.white)
            }
        case .saved:
            ZStack {
                Circle().fill(.red).frame(width: 48, height: 48)
                Image(systemName: "checkmark").foregroundStyle(.white)
                    .font(.system(size: 22, weight: .bold))
            }
        case .saving:
            ZStack {
                Circle().fill(.red).frame(width: 48, height: 48)
                ProgressView().controlSize(.small).tint(.white)
            }
        case .ready:
            Circle().fill(.red).frame(width: 48, height: 48)
        case .needsAttention, .saveFailed, .unavailable:
            ZStack {
                Circle().fill(.red).frame(width: 48, height: 48)
                Image(systemName: "exclamationmark").foregroundStyle(.white)
                    .font(.system(size: 22, weight: .bold))
            }
        case .hidden:
            EmptyView()
        }
    }

    private func bringTranscrideForward() {
        _ = AppWindowPresenter.showExistingMainWindow()
    }

    private func title(for state: GlobalRecordingPresentationState) -> String {
        switch state {
        case .hidden: ""
        case .ready: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .saving: "Saving…"
        case .saved: "Recording Saved"
        case .needsAttention: "Needs Attention"
        case .saveFailed: "Save Failed — Recoverable"
        case .unavailable: "Unavailable"
        }
    }

    private func detail(for state: GlobalRecordingPresentationState) -> String {
        switch state {
        case .hidden: ""
        case .ready(let shortcut): "Start: \(shortcut)"
        case .recording(let elapsed, let pause, let stop):
            "\(format(elapsed))  Pause \(pause) · Save \(stop)"
        case .paused(let elapsed, let pause, let stop):
            "\(format(elapsed))  Resume \(pause) · Save \(stop)"
        case .saving(let elapsed): "Finalizing \(format(elapsed))"
        case .saved(let duration, _): "Saved \(format(duration))"
        case .needsAttention(let message), .saveFailed(let message),
             .unavailable(let message, _): message
        }
    }

    private func accessibilityDescription(for state: GlobalRecordingPresentationState) -> String {
        "Transcride. \(title(for: state)). \(detail(for: state))"
    }

    private func format(_ duration: Double) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
