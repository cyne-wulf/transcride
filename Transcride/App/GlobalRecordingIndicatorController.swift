import AppKit
import Observation
import SwiftUI

@MainActor
final class GlobalRecordingIndicatorController: NSObject, NSWindowDelegate {
    private static let anchorDefaultsKey = "globalIndicatorScreenAnchorV1"
    private static let panelSize = CGSize(width: 270, height: 104)

    private let model: AppModel
    private let panel: GlobalRecordingPanel
    private var observers: [NSObjectProtocol] = []
    private var isRestoringPosition = false
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
        panel.contentView = NSHostingView(rootView: GlobalRecordingIndicatorView(model: model))
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
        let shouldShow = preferences.isEnabled &&
            preferences.showsBackgroundIndicator && !NSApp.isActive
        if shouldShow {
            restorePosition()
            panel.orderFrontRegardless()
            announceStateChangeIfNeeded(model.globalRecordingPresentationState)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let state = model.globalRecordingPresentationState
            HStack(spacing: 14) {
                stateIcon(state, date: context.date)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: state))
                        .font(.headline)
                    Text(detail(for: state))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(width: 270, height: 104)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(contrast == .increased ? Color.primary : Color.primary.opacity(0.15), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription(for: state))
            .accessibilityHint("Click to bring Transcride forward. Drag to move the indicator.")
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
                    Circle().stroke(.red.opacity(0.2 + wave * 0.35), lineWidth: 2)
                        .scaleEffect(1.0 + wave * 0.18)
                }
                Circle().fill(.red).frame(width: 22, height: 22)
                if differentiateWithoutColor {
                    Circle().stroke(.primary, lineWidth: 2).frame(width: 22, height: 22)
                }
            }
        case .paused:
            ZStack {
                Circle().stroke(.red, lineWidth: 3)
                Image(systemName: "pause.fill").foregroundStyle(.red)
            }
        case .saved:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 30))
        case .saving:
            ProgressView().controlSize(.small)
        case .ready:
            Circle().stroke(.red, lineWidth: 3).padding(4)
        case .needsAttention, .saveFailed, .unavailable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .font(.system(size: 28))
        case .hidden:
            EmptyView()
        }
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
