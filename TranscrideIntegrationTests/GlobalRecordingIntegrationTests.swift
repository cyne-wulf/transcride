import Foundation
import Testing
@testable import Transcride

@Suite("Global recording app integration", .serialized)
@MainActor
struct GlobalRecordingIntegrationTests {
    @Test func preferencesStoreDefaultsAndRoundTrips() throws {
        let suiteName = "GlobalRecordingIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(GlobalShortcutPreferencesStore.load(defaults: defaults) == .defaults)
        var changed = GlobalShortcutPreferences.defaults
        changed.showsMenuBarItem = false
        changed.showsBackgroundIndicator = false
        changed.backgroundIndicatorRetention = .never
        changed.bindings[.pauseResumeRecording] = nil
        GlobalShortcutPreferencesStore.save(changed, defaults: defaults)
        #expect(GlobalShortcutPreferencesStore.load(defaults: defaults) == changed)
        #expect(!GlobalShortcutPreferencesStore.load(defaults: defaults).showsMenuBarItem)

        var obsolete = changed
        obsolete.version = GlobalShortcutPreferences.currentVersion - 1
        GlobalShortcutPreferencesStore.save(obsolete, defaults: defaults)
        var migrated = obsolete
        migrated.version = GlobalShortcutPreferences.currentVersion
        #expect(GlobalShortcutPreferencesStore.load(defaults: defaults) == migrated)
    }

    @Test func serviceMapsDisabledAndClearedBindings() {
        let service = GlobalShortcutService()
        var preferences = GlobalShortcutPreferences.defaults
        preferences.bindings = Dictionary(uniqueKeysWithValues:
            GlobalShortcutAction.allCases.map { ($0, nil) }
        )
        service.apply(preferences)
        for action in GlobalShortcutAction.allCases {
            #expect(service.statuses[action] == .cleared)
        }

        preferences.isEnabled = false
        service.apply(preferences)
        for action in GlobalShortcutAction.allCases {
            #expect(service.statuses[action] == .disabled)
        }
        service.shutdown()
    }

    @Test func serviceEmitsOncePerPhysicalPress() {
        let service = GlobalShortcutService()
        var actions: [GlobalShortcutAction] = []
        service.onAction = { actions.append($0) }

        service.receiveHotKeyEvent(action: .toggleRecording, isPressed: true)
        service.receiveHotKeyEvent(action: .toggleRecording, isPressed: true)
        #expect(actions == [.toggleRecording])

        service.receiveHotKeyEvent(action: .toggleRecording, isPressed: false)
        service.receiveHotKeyEvent(action: .toggleRecording, isPressed: true)
        #expect(actions == [.toggleRecording, .toggleRecording])
        service.shutdown()
    }

    @Test func unavailableStartProducesHonestFeedback() async {
        let model = AppModel()
        await model.performRecordingCommand(.startNew)
        guard case .unavailable(let message, _)? = model.globalRecordingTransientState else {
            Issue.record("Expected unavailable presentation state")
            return
        }
        #expect(message.contains("vault"))
        model.shutdownGlobalRecordingControls()
    }

    @Test func menuSnapshotMapsStatesActionsAndShortcutHonesty() {
        let registered: [GlobalShortcutAction: GlobalShortcutRegistrationStatus] = [
            .toggleRecording: .registered,
            .pauseResumeRecording: .registered,
        ]
        let recording = MenuBarControlSnapshot.make(
            presentationState: .recording(
                elapsed: 500,
                pauseShortcut: "⌥P",
                stopShortcut: "⌥R"
            ),
            recorderPhase: .recording,
            preferences: .defaults,
            registrationStatuses: registered
        )
        #expect(recording.status == .recording)
        #expect(recording.status.title(liveElapsed: 12.8) == "Recording · 00:12")
        #expect(recording.primaryActionTitle == "Stop & Save Recording    ⌥R")
        #expect(recording.pauseActionTitle == "Pause Recording    ⌥P")
        #expect(recording.primaryActionEnabled)
        #expect(recording.pauseActionEnabled)

        let paused = MenuBarControlSnapshot.make(
            presentationState: .paused(
                elapsed: 12,
                pauseShortcut: "⌥P",
                stopShortcut: "⌥R"
            ),
            recorderPhase: .paused,
            preferences: .defaults,
            registrationStatuses: registered
        )
        #expect(paused.status == .paused)
        #expect(paused.pauseActionTitle == "Resume Recording    ⌥P")

        let finalizing = MenuBarControlSnapshot.make(
            presentationState: .saving(elapsed: 12),
            recorderPhase: .finalizing,
            preferences: .defaults,
            registrationStatuses: registered
        )
        #expect(finalizing.status == .saving)
        #expect(!finalizing.primaryActionEnabled)
        #expect(!finalizing.pauseActionEnabled)

        var disabledPreferences = GlobalShortcutPreferences.defaults
        disabledPreferences.isEnabled = false
        let disabled = MenuBarControlSnapshot.make(
            presentationState: .ready(startShortcut: "⌥R"),
            recorderPhase: .idle,
            preferences: disabledPreferences,
            registrationStatuses: [
                .toggleRecording: .disabled,
                .pauseResumeRecording: .disabled,
            ]
        )
        #expect(disabled.primaryActionTitle == "Start Recording    ⌥R — Off")
        #expect(disabled.registrationSummary ==
            "Global shortcuts are disabled; menu controls still work.")

        var clearedPreferences = GlobalShortcutPreferences.defaults
        clearedPreferences.bindings[.pauseResumeRecording] = nil
        let cleared = MenuBarControlSnapshot.make(
            presentationState: .needsAttention("Open a vault"),
            recorderPhase: .idle,
            preferences: clearedPreferences,
            registrationStatuses: [
                .toggleRecording: .failed("Already in use."),
                .pauseResumeRecording: .cleared,
            ]
        )
        #expect(cleared.status == .needsAttention("Open a vault"))
        #expect(cleared.pauseActionTitle == "Pause Recording    No shortcut")
        #expect(cleared.primaryActionTitle == "Start Recording    ⌥R — Unavailable")
        #expect(cleared.registrationSummary ==
            "Start / Stop & Save Recording: Already in use.")

        #expect(MenuBarRecordingStatus(.saved(
            duration: 9,
            until: .distantFuture
        )) == .saved(duration: 9))
        #expect(MenuBarRecordingStatus(.saveFailed("Recoverable")) ==
            .saveFailed("Recoverable"))
        #expect(MenuBarRecordingStatus(.unavailable(
            "No microphone",
            until: .distantFuture
        )) == .unavailable("No microphone"))
    }

    @Test func menuRefreshRetainsStableItemIdentityAndOrder() {
        let model = AppModel()
        let controller = MenuBarItemController(model: model, statusBar: nil)
        defer {
            controller.shutdown()
            model.shutdownGlobalRecordingControls()
        }

        let initialItems = controller.menuItemIdentitiesForTesting
        for _ in 0..<20 {
            controller.refreshForTesting()
            #expect(controller.menuItemIdentitiesForTesting == initialItems)
        }
    }
}
