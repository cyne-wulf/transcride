import Foundation
import Testing

@Suite("Global recording controls")
struct GlobalRecordingControlsTests {
    @Test func defaultsMatchProductChords() {
        let preferences = GlobalShortcutPreferences.defaults
        #expect(preferences.bindings[.toggleRecording] == .defaultToggleRecording)
        #expect(preferences.bindings[.pauseResumeRecording] == .defaultPauseResume)
        #expect(GlobalShortcutAction.allCases.count == 2)
        #expect(GlobalShortcutChord.defaultToggleRecording.glyphDescription == "⌥R")
        #expect(GlobalShortcutChord.defaultPauseResume.glyphDescription == "⌥P")
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
