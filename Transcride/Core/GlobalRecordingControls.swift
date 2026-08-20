import Foundation

enum GlobalShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case toggleRecording
    case pauseResumeRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleRecording: "Start / Stop & Save Recording"
        case .pauseResumeRecording: "Pause / Resume Recording"
        }
    }
}

// GlobalShortcutModifiers and GlobalShortcutChord are typealiases of the
// shared ShortcutModifiers/ShortcutChord types in AppShortcuts.swift; the
// persisted wire format is unchanged.

enum GlobalShortcutValidation: Equatable, Sendable {
    case valid
    case modifierOnly
    case requiresNonShiftModifier
    case duplicate(GlobalShortcutAction)

    var message: String? {
        switch self {
        case .valid: nil
        case .modifierOnly: "Press a key together with modifiers."
        case .requiresNonShiftModifier: "Include Command, Option, or Control."
        case .duplicate(let action): "Already assigned to \(action.title)."
        }
    }
}

enum BackgroundIndicatorRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case quick
    case oneMinute
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case oneHour
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "Quick (3 seconds)"
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .never: "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .quick: 2.6
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .never: nil
        }
    }
}

struct GlobalShortcutPreferences: Codable, Equatable, Sendable {
    static let currentVersion = 4

    var version = currentVersion
    var isEnabled = true
    var showsMenuBarItem = true
    var showsBackgroundIndicator = true
    var backgroundIndicatorRetention = BackgroundIndicatorRetention.tenMinutes
    var bindings: [GlobalShortcutAction: GlobalShortcutChord?]

    init(
        version: Int = currentVersion,
        isEnabled: Bool = true,
        showsMenuBarItem: Bool = true,
        showsBackgroundIndicator: Bool = true,
        backgroundIndicatorRetention: BackgroundIndicatorRetention = .tenMinutes,
        bindings: [GlobalShortcutAction: GlobalShortcutChord?]
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.showsMenuBarItem = showsMenuBarItem
        self.showsBackgroundIndicator = showsBackgroundIndicator
        self.backgroundIndicatorRetention = backgroundIndicatorRetention
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case showsMenuBarItem
        case showsBackgroundIndicator
        case backgroundIndicatorRetention
        case bindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showsMenuBarItem = try container.decodeIfPresent(
            Bool.self, forKey: .showsMenuBarItem
        ) ?? true
        showsBackgroundIndicator = try container.decodeIfPresent(
            Bool.self, forKey: .showsBackgroundIndicator
        ) ?? true
        backgroundIndicatorRetention = try container.decodeIfPresent(
            BackgroundIndicatorRetention.self, forKey: .backgroundIndicatorRetention
        ) ?? .tenMinutes
        bindings = try container.decode(
            [GlobalShortcutAction: GlobalShortcutChord?].self, forKey: .bindings
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(showsMenuBarItem, forKey: .showsMenuBarItem)
        try container.encode(showsBackgroundIndicator, forKey: .showsBackgroundIndicator)
        try container.encode(backgroundIndicatorRetention, forKey: .backgroundIndicatorRetention)
        try container.encode(bindings, forKey: .bindings)
    }

    static let defaults = Self(bindings: [
        .toggleRecording: .defaultToggleRecording,
        .pauseResumeRecording: .defaultPauseResume,
    ])

    func validation(
        for action: GlobalShortcutAction,
        chord: GlobalShortcutChord
    ) -> GlobalShortcutValidation {
        let base = chord.globalCaptureValidation
        guard base == .valid else { return base }
        if let duplicate = bindings.first(where: { otherAction, otherChord in
            otherAction != action && otherChord == chord
        })?.key {
            return .duplicate(duplicate)
        }
        return .valid
    }
}

enum GlobalShortcutRegistrationStatus: Equatable, Sendable {
    case disabled
    case cleared
    case registered
    case failed(String)

    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

enum RecordingCommand: Equatable, Sendable {
    case startNew
    case pauseResume
    case stopAndSave
}

enum RecordingCommandAvailabilityState: Equatable, Sendable {
    case idleReady
    case idleUnavailable(String)
    case recording
    case paused
    case pausedResumeUnavailable(String)
    case startingMicrophone
    case finalizing
}

enum RecordingCommandDisposition: Equatable, Sendable {
    case perform
    case unavailable(String)
    case suppressedRepeat
}

struct RecordingCommandGate: Equatable, Sendable {
    private(set) var commandInFlight: RecordingCommand?

    mutating func begin(
        _ command: RecordingCommand,
        state: RecordingCommandAvailabilityState
    ) -> RecordingCommandDisposition {
        guard commandInFlight == nil else { return .suppressedRepeat }
        let disposition: RecordingCommandDisposition = switch (command, state) {
        case (.startNew, .idleReady), (.pauseResume, .recording),
             (.pauseResume, .paused), (.stopAndSave, .recording),
             (.stopAndSave, .paused), (.stopAndSave, .pausedResumeUnavailable):
            .perform
        case (.pauseResume, .pausedResumeUnavailable(let reason)):
            .unavailable(reason)
        case (_, .idleUnavailable(let reason)):
            .unavailable(reason)
        case (.startNew, .recording), (.startNew, .paused),
             (.startNew, .pausedResumeUnavailable):
            .unavailable("A recording is already active.")
        case (.startNew, .startingMicrophone), (.pauseResume, .startingMicrophone),
             (.stopAndSave, .startingMicrophone):
            .unavailable("The microphone is still starting.")
        case (.startNew, .finalizing), (.pauseResume, .finalizing),
             (.stopAndSave, .finalizing):
            .unavailable("The current recording is still being saved.")
        case (.pauseResume, .idleReady):
            .unavailable("There is no recording to pause or resume.")
        case (.stopAndSave, .idleReady):
            .unavailable("There is no recording to save.")
        }
        if disposition == .perform { commandInFlight = command }
        return disposition
    }

    mutating func finish(_ command: RecordingCommand) {
        if commandInFlight == command { commandInFlight = nil }
    }
}

enum RecordingStartAdmissionDecision: Equatable, Sendable {
    case begin
    case rejectAlreadyActive
}

enum RecordingStartAdmissionPolicy {
    static func classify(recorderIsIdle: Bool) -> RecordingStartAdmissionDecision {
        recorderIsIdle ? .begin : .rejectAlreadyActive
    }
}

/// Serializes entry-edit recording workflows across their permission and
/// filesystem awaits. RecorderService remains the final ownership backstop;
/// this gate prevents a losing UI task from mutating the winner's extension or
/// replacement session in its error path.
struct RecordingWorkflowStartGate: Equatable, Sendable {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }
}

enum GlobalRecordingPresentationState: Equatable, Sendable {
    case hidden
    case ready(startShortcut: String)
    case recording(elapsed: Double, pauseShortcut: String, stopShortcut: String)
    case recordingNeedsAttention(elapsed: Double, message: String, stopShortcut: String)
    case paused(elapsed: Double, pauseShortcut: String, stopShortcut: String)
    case startingMicrophone
    case saving(elapsed: Double)
    case saved(duration: Double, until: Date)
    case needsAttention(String)
    case saveFailed(String)
    case unavailable(String, until: Date)

    /// Passive Ready/attention states stay in the main app. The floating
    /// indicator only accompanies a recording session into the background.
    var belongsToRecordingSession: Bool {
        switch self {
        case .recording, .recordingNeedsAttention, .paused, .startingMicrophone,
             .saving, .saved, .saveFailed:
            true
        case .hidden, .ready, .needsAttention, .unavailable:
            false
        }
    }

    var isCaptureActive: Bool {
        switch self {
        case .recording, .recordingNeedsAttention, .paused, .startingMicrophone, .saving:
            true
        case .hidden, .ready, .saved, .needsAttention, .saveFailed, .unavailable:
            false
        }
    }

    func stateAfterExpiring(at now: Date, readyShortcut: String) -> Self {
        switch self {
        case .saved(_, let until) where now >= until:
            .ready(startShortcut: readyShortcut)
        case .unavailable(_, let until) where now >= until:
            .ready(startShortcut: readyShortcut)
        default:
            self
        }
    }
}

struct GlobalIndicatorScreenAnchor: Codable, Equatable, Sendable {
    var displayID: UInt32?
    var normalizedX: Double
    var normalizedY: Double

    init(displayID: UInt32?, normalizedX: Double, normalizedY: Double) {
        self.displayID = displayID
        self.normalizedX = normalizedX.clamped(to: 0...1)
        self.normalizedY = normalizedY.clamped(to: 0...1)
    }

    static func capture(
        frame: CGRect,
        visibleFrame: CGRect,
        displayID: UInt32?
    ) -> Self {
        let availableX = max(visibleFrame.width - frame.width, 1)
        let availableY = max(visibleFrame.height - frame.height, 1)
        return Self(
            displayID: displayID,
            normalizedX: (frame.minX - visibleFrame.minX) / availableX,
            normalizedY: (frame.minY - visibleFrame.minY) / availableY
        )
    }

    func restoredFrame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let availableX = max(visibleFrame.width - size.width, 0)
        let availableY = max(visibleFrame.height - size.height, 0)
        return CGRect(
            x: visibleFrame.minX + availableX * normalizedX,
            y: visibleFrame.minY + availableY * normalizedY,
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
