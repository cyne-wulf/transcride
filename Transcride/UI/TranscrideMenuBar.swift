import AppKit
import Foundation
import Observation

enum MenuBarRecorderPhase: Equatable {
    case idle
    case recording
    case paused
    case finalizing
}

enum MenuBarRecordingStatus: Equatable {
    case hidden
    case ready
    case recording
    case paused
    case saving
    case saved(duration: Double)
    case needsAttention(String)
    case saveFailed(String)
    case unavailable(String)

    init(_ state: GlobalRecordingPresentationState) {
        self = switch state {
        case .hidden:
            .hidden
        case .ready:
            .ready
        case .recording:
            .recording
        case .paused:
            .paused
        case .saving:
            .saving
        case .saved(let duration, _):
            .saved(duration: duration)
        case .needsAttention(let message):
            .needsAttention(message)
        case .saveFailed(let message):
            .saveFailed(message)
        case .unavailable(let message, _):
            .unavailable(message)
        }
    }

    var symbolName: String {
        switch self {
        case .hidden, .ready: "captions.bubble"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .saving: "ellipsis.bubble"
        case .saved: "checkmark.bubble.fill"
        case .needsAttention, .saveFailed, .unavailable:
            "exclamationmark.bubble.fill"
        }
    }

    func title(liveElapsed: Double) -> String {
        switch self {
        case .hidden:
            "Transcride"
        case .ready:
            "Ready to Record"
        case .recording:
            "Recording · \(Self.duration(liveElapsed))"
        case .paused:
            "Paused · \(Self.duration(liveElapsed))"
        case .saving:
            "Saving… · \(Self.duration(liveElapsed))"
        case .saved(let duration):
            "Recording Saved · \(Self.duration(duration))"
        case .needsAttention(let message):
            "Needs Attention — \(message)"
        case .saveFailed(let message):
            "Save Failed — \(message)"
        case .unavailable(let message):
            "Unavailable — \(message)"
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A discrete menu snapshot. Active elapsed time is intentionally absent so
/// audio-buffer updates cannot invalidate or reconstruct the native menu.
struct MenuBarControlSnapshot: Equatable {
    var status: MenuBarRecordingStatus
    var primaryActionTitle: String
    var primaryActionEnabled: Bool
    var pauseActionTitle: String
    var pauseActionEnabled: Bool
    var registrationSummary: String?

    static func make(
        presentationState: GlobalRecordingPresentationState,
        recorderPhase: MenuBarRecorderPhase,
        preferences: GlobalShortcutPreferences,
        registrationStatuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus]
    ) -> Self {
        let primaryTitle: String
        switch recorderPhase {
        case .idle:
            primaryTitle = "Start Recording"
        case .recording, .paused:
            primaryTitle = "Stop & Save Recording"
        case .finalizing:
            primaryTitle = "Saving Recording…"
        }

        let pauseTitle = recorderPhase == .paused
            ? "Resume Recording"
            : "Pause Recording"
        let primaryShortcut = shortcutDisplay(
            for: .toggleRecording,
            preferences: preferences,
            statuses: registrationStatuses
        )
        let pauseShortcut = shortcutDisplay(
            for: .pauseResumeRecording,
            preferences: preferences,
            statuses: registrationStatuses
        )

        return Self(
            status: MenuBarRecordingStatus(presentationState),
            primaryActionTitle: "\(primaryTitle)    \(primaryShortcut)",
            primaryActionEnabled: recorderPhase != .finalizing,
            pauseActionTitle: "\(pauseTitle)    \(pauseShortcut)",
            pauseActionEnabled: recorderPhase == .recording || recorderPhase == .paused,
            registrationSummary: registrationSummary(
                preferences: preferences,
                statuses: registrationStatuses
            )
        )
    }

    private static func shortcutDisplay(
        for action: GlobalShortcutAction,
        preferences: GlobalShortcutPreferences,
        statuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus]
    ) -> String {
        guard let chord = preferences.bindings[action] ?? nil else {
            return "No shortcut"
        }
        let glyph = chord.glyphDescription
        switch statuses[action] ?? .disabled {
        case .registered:
            return glyph
        case .cleared:
            return "No shortcut"
        case .disabled:
            return "\(glyph) — Off"
        case .failed:
            return "\(glyph) — Unavailable"
        }
    }

    private static func registrationSummary(
        preferences: GlobalShortcutPreferences,
        statuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus]
    ) -> String? {
        guard preferences.isEnabled else {
            return "Global shortcuts are disabled; menu controls still work."
        }
        for action in GlobalShortcutAction.allCases {
            if case .failed(let message) = statuses[action] {
                return "\(action.title): \(message)"
            }
        }
        return nil
    }
}

/// Owns one stable NSMenu graph. Titles, symbols, and enablement mutate in
/// place while AppKit is tracking the pointer, so a live timer can never move
/// the highlighted row to a different menu item.
@MainActor
final class MenuBarItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusBar: NSStatusBar?
    private let menu = NSMenu()
    private let statusHeaderItem = NSMenuItem()
    private let primaryActionItem = NSMenuItem()
    private let pauseActionItem = NSMenuItem()
    private let showFloatingWidgetItem = NSMenuItem()
    private let registrationItem = NSMenuItem()
    private let openItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let hideItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var systemStatusItem: NSStatusItem?
    private var elapsedTimer: Timer?
    private var isMenuOpen = false
    private var isShutdown = false
    private var latestSnapshot: MenuBarControlSnapshot?
    private var lastStatusTitle: String?

    init(model: AppModel, statusBar: NSStatusBar? = .system) {
        self.model = model
        self.statusBar = statusBar
        super.init()
        configureMenu()
        refresh(allowLayoutChanges: true)
        observeModel()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        stopElapsedTimer()
        removeStatusItem()
        menu.delegate = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh(allowLayoutChanges: true)
        isMenuOpen = true
        startElapsedTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopElapsedTimer()
        isMenuOpen = false
        refresh(allowLayoutChanges: true)
    }

    var menuItemIdentitiesForTesting: [ObjectIdentifier] {
        menu.items.map(ObjectIdentifier.init)
    }

    var menuItemTitlesForTesting: [String] {
        menu.items.map(\.title)
    }

    func refreshForTesting() {
        refresh(allowLayoutChanges: !isMenuOpen)
    }

    func showFloatingWidgetForTesting() {
        _ = showFloatingWidgetItem.target?.perform(
            showFloatingWidgetItem.action,
            with: showFloatingWidgetItem
        )
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        statusHeaderItem.isEnabled = false
        registrationItem.isEnabled = false

        primaryActionItem.target = self
        primaryActionItem.action = #selector(performPrimaryAction)
        pauseActionItem.target = self
        pauseActionItem.action = #selector(performPauseAction)

        showFloatingWidgetItem.title = "Show Floating Widget"
        showFloatingWidgetItem.target = self
        showFloatingWidgetItem.action = #selector(showFloatingWidget)

        openItem.title = "Open Transcride"
        openItem.target = self
        openItem.action = #selector(openTranscride)

        settingsItem.title = "Settings…"
        settingsItem.target = self
        settingsItem.action = #selector(openSettings)

        hideItem.title = "Hide Menu Bar Item"
        hideItem.target = self
        hideItem.action = #selector(hideMenuBarItem)

        quitItem.title = "Quit Transcride"
        quitItem.target = self
        quitItem.action = #selector(quitTranscride)

        menu.items = [
            statusHeaderItem,
            .separator(),
            primaryActionItem,
            pauseActionItem,
            showFloatingWidgetItem,
            registrationItem,
            .separator(),
            openItem,
            settingsItem,
            .separator(),
            hideItem,
            quitItem,
        ]
    }

    private func observeModel() {
        guard !isShutdown else { return }
        withObservationTracking {
            _ = model.globalShortcutPreferences
            _ = model.globalShortcutService.statuses
            _ = model.recorder.state
            _ = model.globalRecordingTransientState
            _ = model.phase
            _ = model.recorder.alertMessage
            _ = model.inputDevices.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShutdown else { return }
                self.refresh(allowLayoutChanges: !self.isMenuOpen)
                self.observeModel()
            }
        }
    }

    private func refresh(allowLayoutChanges: Bool) {
        let preferences = model.globalShortcutPreferences
        if preferences.showsMenuBarItem {
            ensureStatusItem()
        } else {
            removeStatusItem()
        }

        let snapshot = MenuBarControlSnapshot.make(
            presentationState: model.menuBarRecordingPresentationState,
            recorderPhase: recorderPhase,
            preferences: preferences,
            registrationStatuses: model.globalShortcutService.statuses
        )
        latestSnapshot = snapshot

        primaryActionItem.title = snapshot.primaryActionTitle
        primaryActionItem.isEnabled = snapshot.primaryActionEnabled
        pauseActionItem.title = snapshot.pauseActionTitle
        pauseActionItem.isEnabled = snapshot.pauseActionEnabled
        // The override only ends at the widget's own dismiss control, so the
        // menu item reports the active override instead of toggling it.
        showFloatingWidgetItem.state = model.isGlobalIndicatorManuallyPresented ? .on : .off

        if allowLayoutChanges {
            registrationItem.isHidden = snapshot.registrationSummary == nil
        }
        if !registrationItem.isHidden, let summary = snapshot.registrationSummary {
            registrationItem.title = summary
        }

        updateStatusDisplay(snapshot)
    }

    private var recorderPhase: MenuBarRecorderPhase {
        switch model.recorder.state {
        case .idle: .idle
        case .recording: .recording
        case .paused: .paused
        case .finalizing: .finalizing
        }
    }

    private func updateStatusDisplay(_ snapshot: MenuBarControlSnapshot) {
        let title = snapshot.status.title(liveElapsed: model.recorder.elapsed)
        if title != lastStatusTitle {
            statusHeaderItem.title = title
            statusHeaderItem.toolTip = title
            lastStatusTitle = title
        }

        let image = Self.symbolImage(named: snapshot.status.symbolName)
        statusHeaderItem.image = image
        systemStatusItem?.button?.image = image
        systemStatusItem?.button?.toolTip = title
        systemStatusItem?.button?.setAccessibilityLabel("Transcride. \(title)")
    }

    private func ensureStatusItem() {
        guard systemStatusItem == nil, let statusBar else { return }
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        systemStatusItem = item
    }

    private func removeStatusItem() {
        guard let systemStatusItem else { return }
        systemStatusItem.menu = nil
        statusBar?.removeStatusItem(systemStatusItem)
        self.systemStatusItem = nil
    }

    private func startElapsedTimer() {
        guard elapsedTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(elapsedTimerFired),
            userInfo: nil,
            repeats: true
        )
        elapsedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    @objc private func elapsedTimerFired() {
        guard isMenuOpen, let latestSnapshot else { return }
        updateStatusDisplay(latestSnapshot)
    }

    @objc private func performPrimaryAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.model.recorder.state {
            case .idle:
                await self.model.performRecordingCommand(.startNew)
            case .recording, .paused:
                await self.model.performRecordingCommand(.stopAndSave)
            case .finalizing:
                break
            }
        }
    }

    @objc private func performPauseAction() {
        Task { @MainActor [weak self] in
            await self?.model.performRecordingCommand(.pauseResume)
        }
    }

    @objc private func showFloatingWidget() {
        model.showGlobalIndicatorManually()
    }

    @objc private func openTranscride() {
        AppWindowPresenter.openMainWindow()
    }

    @objc private func openSettings() {
        AppWindowPresenter.openSettings()
    }

    @objc private func hideMenuBarItem() {
        var preferences = model.globalShortcutPreferences
        preferences.showsMenuBarItem = false
        model.updateGlobalShortcutPreferences(preferences)
    }

    @objc private func quitTranscride() {
        NSApp.terminate(nil)
    }

    private static func symbolImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
