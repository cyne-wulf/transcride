import Foundation
import Testing

@Suite("Recording input configuration changes")
struct RecordingInputConfigurationTests {
    private let baseline = RecordingInputSignature(
        deviceID: 71,
        sampleRate: 48_000,
        channelCount: 1,
        deviceIsAvailable: true
    )

    @Test func benignNotificationKeepsRunningEngine() {
        #expect(
            RecordingConfigurationDecision.classify(
                baseline: baseline,
                current: baseline,
                engineIsRunning: true
            ) == .keepRunning
        )
    }

    @Test func benignNotificationRestartsStoppedEngine() {
        #expect(
            RecordingConfigurationDecision.classify(
                baseline: baseline,
                current: baseline,
                engineIsRunning: false
            ) == .restartEngine
        )
    }

    @Test func microphoneStartupRequiresCanonicalFramesAndAStablePhysicalRoute() {
        #expect(startupDecision(now: 10.19, frames: 4_410) == .waiting)
        #expect(startupDecision(now: 10.2, frames: 0) == .waiting)
        #expect(startupDecision(now: 10.2, frames: 4_410) == .ready)
    }

    @Test func lateConfigurationChangeRestartsTheStabilityWindow() {
        #expect(startupDecision(
            now: 10.34,
            lastConfigurationChangeAt: 10.15,
            frames: 4_410
        ) == .waiting)
        #expect(startupDecision(
            now: 10.35,
            lastConfigurationChangeAt: 10.15,
            frames: 4_410
        ) == .ready)
    }

    @Test func stableWrongRouteAndStoppedEngineAreRetried() {
        var wrongRoute = baseline
        wrongRoute.deviceID = 99
        #expect(startupDecision(
            now: 10.2,
            current: wrongRoute,
            frames: 4_410
        ) == .retry(.routeMismatch))
        #expect(startupDecision(
            now: 10.2,
            engineIsRunning: false,
            frames: 4_410
        ) == .retry(.engineStopped))
    }

    @Test func runningEngineWithoutCanonicalFramesTimesOut() {
        #expect(startupDecision(now: 11.99, frames: 0) == .waiting)
        #expect(startupDecision(
            now: 12,
            frames: 0
        ) == .retry(.noCanonicalFrames))
    }

    @Test func clientConvertedTapFormatDoesNotInvalidatePhysicalRoute() {
        let physicalRoute = RecordingInputSignature(
            deviceID: 71,
            sampleRate: 48_000,
            channelCount: 3,
            deviceIsAvailable: true
        )
        // This is retained as first-buffer diagnostics and sink state, not fed
        // into physical-route compatibility.
        let deliveredTapSampleRate = 44_100.0
        let deliveredTapChannels: UInt32 = 1
        #expect(deliveredTapSampleRate != physicalRoute.sampleRate)
        #expect(deliveredTapChannels != physicalRoute.channelCount)
        #expect(MicrophoneStartupValidationPolicy.classify(
            now: 10.2,
            startedAt: 10,
            lastConfigurationChangeAt: nil,
            requested: physicalRoute,
            current: physicalRoute,
            engineIsRunning: true,
            canonicalFrames: 4_410
        ) == .ready)
    }

    @Test func deliveredFormatChangePreventsCommitDespiteWrittenFrames() {
        #expect(MicrophoneStartupValidationPolicy.classify(
            now: 10.2,
            startedAt: 10,
            lastConfigurationChangeAt: nil,
            requested: baseline,
            current: baseline,
            engineIsRunning: true,
            deliveredFormatChanged: true,
            canonicalFrames: 4_410
        ) == .retry(.deliveredFormatChanged))
    }

    @Test func configurationStormCannotExtendStartupPastDeadline() {
        #expect(MicrophoneStartupValidationPolicy.classify(
            now: 12,
            startedAt: 10,
            lastConfigurationChangeAt: 11.95,
            requested: baseline,
            current: baseline,
            engineIsRunning: true,
            canonicalFrames: 4_410
        ) == .retry(.routeUnstable))
    }

    @Test func changedDevicePausesRecording() {
        var changed = baseline
        changed.deviceID = 99
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test func changedSampleRatePausesRecording() {
        var changed = baseline
        changed.sampleRate = 44_100
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test func changedChannelCountPausesRecording() {
        var changed = baseline
        changed.channelCount = 2
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test(arguments: [
        RecordingInputSignature(
            deviceID: nil, sampleRate: 48_000, channelCount: 1, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 0, channelCount: 1, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 48_000, channelCount: 0, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 48_000, channelCount: 1, deviceIsAvailable: false
        ),
    ])
    func invalidCurrentInputPausesRecording(current: RecordingInputSignature) {
        #expect(classify(current) == .pauseForInputChange)
    }

    private func classify(_ current: RecordingInputSignature) -> RecordingConfigurationDecision {
        RecordingConfigurationDecision.classify(
            baseline: baseline,
            current: current,
            engineIsRunning: true
        )
    }

    private func startupDecision(
        now: TimeInterval,
        lastConfigurationChangeAt: TimeInterval? = nil,
        current: RecordingInputSignature? = nil,
        engineIsRunning: Bool = true,
        frames: Int64
    ) -> MicrophoneStartupValidationDecision {
        MicrophoneStartupValidationPolicy.classify(
            now: now,
            startedAt: 10,
            lastConfigurationChangeAt: lastConfigurationChangeAt,
            requested: baseline,
            current: current ?? baseline,
            engineIsRunning: engineIsRunning,
            canonicalFrames: frames
        )
    }

    @Test func circuitBreakerTripsOnRapidConfigurationChanges() {
        var breaker = RecordingConfigurationChangeCircuitBreaker()
        let first = breaker.registerChange(at: 10)
        let second = breaker.registerChange(at: 10.4)
        let third = breaker.registerChange(at: 11.1)
        #expect(!first)
        #expect(!second)
        #expect(third)
    }

    @Test func circuitBreakerAllowsSparseConfigurationChanges() {
        var breaker = RecordingConfigurationChangeCircuitBreaker()
        let first = breaker.registerChange(at: 10)
        let second = breaker.registerChange(at: 12.1)
        let third = breaker.registerChange(at: 14.2)
        #expect(!first)
        #expect(!second)
        #expect(!third)
    }

    @Test func circuitBreakerResetStartsAFreshWindow() {
        var breaker = RecordingConfigurationChangeCircuitBreaker()
        let first = breaker.registerChange(at: 10)
        let second = breaker.registerChange(at: 10.2)
        breaker.reset()
        let afterReset = breaker.registerChange(at: 10.3)
        #expect(!first)
        #expect(!second)
        #expect(!afterReset)
    }

    @Test func captureHealthRequiresFreshBuffersAfterStartAndResume() {
        var monitor = RecordingCaptureHealthMonitor(startedAt: 10)
        #expect(monitor.state(at: 11.9) == .awaitingFirstBuffer)
        #expect(monitor.state(at: 12) == .noBuffers)

        monitor.observe(framesWritten: 4_410, bufferPeak: 0.1, at: 12.1)
        #expect(monitor.state(at: 12.2) == .healthy)

        monitor.beginActivePeriod(at: 20)
        #expect(monitor.state(at: 21) == .awaitingFirstBuffer)
        #expect(monitor.state(at: 22) == .noBuffers)
    }

    @Test func captureHealthDistinguishesDigitalSilenceFromSignal() {
        var monitor = RecordingCaptureHealthMonitor(startedAt: 10)
        monitor.observe(framesWritten: 44_100, bufferPeak: 0, at: 11)
        monitor.observe(framesWritten: 48_000, bufferPeak: 0, at: 13.9)
        #expect(monitor.state(at: 13.9) == .healthy)
        monitor.observe(framesWritten: 48_100, bufferPeak: 0, at: 14)
        #expect(monitor.state(at: 14) == .noSignal)

        monitor.observe(framesWritten: 48_510, bufferPeak: 0.001, at: 14.1)
        #expect(monitor.state(at: 14.2) == .healthy)
    }

    @Test func captureHealthUsesThePersistedPCM16NoiseFloor() {
        var monitor = RecordingCaptureHealthMonitor(startedAt: 10)
        monitor.observe(
            framesWritten: 4_410,
            bufferPeak: RecordingCaptureHealthMonitor.signalThreshold / 2,
            at: 10.1
        )
        monitor.observe(
            framesWritten: 8_820,
            bufferPeak: RecordingCaptureHealthMonitor.signalThreshold / 2,
            at: 13.9
        )
        #expect(monitor.state(at: 14) == .noSignal)

        monitor.observe(
            framesWritten: 13_230,
            bufferPeak: RecordingCaptureHealthMonitor.signalThreshold,
            at: 14.1
        )
        #expect(monitor.state(at: 14.2) == .healthy)
    }

    @Test func terminalMicrophoneFailureCannotBeMaskedByAnotherAudioSource() {
        #expect(MicrophoneTerminalCaptureState.classify(
            frames: 0,
            hasSignal: true
        ) == .noFrames)
        #expect(MicrophoneTerminalCaptureState.classify(
            frames: 44_100,
            hasSignal: false
        ) == .perfectlySilent)
        #expect(MicrophoneTerminalCaptureState.classify(
            frames: 44_100,
            hasSignal: true
        ) == .signal)
    }

    @Test func captureHealthDetectsAStalledStream() {
        var monitor = RecordingCaptureHealthMonitor(startedAt: 10)
        monitor.observe(framesWritten: 4_410, bufferPeak: 0.2, at: 10.5)
        #expect(monitor.state(at: 12.49) == .healthy)
        #expect(monitor.state(at: 12.5) == .stalled)
    }

    @Test func optionalSystemLivenessDoesNotCountTimeSpentPaused() {
        var liveness = OptionalSystemAudioLiveness(activeSince: 10)
        liveness.observeBuffer(at: 11)
        #expect(liveness.isStalled(at: 15, grace: 4))

        // A long wall-clock pause establishes a fresh active period. The
        // retained `.captured` source status is independent of this watchdog.
        liveness.beginActivePeriod(at: 100)
        #expect(!liveness.isStalled(at: 100.25, grace: 4))
        #expect(liveness.isStalled(at: 104, grace: 4))
    }

    @Test func retiredSourcePreferenceIsRemovedAndIgnored() {
        let suite = "RecordingSourcePreferenceMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("meeting", forKey: RecordingSourcePreferenceMigration.legacyKey)

        #expect(RecordingSourcePreferenceMigration.removeLegacyPreference(from: defaults))
        #expect(defaults.object(forKey: RecordingSourcePreferenceMigration.legacyKey) == nil)
        #expect(!RecordingSourcePreferenceMigration.removeLegacyPreference(from: defaults))
    }

    @Test func optionalSystemStatusesMapToHonestUserFacingState() {
        #expect(OptionalSystemAudioCaptureStatus.capturing.presentation == .init(
            text: "Mac audio available — listening for sound",
            symbolName: "speaker.wave.2",
            tone: .neutral
        ))
        #expect(OptionalSystemAudioCaptureStatus.captured.presentation.tone == .success)
        #expect(OptionalSystemAudioCaptureStatus.microphoneOnly(
            .permissionDenied
        ).presentation.text.contains("permission"))
        #expect(OptionalSystemAudioCaptureStatus.microphoneOnly(
            .noMeaningfulAudio
        ).presentation.text.contains("no Mac audio"))
        #expect(OptionalSystemAudioCaptureStatus.microphoneOnly(
            .mixFailed
        ).presentation.tone == .warning)
    }

    @Test func optionalSystemPermissionFlowStartsOnlyTheSidecar() {
        let request = OptionalSystemAudioCapturePolicy.transition(
            from: .notRequested,
            event: .begin(permission: .notDetermined)
        )
        #expect(request == .init(
            status: .awaitingPermission,
            actions: [.requestPermission]
        ))

        let granted = OptionalSystemAudioCapturePolicy.transition(
            from: request.status,
            event: .permissionResolved(.granted)
        )
        #expect(granted == .init(status: .starting, actions: [.startStream]))

        let started = OptionalSystemAudioCapturePolicy.transition(
            from: granted.status,
            event: .streamStarted
        )
        #expect(started == .init(status: .capturing, actions: []))
        #expect(started.status.acceptsSystemAudio)

        let captured = OptionalSystemAudioCapturePolicy.transition(
            from: started.status,
            event: .meaningfulBufferCaptured
        )
        #expect(captured == .init(status: .captured, actions: []))
        #expect(captured.status.acceptsSystemAudio)
    }

    @Test(arguments: [
        (OptionalSystemAudioPermission.denied, OptionalSystemAudioFallbackReason.permissionDenied),
        (.restricted, .permissionRestricted),
    ])
    func deniedOptionalPermissionFallsBackToMicrophone(
        permission: OptionalSystemAudioPermission,
        reason: OptionalSystemAudioFallbackReason
    ) {
        let transition = OptionalSystemAudioCapturePolicy.transition(
            from: .notRequested,
            event: .begin(permission: permission)
        )

        #expect(transition == .init(
            status: .microphoneOnly(reason),
            actions: [.continueMicrophoneOnly(reason)]
        ))
        #expect(!transition.status.acceptsSystemAudio)
    }

    @Test func optionalStreamStartFailureFallsBackToMicrophone() {
        let transition = OptionalSystemAudioCapturePolicy.transition(
            from: .starting,
            event: .streamStartFailed
        )

        #expect(transition == .init(
            status: .microphoneOnly(.startFailed),
            actions: [.stopStream, .continueMicrophoneOnly(.startFailed)]
        ))
    }

    @Test func optionalStreamStallStopsOnlySystemCapture() {
        let transition = OptionalSystemAudioCapturePolicy.transition(
            from: .captured,
            event: .stallDetected
        )

        #expect(transition == .init(
            status: .microphoneOnly(.stalled),
            actions: [.stopStream, .continueMicrophoneOnly(.stalled)]
        ))
    }

    @Test(arguments: [
        (OptionalSystemAudioCaptureEvent.invalidTiming,
         OptionalSystemAudioFallbackReason.invalidTiming),
        (.invalidFormat, .invalidFormat),
    ])
    func invalidSidecarDataStopsOnlySystemCapture(
        event: OptionalSystemAudioCaptureEvent,
        reason: OptionalSystemAudioFallbackReason
    ) {
        let transition = OptionalSystemAudioCapturePolicy.transition(
            from: .captured,
            event: event
        )

        #expect(transition == .init(
            status: .microphoneOnly(reason),
            actions: [.stopStream, .continueMicrophoneOnly(reason)]
        ))
    }

    @Test func sidecarWriteFailureStopsOnlySystemCapture() {
        let transition = OptionalSystemAudioCapturePolicy.transition(
            from: .captured,
            event: .sidecarWriteFailed
        )

        #expect(transition == .init(
            status: .microphoneOnly(.sidecarWriteFailed),
            actions: [.stopStream, .continueMicrophoneOnly(.sidecarWriteFailed)]
        ))
    }

    @Test(arguments: [
        OptionalSystemAudioCaptureStatus.awaitingPermission,
        .starting,
        .capturing,
        .captured,
    ])
    func finishMakesOptionalSystemCaptureTerminal(
        status: OptionalSystemAudioCaptureStatus
    ) {
        let finished = OptionalSystemAudioCapturePolicy.transition(
            from: status,
            event: .finish
        )
        let expectedActions: [OptionalSystemAudioCaptureAction] = switch status {
        case .starting, .capturing, .captured: [.stopStream]
        default: []
        }
        #expect(finished == .init(status: .finished, actions: expectedActions))

        let latePermission = OptionalSystemAudioCapturePolicy.transition(
            from: finished.status,
            event: .permissionResolved(.granted)
        )
        let lateBuffer = OptionalSystemAudioCapturePolicy.transition(
            from: finished.status,
            event: .meaningfulBufferCaptured
        )
        #expect(latePermission == .init(status: .finished, actions: []))
        #expect(lateBuffer == .init(status: .finished, actions: []))
    }

    @Test func cancelIsIdempotentAfterFallback() {
        let first = OptionalSystemAudioCapturePolicy.transition(
            from: .microphoneOnly(.permissionDenied),
            event: .cancel
        )
        let second = OptionalSystemAudioCapturePolicy.transition(
            from: first.status,
            event: .cancel
        )

        #expect(first == .init(status: .finished, actions: []))
        #expect(second == .init(status: .finished, actions: []))
    }

    @Test func lateCallbacksCannotReviveAFallbackSystemStream() {
        let fallback = OptionalSystemAudioCaptureStatus.microphoneOnly(.stalled)
        let lateStart = OptionalSystemAudioCapturePolicy.transition(
            from: fallback,
            event: .streamStarted
        )
        let latePermission = OptionalSystemAudioCapturePolicy.transition(
            from: fallback,
            event: .permissionResolved(.granted)
        )

        #expect(lateStart == .init(status: fallback, actions: []))
        #expect(latePermission == .init(status: fallback, actions: []))
    }

    @Test func earlyMeaningfulBufferSurvivesStreamStartContinuation() {
        let earlyBuffer = OptionalSystemAudioCapturePolicy.transition(
            from: .awaitingPermission,
            event: .meaningfulBufferCaptured
        )
        #expect(earlyBuffer.status == .captured)

        let startReturned = OptionalSystemAudioCapturePolicy.transition(
            from: earlyBuffer.status,
            event: .streamStarted
        )
        #expect(startReturned == .init(status: .captured, actions: []))
        #expect(startReturned.status.acceptsRuntimeCallbacks)
    }

    @Test func fallbackRejectsLateBuffersAndStreamStart() {
        let fallback = OptionalSystemAudioCaptureStatus.microphoneOnly(.invalidTiming)
        #expect(!fallback.acceptsRuntimeCallbacks)
        #expect(OptionalSystemAudioCapturePolicy.transition(
            from: fallback,
            event: .meaningfulBufferCaptured
        ) == .init(status: fallback, actions: []))
        #expect(OptionalSystemAudioCapturePolicy.transition(
            from: fallback,
            event: .streamStarted
        ) == .init(status: fallback, actions: []))
    }
}
