import Foundation

/// Removes the retired Voice/Meeting selector. Old values have no behavioral
/// effect: every new recording now starts the microphone and opportunistically
/// adds Mac audio under the universal capture policy.
enum RecordingSourcePreferenceMigration {
    static let legacyKey = "recordingCaptureMode"

    @discardableResult
    static func removeLegacyPreference(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: legacyKey) != nil else { return false }
        defaults.removeObject(forKey: legacyKey)
        return true
    }
}

/// Honest liveness state for the audio path. `AVAudioEngine.isRunning` and a
/// valid channel count do not prove that buffers or non-zero samples are
/// arriving, which is why this is deliberately driven by captured frames.
enum RecordingCaptureHealthState: Equatable, Sendable {
    case inactive
    case awaitingFirstBuffer
    case healthy
    case noBuffers
    case noSignal
    case stalled

    var needsAttention: Bool {
        switch self {
        case .noBuffers, .noSignal, .stalled: true
        case .inactive, .awaitingFirstBuffer, .healthy: false
        }
    }
}

/// Definitive microphone-only outcome at teardown. Optional Mac audio is
/// deliberately absent from this classifier so it can never hide a dead mic.
enum MicrophoneTerminalCaptureState: Equatable, Sendable {
    case signal
    case noFrames
    case perfectlySilent

    static func classify(frames: Int64, hasSignal: Bool) -> Self {
        guard frames > 0 else { return .noFrames }
        return hasSignal ? .signal : .perfectlySilent
    }
}

/// Pure/testable watchdog state. Each active period is independent so a resume
/// must prove that fresh buffers and signal are flowing again.
struct RecordingCaptureHealthMonitor: Equatable, Sendable {
    static let firstBufferGrace: TimeInterval = 2.0
    static let stallGrace: TimeInterval = 2.0
    static let signalGrace: TimeInterval = 4.0
    /// One signed 16-bit PCM step, matching the crash-safe microphone journal.
    /// Values below this can disappear when the canonical Float32 buffer is
    /// written to the 16-bit file. A built-in environmental microphone should
    /// sit comfortably above this even in a quiet room, while an all-zero or
    /// effectively all-zero route is treated as a capture failure.
    static let signalThreshold: Float = 1 / 32_768

    private(set) var activeSince: TimeInterval
    private(set) var framesAtActiveStart: Int64
    private(set) var framesWritten: Int64
    private(set) var lastBufferAt: TimeInterval?
    private(set) var lastSignalAt: TimeInterval?

    init(startedAt: TimeInterval, framesWritten: Int64 = 0) {
        activeSince = startedAt
        framesAtActiveStart = framesWritten
        self.framesWritten = framesWritten
    }

    mutating func beginActivePeriod(at uptime: TimeInterval) {
        activeSince = uptime
        framesAtActiveStart = framesWritten
        lastBufferAt = nil
        lastSignalAt = nil
    }

    mutating func observe(
        framesWritten: Int64,
        bufferPeak: Float,
        at uptime: TimeInterval
    ) {
        guard uptime.isFinite, framesWritten >= self.framesWritten else { return }
        self.framesWritten = framesWritten
        lastBufferAt = uptime
        if bufferPeak.isFinite, bufferPeak >= Self.signalThreshold {
            lastSignalAt = uptime
        }
    }

    func state(at uptime: TimeInterval) -> RecordingCaptureHealthState {
        guard uptime.isFinite else { return .noBuffers }
        let activeDuration = max(0, uptime - activeSince)
        let receivedFreshFrames = framesWritten > framesAtActiveStart
        guard receivedFreshFrames, let lastBufferAt else {
            return activeDuration >= Self.firstBufferGrace
                ? .noBuffers : .awaitingFirstBuffer
        }
        if uptime - lastBufferAt >= Self.stallGrace {
            return .stalled
        }
        let silentDuration = uptime - (lastSignalAt ?? activeSince)
        if silentDuration >= Self.signalGrace {
            return .noSignal
        }
        return .healthy
    }
}

/// Optional-source liveness is restarted after every microphone pause/gap so
/// wall-clock time spent paused can never be mistaken for a ScreenCaptureKit
/// stall. This state has no authority over microphone capture.
struct OptionalSystemAudioLiveness: Equatable, Sendable {
    private(set) var activeSince: TimeInterval
    private(set) var lastBufferAt: TimeInterval?

    init(activeSince: TimeInterval) {
        self.activeSince = activeSince
    }

    mutating func beginActivePeriod(at uptime: TimeInterval) {
        activeSince = uptime
        lastBufferAt = nil
    }

    mutating func observeBuffer(at uptime: TimeInterval) {
        guard uptime.isFinite, uptime >= activeSince else { return }
        lastBufferAt = uptime
    }

    func isStalled(at uptime: TimeInterval, grace: TimeInterval) -> Bool {
        guard uptime.isFinite, grace >= 0 else { return true }
        return uptime - (lastBufferAt ?? activeSince) >= grace
    }
}

/// Primitive snapshot of the hardware input feeding a recording engine.
///
/// Kept in Core so configuration-change decisions can be tested without
/// constructing AVAudioEngine/CoreAudio objects.
struct RecordingInputSignature: Equatable, Sendable {
    var deviceID: UInt32?
    var sampleRate: Double
    var channelCount: UInt32
    var deviceIsAvailable: Bool

    var isUsable: Bool {
        guard let deviceID else { return false }
        return deviceID != 0
            && deviceIsAvailable
            && sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
    }

    func isCompatible(with other: RecordingInputSignature) -> Bool {
        isUsable
            && other.isUsable
            && deviceID == other.deviceID
            && channelCount == other.channelCount
            && abs(sampleRate - other.sampleRate) < 0.5
    }
}

/// A recording is not live merely because AVAudioEngine.start() returned.
/// Startup commits only after the requested physical route has remained stable
/// and at least one buffer has survived canonical normalization and disk write.
/// Keeping this policy free of AVFoundation makes delayed Core Audio route
/// changes and no-buffer engines deterministic to test.
enum MicrophoneStartupValidationFailure: Equatable, Sendable {
    case engineStopped
    case unusableRoute
    case routeMismatch
    case routeUnstable
    case deliveredFormatChanged
    case noCanonicalFrames
}

enum MicrophoneStartupValidationDecision: Equatable, Sendable {
    case waiting
    case ready
    case retry(MicrophoneStartupValidationFailure)
}

enum MicrophoneStartupValidationPolicy {
    static let routeStabilityInterval: TimeInterval = 0.2
    static let deadline: TimeInterval = 2.0

    static func classify(
        now: TimeInterval,
        startedAt: TimeInterval,
        lastConfigurationChangeAt: TimeInterval?,
        requested: RecordingInputSignature,
        current: RecordingInputSignature,
        engineIsRunning: Bool,
        deliveredFormatChanged: Bool = false,
        canonicalFrames: Int64
    ) -> MicrophoneStartupValidationDecision {
        guard now.isFinite, startedAt.isFinite, now >= startedAt else {
            return .retry(.unusableRoute)
        }
        let lastRouteActivity = max(
            startedAt,
            lastConfigurationChangeAt ?? startedAt
        )
        // Decimal test clocks (and real monotonic conversions) can represent
        // 200 ms as 0.199999999999; do not extend the contract by a poll tick.
        let routeIsStable = now - lastRouteActivity + 1e-9
            >= routeStabilityInterval
        let deadlineReached = now - startedAt >= deadline

        if !engineIsRunning, routeIsStable || deadlineReached {
            return .retry(.engineStopped)
        }
        guard current.isUsable else {
            return routeIsStable || deadlineReached
                ? .retry(.unusableRoute) : .waiting
        }
        guard requested.isCompatible(with: current) else {
            return routeIsStable || deadlineReached
                ? .retry(.routeMismatch) : .waiting
        }
        // Once the sink adopts the first tap format it cannot safely normalize
        // a different delivered format in the same graph. Even frames already
        // written by format A must not allow that attempt to commit after B
        // appears during the route-stability window.
        guard !deliveredFormatChanged else {
            return .retry(.deliveredFormatChanged)
        }
        guard canonicalFrames > 0 else {
            return deadlineReached ? .retry(.noCanonicalFrames) : .waiting
        }
        guard routeIsStable else {
            return deadlineReached ? .retry(.routeUnstable) : .waiting
        }
        return .ready
    }
}

enum RecordingConfigurationDecision: Equatable, Sendable {
    /// The input is unchanged and the engine is already accepting buffers.
    case keepRunning
    /// The input is unchanged, but CoreAudio stopped the engine while rebuilding its graph.
    case restartEngine
    /// The input disappeared, changed identity, or changed to an incompatible format.
    case pauseForInputChange

    static func classify(
        baseline: RecordingInputSignature,
        current: RecordingInputSignature,
        engineIsRunning: Bool
    ) -> Self {
        guard baseline.isCompatible(with: current) else {
            return .pauseForInputChange
        }
        return engineIsRunning ? .keepRunning : .restartEngine
    }
}

/// Bounds automatic AVAudioEngine recovery when a route is repeatedly torn
/// down and rebuilt, as can happen when a multipoint Bluetooth headset moves
/// between hosts. Sparse configuration notifications remain recoverable; a
/// burst tells the recorder to quarantine the graph and preserve captured
/// audio for Stop & Save.
struct RecordingConfigurationChangeCircuitBreaker: Equatable, Sendable {
    var maximumChanges = 3
    var window: TimeInterval = 2
    private(set) var recentEventUptimes: [TimeInterval] = []

    mutating func registerChange(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, maximumChanges > 0, window >= 0 else { return true }
        recentEventUptimes.removeAll {
            $0 > uptime || uptime - $0 > window
        }
        recentEventUptimes.append(uptime)
        return recentEventUptimes.count >= maximumChanges
    }

    mutating func reset() {
        recentEventUptimes.removeAll(keepingCapacity: true)
    }
}

// MARK: - Optional system-audio policy

/// Pure permission vocabulary for an optional system-audio sidecar. The
/// microphone capture is deliberately outside this state machine and can
/// continue through every fallback transition.
enum OptionalSystemAudioPermission: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

enum OptionalSystemAudioFallbackReason: Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case startFailed
    case stalled
    case invalidTiming
    case invalidFormat
    case sidecarWriteFailed
    case mixFailed
    case noMeaningfulAudio
}

enum OptionalSystemAudioCaptureStatus: Equatable, Sendable {
    case notRequested
    case awaitingPermission
    case starting
    /// The stream started but has not yet proved that it can deliver a buffer.
    case capturing
    /// At least one system-audio buffer was retained in the sidecar.
    case captured
    case microphoneOnly(OptionalSystemAudioFallbackReason)
    case finished

    var acceptsSystemAudio: Bool {
        switch self {
        case .capturing, .captured: true
        default: false
        }
    }

    /// True while callbacks from the current stream generation may still be
    /// applied. ScreenCaptureKit can enqueue a buffer between activating its
    /// output and returning from `startCapture`, so the startup states must
    /// accept that callback without allowing a terminal fallback to revive.
    var acceptsRuntimeCallbacks: Bool {
        switch self {
        case .awaitingPermission, .starting, .capturing, .captured: true
        case .notRequested, .microphoneOnly, .finished: false
        }
    }
}

enum OptionalSystemAudioCaptureTone: Equatable, Sendable {
    case neutral
    case success
    case warning
}

struct OptionalSystemAudioCapturePresentation: Equatable, Sendable {
    var text: String
    var symbolName: String
    var tone: OptionalSystemAudioCaptureTone
}

extension OptionalSystemAudioCaptureStatus {
    var presentation: OptionalSystemAudioCapturePresentation {
        switch self {
        case .notRequested, .awaitingPermission:
            return .init(
                text: "Mac audio: checking availability…",
                symbolName: "speaker.wave.2",
                tone: .neutral
            )
        case .starting:
            return .init(
                text: "Mac audio: starting optional capture…",
                symbolName: "speaker.wave.2",
                tone: .neutral
            )
        case .capturing:
            return .init(
                text: "Mac audio available — listening for sound",
                symbolName: "speaker.wave.2",
                tone: .neutral
            )
        case .captured:
            return .init(
                text: "Mac audio detected — it will be included",
                symbolName: "speaker.wave.2.fill",
                tone: .success
            )
        case .microphoneOnly(let reason):
            let text = switch reason {
            case .permissionDenied, .permissionRestricted:
                "Microphone only — Mac audio permission is unavailable"
            case .startFailed:
                "Microphone only — Mac audio could not start"
            case .stalled:
                "Microphone continues — Mac audio stopped arriving"
            case .invalidTiming, .invalidFormat:
                "Microphone only — Mac audio timing was unreliable"
            case .sidecarWriteFailed:
                "Microphone only — Mac audio could not be stored"
            case .mixFailed:
                "Microphone only — Mac audio could not be mixed safely"
            case .noMeaningfulAudio:
                "Microphone only — no Mac audio was detected"
            }
            return .init(text: text, symbolName: "mic.fill", tone: .warning)
        case .finished:
            return .init(
                text: "Mac audio capture finished",
                symbolName: "checkmark.circle",
                tone: .neutral
            )
        }
    }
}

enum OptionalSystemAudioCaptureEvent: Equatable, Sendable {
    case begin(permission: OptionalSystemAudioPermission)
    case permissionResolved(OptionalSystemAudioPermission)
    case streamStarted
    case meaningfulBufferCaptured
    case streamStartFailed
    case stallDetected
    case invalidTiming
    case invalidFormat
    case sidecarWriteFailed
    case finish
    case cancel
}

enum OptionalSystemAudioCaptureAction: Equatable, Sendable {
    case requestPermission
    case startStream
    case stopStream
    case continueMicrophoneOnly(OptionalSystemAudioFallbackReason)
}

struct OptionalSystemAudioCaptureTransition: Equatable, Sendable {
    var status: OptionalSystemAudioCaptureStatus
    var actions: [OptionalSystemAudioCaptureAction]
}

/// Deterministic transition policy for opportunistic system capture. Permission
/// denial, startup failure, and a later stream stall degrade only the sidecar;
/// none of them invalidate microphone audio already being recorded.
enum OptionalSystemAudioCapturePolicy {
    static func transition(
        from status: OptionalSystemAudioCaptureStatus,
        event: OptionalSystemAudioCaptureEvent
    ) -> OptionalSystemAudioCaptureTransition {
        switch (status, event) {
        case (_, .finish), (_, .cancel):
            return terminate(from: status)

        case (.notRequested, .begin(let permission)):
            return begin(with: permission)

        case (.awaitingPermission, .permissionResolved(let permission)):
            return resolve(permission)

        case (.awaitingPermission, .streamStarted),
             (.starting, .streamStarted):
            return .init(status: .capturing, actions: [])

        case (.awaitingPermission, .meaningfulBufferCaptured),
             (.starting, .meaningfulBufferCaptured),
             (.capturing, .meaningfulBufferCaptured),
             (.captured, .meaningfulBufferCaptured):
            return .init(status: .captured, actions: [])

        case (.starting, .streamStartFailed):
            return stopAndFallback(.startFailed)

        case (.capturing, .stallDetected), (.captured, .stallDetected):
            return .init(
                status: .microphoneOnly(.stalled),
                actions: [.stopStream, .continueMicrophoneOnly(.stalled)]
            )

        case (.starting, .invalidTiming):
            return stopAndFallback(.invalidTiming)

        case (.starting, .invalidFormat):
            return stopAndFallback(.invalidFormat)

        case (.capturing, .invalidTiming), (.captured, .invalidTiming):
            return stopAndFallback(.invalidTiming)

        case (.capturing, .invalidFormat), (.captured, .invalidFormat):
            return stopAndFallback(.invalidFormat)

        case (.starting, .sidecarWriteFailed),
             (.capturing, .sidecarWriteFailed),
             (.captured, .sidecarWriteFailed):
            return stopAndFallback(.sidecarWriteFailed)

        default:
            // Late permission/stream callbacks must not revive a capture that
            // already fell back to its authoritative microphone track.
            return .init(status: status, actions: [])
        }
    }

    private static func begin(
        with permission: OptionalSystemAudioPermission
    ) -> OptionalSystemAudioCaptureTransition {
        switch permission {
        case .notDetermined:
            return .init(status: .awaitingPermission, actions: [.requestPermission])
        case .granted:
            return .init(status: .starting, actions: [.startStream])
        case .denied:
            return fallback(.permissionDenied)
        case .restricted:
            return fallback(.permissionRestricted)
        }
    }

    private static func resolve(
        _ permission: OptionalSystemAudioPermission
    ) -> OptionalSystemAudioCaptureTransition {
        switch permission {
        case .notDetermined:
            return .init(status: .awaitingPermission, actions: [])
        case .granted:
            return .init(status: .starting, actions: [.startStream])
        case .denied:
            return fallback(.permissionDenied)
        case .restricted:
            return fallback(.permissionRestricted)
        }
    }

    private static func fallback(
        _ reason: OptionalSystemAudioFallbackReason
    ) -> OptionalSystemAudioCaptureTransition {
        .init(
            status: .microphoneOnly(reason),
            actions: [.continueMicrophoneOnly(reason)]
        )
    }

    private static func stopAndFallback(
        _ reason: OptionalSystemAudioFallbackReason
    ) -> OptionalSystemAudioCaptureTransition {
        .init(
            status: .microphoneOnly(reason),
            actions: [.stopStream, .continueMicrophoneOnly(reason)]
        )
    }

    private static func terminate(
        from status: OptionalSystemAudioCaptureStatus
    ) -> OptionalSystemAudioCaptureTransition {
        let shouldStopStream: Bool
        switch status {
        case .starting, .capturing, .captured:
            shouldStopStream = true
        case .notRequested, .awaitingPermission, .microphoneOnly, .finished:
            shouldStopStream = false
        }
        return .init(
            status: .finished,
            actions: shouldStopStream ? [.stopStream] : []
        )
    }
}
