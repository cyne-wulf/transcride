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
        changed.showsBackgroundIndicator = false
        changed.bindings[.pauseResumeRecording] = nil
        GlobalShortcutPreferencesStore.save(changed, defaults: defaults)
        #expect(GlobalShortcutPreferencesStore.load(defaults: defaults) == changed)

        var obsolete = changed
        obsolete.version = GlobalShortcutPreferences.currentVersion - 1
        GlobalShortcutPreferencesStore.save(obsolete, defaults: defaults)
        #expect(GlobalShortcutPreferencesStore.load(defaults: defaults) == .defaults)
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
}
