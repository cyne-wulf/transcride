import Foundation
import Testing

@Suite("Global recording controls")
struct GlobalRecordingControlsTests {
    @Test func backgroundIndicatorOnlyBelongsToRecordingSessions() {
        let now = Date()
        #expect(!GlobalRecordingPresentationState.hidden.belongsToRecordingSession)
        #expect(!GlobalRecordingPresentationState.ready(startShortcut: "⌥R").belongsToRecordingSession)
        #expect(!GlobalRecordingPresentationState.needsAttention("Open a vault").belongsToRecordingSession)
        #expect(!GlobalRecordingPresentationState.unavailable("Idle", until: now).belongsToRecordingSession)
        #expect(GlobalRecordingPresentationState.recording(
            elapsed: 1, pauseShortcut: "⌥P", stopShortcut: "⌥R"
        ).belongsToRecordingSession)
        #expect(GlobalRecordingPresentationState.paused(
            elapsed: 1, pauseShortcut: "⌥P", stopShortcut: "⌥R"
        ).belongsToRecordingSession)
        #expect(GlobalRecordingPresentationState.saving(elapsed: 1).belongsToRecordingSession)
        #expect(GlobalRecordingPresentationState.saved(duration: 1, until: now).belongsToRecordingSession)
        #expect(GlobalRecordingPresentationState.saveFailed("Recoverable").belongsToRecordingSession)
        #expect(!GlobalRecordingPresentationState.ready(startShortcut: "⌥R").isCaptureActive)
        #expect(GlobalRecordingPresentationState.recording(
            elapsed: 1, pauseShortcut: "⌥P", stopShortcut: "⌥R"
        ).isCaptureActive)
    }

    @Test func defaultsMatchProductChords() {
        let preferences = GlobalShortcutPreferences.defaults
        #expect(preferences.bindings[.toggleRecording] == .defaultToggleRecording)
        #expect(preferences.bindings[.pauseResumeRecording] == .defaultPauseResume)
        #expect(GlobalShortcutAction.allCases.count == 2)
        #expect(GlobalShortcutChord.defaultToggleRecording.glyphDescription == "⌥R")
        #expect(GlobalShortcutChord.defaultPauseResume.glyphDescription == "⌥P")
        #expect(preferences.showsMenuBarItem)
        #expect(preferences.backgroundIndicatorRetention == .tenMinutes)
        #expect(BackgroundIndicatorRetention.quick.interval == 2.6)
        #expect(BackgroundIndicatorRetention.tenMinutes.interval == 600)
        #expect(BackgroundIndicatorRetention.never.interval == nil)
    }

    @Test func validationRejectsPlainShiftAndDuplicates() {
        let plain = GlobalShortcutChord(keyCode: 15, modifiers: [])
        let shifted = GlobalShortcutChord(keyCode: 15, modifiers: .shift)
        #expect(plain.validation == .requiresNonShiftModifier)
        #expect(shifted.validation == .requiresNonShiftModifier)

        let preferences = GlobalShortcutPreferences.defaults
        #expect(preferences.validation(
            for: .pauseResumeRecording, chord: .defaultToggleRecording
        ) == .duplicate(.toggleRecording))
    }

    @Test func preferencesRoundTrip() throws {
        var preferences = GlobalShortcutPreferences.defaults
        preferences.bindings[.pauseResumeRecording] = nil
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(GlobalShortcutPreferences.self, from: data) == preferences)
    }

    @Test func versionTwoPreferencesMigrateWithoutLosingKeybinds() throws {
        struct VersionTwoPreferences: Codable {
            var version: Int
            var isEnabled: Bool
            var showsBackgroundIndicator: Bool
            var bindings: [GlobalShortcutAction: GlobalShortcutChord?]
        }
        let legacy = VersionTwoPreferences(
            version: 2,
            isEnabled: true,
            showsBackgroundIndicator: false,
            bindings: [
                .toggleRecording: GlobalShortcutChord(keyCode: 12, modifiers: .option),
                .pauseResumeRecording: nil,
            ]
        )
        let preferences = try JSONDecoder().decode(
            GlobalShortcutPreferences.self, from: JSONEncoder().encode(legacy)
        )
        #expect(preferences.version == 2)
        #expect(preferences.showsMenuBarItem)
        #expect(!preferences.showsBackgroundIndicator)
        #expect(preferences.backgroundIndicatorRetention == .tenMinutes)
        #expect((preferences.bindings[.toggleRecording] ?? nil)?.keyCode == 12)
        #expect((preferences.bindings[.pauseResumeRecording] ?? nil) == nil)
    }

    @Test func versionThreePreferencesMigrateWithMenuBarVisible() throws {
        struct VersionThreePreferences: Codable {
            var version: Int
            var isEnabled: Bool
            var showsBackgroundIndicator: Bool
            var backgroundIndicatorRetention: BackgroundIndicatorRetention
            var bindings: [GlobalShortcutAction: GlobalShortcutChord?]
        }
        let legacy = VersionThreePreferences(
            version: 3,
            isEnabled: false,
            showsBackgroundIndicator: false,
            backgroundIndicatorRetention: .never,
            bindings: [
                .toggleRecording: .defaultToggleRecording,
                .pauseResumeRecording: .defaultPauseResume,
            ]
        )
        let preferences = try JSONDecoder().decode(
            GlobalShortcutPreferences.self, from: JSONEncoder().encode(legacy)
        )
        #expect(preferences.version == 3)
        #expect(preferences.showsMenuBarItem)
        #expect(!preferences.isEnabled)
        #expect(!preferences.showsBackgroundIndicator)
        #expect(preferences.backgroundIndicatorRetention == .never)
        #expect(preferences.bindings == legacy.bindings)
    }

    @Test func menuBarVisibilityPersistsAndResetDefaultsRestoreIt() throws {
        var preferences = GlobalShortcutPreferences.defaults
        preferences.showsMenuBarItem = false
        let restored = try JSONDecoder().decode(
            GlobalShortcutPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        #expect(!restored.showsMenuBarItem)
        #expect(GlobalShortcutPreferences.defaults.showsMenuBarItem)
    }

    @Test func commandGateSerializesAndSuppressesInvalidTransitions() {
        var gate = RecordingCommandGate()
        #expect(gate.begin(.startNew, state: .idleReady) == .perform)
        #expect(gate.begin(.startNew, state: .idleReady) == .suppressedRepeat)
        gate.finish(.startNew)
        #expect(gate.begin(.pauseResume, state: .idleReady) == .unavailable(
            "There is no recording to pause or resume."
        ))
        #expect(gate.begin(.stopAndSave, state: .recording) == .perform)
        gate.finish(.stopAndSave)
    }

    @Test func presentationExpiresToReady() {
        let now = Date(timeIntervalSince1970: 100)
        let saved = GlobalRecordingPresentationState.saved(duration: 4, until: now)
        #expect(saved.stateAfterExpiring(at: now, readyShortcut: "⌥R") == .ready(
            startShortcut: "⌥R"
        ))
    }

    @Test func screenAnchorRestoresAndClamps() {
        let visible = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let frame = CGRect(x: 800, y: 500, width: 240, height: 96)
        let anchor = GlobalIndicatorScreenAnchor.capture(
            frame: frame, visibleFrame: visible, displayID: 7
        )
        #expect(anchor.displayID == 7)
        #expect(anchor.restoredFrame(size: frame.size, visibleFrame: visible) == frame)

        let clamped = GlobalIndicatorScreenAnchor(
            displayID: nil, normalizedX: 2, normalizedY: -1
        )
        #expect(clamped.normalizedX == 1)
        #expect(clamped.normalizedY == 0)
    }
}
