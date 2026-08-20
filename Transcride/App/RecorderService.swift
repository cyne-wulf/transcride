import AVFoundation
import Foundation
import Observation

/// REC-6 recording quality, stored in UserDefaults (`recordingQuality`).
enum RecordingQuality: String, CaseIterable, Identifiable, Sendable {
    case compressed = "aac"
    case lossless = "alac"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compressed: return "Compressed (AAC, 64 kbps)"
        case .lossless: return "Lossless (ALAC)"
        }
    }

    /// AVAudioFile settings: mono 44.1 kHz in both modes.
    var fileSettings: [String: Any] {
        outputEncoding.fileSettings
    }

    var outputEncoding: RecordingOutputEncoding {
        switch self {
        case .compressed: .aac
        case .lossless: .alac
        }
    }
}

enum RecordingStopCoordination<Outcome, Result> {
    case noOutcome
    case notReady(Outcome)
    case handedOff(Result)
}

/// Single ordering boundary for live-preview teardown, canonical installation,
/// and post-stop handoff. The readiness predicate prevents any downstream
/// consumer from seeing an outcome whose final install failed.
@MainActor
enum RecordingStopCoordinator {
    static func run<Outcome, Result>(
        clearLiveDisplay: () -> Void,
        finalizeAndInstall: () async -> Outcome?,
        isReadyForHandoff: (Outcome) -> Bool,
        handoffFinalized: (Outcome) async -> Result
    ) async -> RecordingStopCoordination<Outcome, Result> {
        clearLiveDisplay()
        guard let outcome = await finalizeAndInstall() else { return .noOutcome }
        guard isReadyForHandoff(outcome) else { return .notReady(outcome) }
        return .handedOff(await handoffFinalized(outcome))
    }
}

/// Starts an eventual cleanup chain without awaiting an optional-source start
/// continuation. A TCC-suspended ScreenCaptureKit task can therefore delay only
/// a future optional capture, never microphone finalization.
@MainActor
enum OptionalCaptureCleanupScheduler {
    static func schedule(
        prior: Task<Void, Never>?,
        suspendedStart: Task<Void, Never>?,
        cleanup: @escaping @MainActor @Sendable () async -> Void,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            if let prior { await prior.value }
            if let suspendedStart { await suspendedStart.value }
            await cleanup()
            completion()
        }
    }
}

/// Records microphone audio into an entry folder.
///
/// Pipeline: AVAudioEngine input tap → AVAudioConverter (to mono 44.1 kHz
/// float) → fixed-width PCM in a hidden `.recording.caf`. PCM needs no packet
/// table finalized at close, so a crash mid-recording leaves a readable
/// partial file. On stop the journal is encoded to the selected AAC/ALAC M4A,
/// and `waveform.json` + the stub transcript are written.
@MainActor
@Observable
final class RecorderService {
    /// Publish recorded time and live waveform changes at a consistent cadence
    /// regardless of the input device's sample rate. A fixed frame count makes
    /// low-rate Bluetooth microphones update only a few times per second.
    nonisolated static let liveUpdateInterval: TimeInterval = 0.1

    nonisolated static func liveUpdateBufferSize(for sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(max(1, Int((sampleRate * liveUpdateInterval).rounded())))
    }

    nonisolated static func classifyCaptureResult(
        frames: Int64,
        microphoneHasSignal: Bool,
        firstMeaningfulSystemFrame: Int64?
    ) -> FinalizationOutcome.CaptureResult {
        guard frames > 0 else { return .noFrames }
        return microphoneHasSignal || firstMeaningfulSystemFrame != nil
            ? .captured : .noSignal
    }

    enum SessionTarget: Equatable, Sendable {
        case newEntry
        case extensionOf(RecordingExtensionTarget)
        case replacementTake(ReplacementRecordingTarget)
    }

    struct FinalizationOutcome: Sendable {
        enum CaptureResult: Equatable, Sendable {
            case captured
            case noSignal
            case noFrames
        }

        var entryRelativePath: RelativePath
        var target: SessionTarget
        var duration: Double
        var captureResult: CaptureResult
        /// True only after the visible canonical audio and its companion entry
        /// metadata have been installed successfully.
        var canonicalAudioInstalled: Bool
        /// Expected terminal outcomes (including an empty capture) may still be
        /// handed back for UI cleanup. Unexpected finalization failures may not.
        var finalizationSucceeded: Bool
        var systemAudioStatus: OptionalSystemAudioCaptureStatus
        var extensionSegmentURL: URL?
        var replacementTake: ReplacementTake?
        var replacementTakeURL: URL?
    }

    enum State: Equatable {
        case idle
        case recording
        case paused
        case finalizing
    }

    nonisolated static let partialFileName = RecorderPartialFile.name

    /// Side-channel copy of the input for live transcription. The recording
    /// path never depends on it: the sink writes first, then the tee relays
    /// the same buffer (or drops it silently when no handler is attached).
    nonisolated let liveTee = LiveAudioTee()

    private(set) var state: State = .idle
    /// `.finalizing` is also the lifecycle lock used while Core Audio settles.
    /// This discriminator lets presentation code say "Starting microphone"
    /// without weakening the vault-switch and termination guards.
    private(set) var isStartingMicrophone = false
    /// Recorded audio time in seconds (excludes pauses).
    private(set) var elapsed: Double = 0
    /// Tail of the live waveform (canonical resolution, newest last).
    private(set) var livePeaks: [Float] = []
    /// Liveness is based on frames and samples received, not merely on an
    /// engine/stream reporting that it started.
    private(set) var captureHealth: RecordingCaptureHealthState = .inactive
    private(set) var captureHealthMessage: String?
    /// Mac audio is an optional companion to the authoritative microphone
    /// journal. This state is informational and never changes recorder health.
    private(set) var systemAudioStatus: OptionalSystemAudioCaptureStatus = .notRequested
    private(set) var systemAudioPeak: Float = 0
    /// Vault-relative path of the entry being recorded; nil when idle.
    private(set) var currentEntryPath: RelativePath?
    /// Explicit capture purpose; views and finalization never infer it from a
    /// hidden filename.
    private(set) var sessionTarget: SessionTarget?
    private(set) var extensionSession: RecordingExtensionSession?
    /// Recording problems surfaced to the UI (device loss, disk errors).
    var alertMessage: String?
    var isZenMode = false

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var activeSinkID: UUID?
    private var recordingTimeline: UniversalRecordingTimeline?
    private var systemAudioCapture: UniversalSystemAudioCaptureService?
    private var systemAudioCaptureID: UUID?
    private var systemAudioStartTask: Task<Void, Never>?
    private var systemAudioCleanupTask: Task<Void, Never>?
    private var systemAudioCleanupID: UUID?
    private var systemAudioArtifactURL: URL?
    private var systemAudioLiveness: OptionalSystemAudioLiveness?
    private var systemAudioTeardownInFlight = false
    private var entryURL: URL?
    private var retainedExtensionEntryURL: URL?
    private var entryCreated: Date = .now
    private var sampleRate: Double = 44_100
    private var recordingQuality: RecordingQuality = .compressed
    private var configChangeObserver: NSObjectProtocol?
    private var baselineInputSignature: RecordingInputSignature?
    private var recordingStartUptime: TimeInterval?
    private var configurationChangeCount = 0
    private var configurationChangePending = false
    private var isHandlingConfigurationChange = false
    private var configurationChangeCircuitBreaker =
        RecordingConfigurationChangeCircuitBreaker()
    private var inputTapInstalled = false
    private(set) var requiresStopAfterInputChange = false
    private var reportedSinkError = false
    private var replacementBoundaryRequested = false
    private var captureHealthMonitor: RecordingCaptureHealthMonitor?
    private var captureHealthTask: Task<Void, Never>?
    private var microphoneFailureSessionID: UUID?
    private var microphoneFailurePreferredUID = ""
    private var microphoneStartupAttemptNumber: Int?
    private var microphoneRequestedDeviceID: AudioDeviceID?
    private var microphoneFirstBufferFormat: AVAudioFormat?
    private var microphoneFirstBufferLatency: TimeInterval?
    /// Non-nil only while an extension microphone is starting. Ordinary
    /// rollback removes the provisional manifest/CAF; a hard crash naturally
    /// retains both so extension recovery can classify the partial capture.
    private var startupExtensionEntryURL: URL?

    /// AppModel installs this only while a replacement attempt is active. The
    /// trigger comes from the sink's frame-derived elapsed time, never a UI timer.
    var onReplacementBoundaryReached: (() -> Void)?

    var isActive: Bool { state != .idle }
    var canResume: Bool { state == .paused && !requiresStopAfterInputChange }

    // MARK: - Permission

    static func ensureMicPermission(
        target: MicrophoneFailureEvent.Target,
        preferredMicUID: String
    ) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        guard !granted else { return true }
        let failureReason: MicrophoneFailureEvent.Reason = status == .restricted
            ? .permissionRestricted
            : .permissionDenied
        MicrophoneFailureLogger.shared.log(MicrophoneFailureEvent(
            sessionID: UUID(),
            kind: .initializationFailed,
            target: target,
            stage: .permission,
            reason: failureReason,
            preferredRoute: failurePreferredRoute(uid: preferredMicUID),
            resolvedDeviceFormat: nil,
            engineState: .init(
                phase: .notCreated, isRunning: false, tapInstalled: false
            ),
            frames: 0,
            elapsedSeconds: 0
        ))
        return false
    }

    private static func failureTarget(
        for target: SessionTarget?
    ) -> MicrophoneFailureEvent.Target {
        switch target {
        case .newEntry: .newEntry
        case .extensionOf: .extensionRecording
        case .replacementTake: .replacementTake
        case nil: .unknown
        }
    }

    private static func failurePreferredRoute(
        uid: String
    ) -> MicrophoneFailureEvent.PreferredRoute {
        uid.isEmpty ? .systemDefault : .selectedDevice(uid: uid)
    }

    private static func failureSampleFormat(
        _ format: AVAudioFormat?
    ) -> MicrophoneFailureEvent.ResolvedDeviceFormat.SampleFormat {
        guard let format else { return .unknown }
        return switch format.commonFormat {
        case .pcmFormatFloat32: .float32
        case .pcmFormatFloat64: .float64
        case .pcmFormatInt16: .int16
        case .pcmFormatInt32: .int32
        case .otherFormat: .other
        @unknown default: .unknown
        }
    }

    private func logMicrophoneFailure(
        kind: MicrophoneFailureEvent.Kind,
        stage: MicrophoneFailureEvent.Stage,
        reason: MicrophoneFailureEvent.Reason,
        sessionID: UUID? = nil,
        target: SessionTarget? = nil,
        preferredMicUID: String? = nil,
        attemptNumber: Int? = nil,
        requestedDeviceID: AudioDeviceID? = nil,
        baselineSignature: RecordingInputSignature? = nil,
        resolvedSignature: RecordingInputSignature? = nil,
        inputFormat: AVAudioFormat? = nil,
        firstBufferFormat: AVAudioFormat? = nil,
        firstBufferLatency: TimeInterval? = nil,
        enginePhase: MicrophoneFailureEvent.EngineState.Phase? = nil,
        engineRunning: Bool? = nil,
        tapInstalled: Bool? = nil,
        frames: Int64? = nil,
        elapsedSeconds: TimeInterval? = nil,
        error: Error? = nil
    ) {
        let currentEngine = engine
        let baseline = baselineSignature ?? baselineInputSignature
        // Runtime failures must snapshot the route at the failure, not silently
        // fall back to the start-of-session route which may be the thing that
        // disappeared. Startup call sites pass their local fresh engine.
        let current = resolvedSignature ?? currentEngine.map(Self.inputSignature)
        let resolvedFormat = Self.failureResolvedFormat(
            signature: current,
            format: inputFormat
        )
        let baselineFormat = Self.failureResolvedFormat(signature: baseline)
        let firstFormat = firstBufferFormat ?? microphoneFirstBufferFormat
        let firstResolvedFormat = Self.failureResolvedFormat(
            signature: firstFormat == nil ? nil : baseline,
            format: firstFormat
        )
        let phase: MicrophoneFailureEvent.EngineState.Phase
        if let enginePhase {
            phase = enginePhase
        } else {
            phase = switch state {
            case .idle: .stopped
            case .recording: .running
            case .paused: .paused
            case .finalizing: .finalizing
            }
        }
        MicrophoneFailureLogger.shared.log(MicrophoneFailureEvent(
            sessionID: sessionID ?? microphoneFailureSessionID ?? UUID(),
            kind: kind,
            target: Self.failureTarget(for: target ?? sessionTarget),
            stage: stage,
            reason: reason,
            preferredRoute: Self.failurePreferredRoute(
                uid: preferredMicUID ?? microphoneFailurePreferredUID
            ),
            resolvedDeviceFormat: resolvedFormat,
            engineState: .init(
                phase: phase,
                isRunning: engineRunning ?? currentEngine?.isRunning ?? false,
                tapInstalled: tapInstalled ?? inputTapInstalled,
                firstBufferConfirmed: (frames ?? sink?.frameCount ?? 0) > 0
            ),
            frames: frames ?? sink?.frameCount ?? 0,
            elapsedSeconds: elapsedSeconds ?? elapsed,
            error: error.map(MicrophoneFailureEvent.ErrorIdentity.init),
            attemptNumber: attemptNumber ?? microphoneStartupAttemptNumber,
            requestedDeviceID: requestedDeviceID ?? microphoneRequestedDeviceID,
            baselineDeviceFormat: baselineFormat,
            currentDeviceFormat: resolvedFormat,
            firstBufferFormat: firstResolvedFormat,
            firstBufferLatencySeconds: firstBufferLatency ?? microphoneFirstBufferLatency
        ))
    }

    private static func failureResolvedFormat(
        signature: RecordingInputSignature?,
        format: AVAudioFormat? = nil
    ) -> MicrophoneFailureEvent.ResolvedDeviceFormat? {
        guard signature != nil || format != nil else { return nil }
        return .init(
            deviceID: signature?.deviceID,
            sampleRate: format?.sampleRate ?? signature?.sampleRate,
            channelCount: format?.channelCount ?? signature?.channelCount,
            sampleFormat: failureSampleFormat(format),
            isInterleaved: format?.isInterleaved
        )
    }

    private func clearMicrophoneFailureContext() {
        microphoneFailureSessionID = nil
        microphoneFailurePreferredUID = ""
        microphoneStartupAttemptNumber = nil
        microphoneRequestedDeviceID = nil
        microphoneFirstBufferFormat = nil
        microphoneFirstBufferLatency = nil
    }

    // MARK: - Start / pause / resume

    private struct MicrophoneStartupResources {
        var engine: AVAudioEngine
        var sink: RecordingSink
        var sinkID: UUID
        var timeline: UniversalRecordingTimeline?
        var configurationObserver: NSObjectProtocol
        var gate: MicrophoneStartupGate
        var journalURL: URL
        var baseline: RecordingInputSignature
        var requestedDeviceID: AudioDeviceID
        var firstBufferFormat: AVAudioFormat
        var firstBufferLatency: TimeInterval
        var startedAt: TimeInterval
        var setDeviceStatus: OSStatus
        var attemptNumber: Int
    }

    private struct MicrophoneStartupAttemptFailure: Error {
        var underlying: Error
        var retryable: Bool
    }

    private static let maximumMicrophoneStartupAttempts = 3

    /// Starts recording into `entryURL` (an already-created entry folder).
    func start(
        entryURL: URL,
        relativePath: RelativePath,
        quality: RecordingQuality,
        preferredMicUID: String,
        target: SessionTarget = .newEntry
    ) async throws {
        guard RecordingStartAdmissionPolicy.classify(
            recorderIsIdle: state == .idle
        ) == .begin else {
            throw RecorderError.recordingAlreadyActive
        }
        // `start()` is actor-reentrant while Core Audio settles. Use the same
        // lifecycle lock as finalization so quit, vault switches, and a second
        // recording command cannot enter while an attempt owns a tap or file.
        state = .finalizing
        isStartingMicrophone = true
        let failureSessionID = UUID()
        microphoneFailureSessionID = failureSessionID
        microphoneFailurePreferredUID = preferredMicUID
        defer {
            if isStartingMicrophone {
                rollbackMicrophoneStartup()
            }
        }
        if case .extensionOf(let extensionTarget) = target {
            let provisionalSession = RecordingExtensionSession(target: extensionTarget)
            startupExtensionEntryURL = entryURL
            extensionSession = provisionalSession
            try persistProvisionalExtensionSession(
                provisionalSession,
                in: entryURL
            )
        } else {
            startupExtensionEntryURL = nil
            extensionSession = nil
        }
        let partialName = switch target {
        case .newEntry: Self.partialFileName
        case .extensionOf: RecordingExtensionArtifacts.partialFileName
        case .replacementTake: AudioReplacementArtifacts.partialFileName
        }
        let cafURL = entryURL.appending(path: partialName)
        var resources: MicrophoneStartupResources?
        var terminalError: Error = RecorderError.noAudioCaptured
        for attempt in 1...Self.maximumMicrophoneStartupAttempts {
            microphoneStartupAttemptNumber = attempt
            do {
                let candidate = try await startMicrophoneAttempt(
                    canonicalJournalURL: cafURL,
                    target: target,
                    preferredMicUID: preferredMicUID,
                    failureSessionID: failureSessionID,
                    attemptNumber: attempt
                )
                do {
                    try validateMicrophoneStartupCandidateForCommit(
                        candidate,
                        target: target,
                        preferredMicUID: preferredMicUID,
                        failureSessionID: failureSessionID
                    )
                } catch {
                    disposeMicrophoneStartupResources(candidate)
                    throw error
                }
                resources = candidate
                break
            } catch let failure as MicrophoneStartupAttemptFailure {
                terminalError = failure.underlying
                guard failure.retryable,
                      attempt < Self.maximumMicrophoneStartupAttempts else {
                    throw failure.underlying
                }
                DebugLog.append(
                    "recorder: microphone startup attempt \(attempt) failed; rebuilding graph"
                )
                try await Task.sleep(for: .milliseconds(attempt == 1 ? 75 : 175))
            }
        }
        guard let resources else { throw terminalError }

        let engine = resources.engine
        let sink = resources.sink
        let timeline = resources.timeline
        let targetFormat = sink.targetAudioFormat
        self.engine = engine
        self.sink = sink
        activeSinkID = resources.sinkID
        recordingTimeline = timeline
        self.entryURL = entryURL
        self.sampleRate = targetFormat.sampleRate
        recordingQuality = quality
        currentEntryPath = relativePath
        sessionTarget = target
        if case .extensionOf = target {
            // Reuse the manifest that was durably installed before the first
            // attempt opened `.extension-recording.caf`.
            startupExtensionEntryURL = nil
        } else {
            extensionSession = nil
        }
        entryCreated = EntryFolderName(parsing: entryURL.lastPathComponent)?.date ?? .now
        elapsed = 0
        livePeaks = []
        alertMessage = nil
        captureHealthMessage = nil
        captureHealth = .awaitingFirstBuffer
        systemAudioStatus = .notRequested
        systemAudioPeak = 0
        systemAudioLiveness = nil
        systemAudioTeardownInFlight = false
        baselineInputSignature = resources.baseline
        microphoneRequestedDeviceID = resources.requestedDeviceID
        microphoneFirstBufferFormat = resources.firstBufferFormat
        microphoneFirstBufferLatency = resources.firstBufferLatency
        recordingStartUptime = resources.startedAt
        configurationChangeCount = 0
        configurationChangePending = false
        isHandlingConfigurationChange = false
        configurationChangeCircuitBreaker.reset()
        inputTapInstalled = true
        requiresStopAfterInputChange = false
        reportedSinkError = false
        replacementBoundaryRequested = false
        configChangeObserver = resources.configurationObserver
        isStartingMicrophone = false
        state = .recording
        // Callback delivery becomes live only after every resource and public
        // state field belongs to this service. There is no await between the
        // final sink/route check above and this activation barrier.
        resources.gate.commit()
        beginCaptureHealthMonitoring(framesWritten: sink.frameCount)
        if case .newEntry = target, let timeline {
            beginOptionalSystemAudioCapture(
                canonicalFormat: targetFormat,
                timeline: timeline,
                entryURL: entryURL
            )
        }
        DebugLog.append(
            "recorder: started [\(relativePath)] quality=\(quality.rawValue) "
                + "input={\(Self.describe(resources.baseline))} "
                + "preferred_uid=\(preferredMicUID.isEmpty ? "<system-default>" : preferredMicUID) "
                + "set_device_status=\(resources.setDeviceStatus) "
                + "attempt=\(resources.attemptNumber) "
                + "first_buffer_latency=\(String(format: "%.3f", resources.firstBufferLatency))s "
                + "engine_running=\(engine.isRunning)"
        )
    }

    private func startMicrophoneAttempt(
        canonicalJournalURL: URL,
        target: SessionTarget,
        preferredMicUID: String,
        failureSessionID: UUID,
        attemptNumber: Int
    ) async throws -> MicrophoneStartupResources {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let requestedDeviceID: AudioDeviceID
        if preferredMicUID.isEmpty {
            guard let deviceID = AudioInputDevices.defaultInputDeviceID(),
                  AudioInputDevices.isUsableInputDevice(deviceID) else {
                logMicrophoneFailure(
                    kind: .initializationFailed,
                    stage: .deviceSelection,
                    reason: .noInputDevice,
                    sessionID: failureSessionID,
                    target: target,
                    preferredMicUID: preferredMicUID,
                    attemptNumber: attemptNumber,
                    resolvedSignature: Self.inputSignature(for: engine),
                    enginePhase: .created
                )
                throw MicrophoneStartupAttemptFailure(
                    underlying: RecorderError.noInputDevice,
                    retryable: true
                )
            }
            requestedDeviceID = deviceID
        } else {
            guard let device = AudioInputDevices.allInputDevices().first(where: {
                $0.uid == preferredMicUID
            }) else {
                logMicrophoneFailure(
                    kind: .initializationFailed,
                    stage: .deviceSelection,
                    reason: .selectedInputUnavailable,
                    sessionID: failureSessionID,
                    target: target,
                    preferredMicUID: preferredMicUID,
                    attemptNumber: attemptNumber,
                    resolvedSignature: Self.inputSignature(for: engine),
                    enginePhase: .created
                )
                // A selected microphone that is not in the device list will not
                // appear by rebuilding the graph. Failing on the first attempt
                // keeps eyes-off feedback immediate instead of spending the
                // retry budget before the indicator can say what is wrong.
                throw MicrophoneStartupAttemptFailure(
                    underlying: RecorderError.selectedInputUnavailable,
                    retryable: false
                )
            }
            requestedDeviceID = device.deviceID
        }
        microphoneRequestedDeviceID = requestedDeviceID
        let requestedSignature = Self.inputSignature(forDeviceID: requestedDeviceID)

        guard let unit = input.audioUnit else {
            logMicrophoneFailure(
                kind: .initializationFailed,
                stage: .deviceSelection,
                reason: .selectedInputUnavailable,
                sessionID: failureSessionID,
                target: target,
                preferredMicUID: preferredMicUID,
                attemptNumber: attemptNumber,
                requestedDeviceID: requestedDeviceID,
                baselineSignature: requestedSignature,
                resolvedSignature: Self.inputSignature(for: engine),
                enginePhase: .created
            )
            throw MicrophoneStartupAttemptFailure(
                underlying: RecorderError.selectedInputUnavailable,
                retryable: true
            )
        }
        var mutableDeviceID = requestedDeviceID
        let setDeviceStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setDeviceStatus == noErr else {
            let statusError = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(setDeviceStatus)
            )
            logMicrophoneFailure(
                kind: .initializationFailed,
                stage: .deviceSelection,
                reason: .selectedInputUnavailable,
                sessionID: failureSessionID,
                target: target,
                preferredMicUID: preferredMicUID,
                attemptNumber: attemptNumber,
                requestedDeviceID: requestedDeviceID,
                baselineSignature: requestedSignature,
                resolvedSignature: Self.inputSignature(for: engine),
                enginePhase: .created,
                error: statusError
            )
            throw MicrophoneStartupAttemptFailure(
                underlying: RecorderError.selectedInputUnavailable,
                retryable: true
            )
        }

        // The attempt writes the canonical hidden partial directly. A rejected
        // attempt is closed and deleted before retry; a hard crash remains
        // discoverable by the existing interrupted-recording recovery scan.
        let attemptURL = canonicalJournalURL
        try? FileManager.default.removeItem(at: attemptURL)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: attemptURL,
                settings: CrashTolerantAudioJournal.fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            logMicrophoneFailure(
                kind: .initializationFailed,
                stage: .journalCreation,
                reason: .journalCreationFailed,
                sessionID: failureSessionID,
                target: target,
                preferredMicUID: preferredMicUID,
                attemptNumber: attemptNumber,
                requestedDeviceID: requestedDeviceID,
                baselineSignature: requestedSignature,
                resolvedSignature: Self.inputSignature(for: engine),
                enginePhase: .created,
                error: error
            )
            throw MicrophoneStartupAttemptFailure(
                underlying: error,
                retryable: false
            )
        }
        let targetFormat = file.processingFormat
        let timeline: UniversalRecordingTimeline? = switch target {
        case .newEntry:
            UniversalRecordingTimeline(sampleRate: targetFormat.sampleRate)
        case .extensionOf, .replacementTake:
            nil
        }
        timeline?.beginSegment(atFrame: 0)
        let gate = MicrophoneStartupGate()
        let sinkID = UUID()
        let sink = RecordingSink(
            file: file,
            targetFormat: targetFormat
        ) { [weak self] elapsed, peaksTail, error, inputFormatChanged, framesWritten, bufferPeak in
            Task { @MainActor [weak self] in
                self?.applySinkUpdate(
                    sinkID: sinkID,
                    elapsed: elapsed,
                    peaksTail: peaksTail,
                    error: error,
                    inputFormatChanged: inputFormatChanged,
                    framesWritten: framesWritten,
                    bufferPeak: bufferPeak
                )
            }
        }
        var tapInstalled = false
        var keepResources = false
        var configurationObserver: NSObjectProtocol?
        defer {
            if !keepResources {
                gate.deactivate()
                if let configurationObserver {
                    NotificationCenter.default.removeObserver(configurationObserver)
                }
                if tapInstalled {
                    input.removeTap(onBus: 0)
                }
                engine.stop()
                sink.finish()
                try? FileManager.default.removeItem(at: attemptURL)
            }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            gate.observeConfigurationChange(
                at: ProcessInfo.processInfo.systemUptime
            )
            guard gate.isCommitted else { return }
            Task { @MainActor [weak self] in
                await self?.receiveConfigurationChange()
            }
        }

        // Nil is intentional: AVAudioEngine must negotiate the selected
        // physical device's delivered format. Passing outputFormat here can
        // freeze the default aggregate's stale 44.1 kHz client format onto a
        // 48 kHz built-in or 16 kHz Bluetooth input and silently reject the tap.
        let liveTee = liveTee
        input.installTap(
            onBus: 0,
            bufferSize: Self.liveUpdateBufferSize(
                for: requestedSignature.sampleRate > 0
                    ? requestedSignature.sampleRate
                    : targetFormat.sampleRate
            ),
            format: nil
        ) { @Sendable buffer, when in
            let canonicalStartFrame = sink.frameCount
            if let recordedBuffer = sink.process(buffer) {
                gate.observeFirstCanonicalBuffer(
                    format: buffer.format,
                    at: ProcessInfo.processInfo.systemUptime
                )
                if when.isHostTimeValid {
                    timeline?.observeMicrophoneBuffer(
                        startFrame: canonicalStartFrame,
                        frameCount: Int(recordedBuffer.frameLength),
                        hostTime: when.hostTime
                    )
                }
                // AppModel attaches live transcription after start returns.
                // Explicitly gate the tee as well so buffers from an attempt
                // that will be discarded can never shift karaoke timing.
                if gate.isCommitted {
                    liveTee.send(recordedBuffer)
                }
            }
        }
        tapInstalled = true

        let startedAt = ProcessInfo.processInfo.systemUptime
        gate.begin(at: startedAt)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            let snapshot = gate.snapshot()
            logMicrophoneFailure(
                kind: .initializationFailed,
                stage: .engineStart,
                reason: .engineStartFailed,
                sessionID: failureSessionID,
                target: target,
                preferredMicUID: preferredMicUID,
                attemptNumber: attemptNumber,
                requestedDeviceID: requestedDeviceID,
                baselineSignature: requestedSignature,
                resolvedSignature: Self.inputSignature(for: engine),
                firstBufferFormat: snapshot.firstBufferFormat,
                firstBufferLatency: snapshot.firstBufferLatency,
                enginePhase: .prepared,
                engineRunning: engine.isRunning,
                tapInstalled: tapInstalled,
                frames: sink.frameCount,
                error: error
            )
            throw MicrophoneStartupAttemptFailure(
                underlying: error,
                retryable: true
            )
        }

        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let current = Self.inputSignature(for: engine)
            let snapshot = gate.snapshot()
            if let error = sink.currentError {
                logMicrophoneFailure(
                    kind: .initializationFailed,
                    stage: .firstBuffer,
                    reason: .sinkWriteFailed,
                    sessionID: failureSessionID,
                    target: target,
                    preferredMicUID: preferredMicUID,
                    attemptNumber: attemptNumber,
                    requestedDeviceID: requestedDeviceID,
                    baselineSignature: requestedSignature,
                    resolvedSignature: current,
                    firstBufferFormat: snapshot.firstBufferFormat,
                    firstBufferLatency: snapshot.firstBufferLatency,
                    enginePhase: engine.isRunning ? .running : .stopped,
                    engineRunning: engine.isRunning,
                    tapInstalled: tapInstalled,
                    frames: sink.frameCount,
                    error: error
                )
                throw MicrophoneStartupAttemptFailure(
                    underlying: error,
                    retryable: false
                )
            }
            var decision = MicrophoneStartupValidationPolicy.classify(
                now: now,
                startedAt: startedAt,
                lastConfigurationChangeAt: snapshot.lastConfigurationChangeAt,
                requested: requestedSignature,
                current: current,
                engineIsRunning: engine.isRunning,
                deliveredFormatChanged: sink.inputFormatMismatchDetected,
                canonicalFrames: sink.frameCount
            )
            if decision == .ready,
               sink.inputFormatMismatchDetected {
                decision = .retry(.deliveredFormatChanged)
            }
            switch decision {
            case .waiting:
                try await Task.sleep(for: .milliseconds(25))
            case .ready:
                guard let deliveredFormat = snapshot.firstBufferFormat,
                      let firstBufferLatency = snapshot.firstBufferLatency else {
                    // The policy cannot be ready without canonical frames; keep
                    // this guard defensive against an impossible torn snapshot.
                    try await Task.sleep(for: .milliseconds(25))
                    continue
                }
                // Route compatibility stays in the physical-device domain.
                // The negotiated tap may legitimately be client-converted;
                // its delivered format is tracked independently by the sink
                // and durable first-buffer diagnostics.
                let committedBaseline = requestedSignature
                keepResources = true
                return MicrophoneStartupResources(
                    engine: engine,
                    sink: sink,
                    sinkID: sinkID,
                    timeline: timeline,
                    configurationObserver: configurationObserver!,
                    gate: gate,
                    journalURL: attemptURL,
                    baseline: committedBaseline,
                    requestedDeviceID: requestedDeviceID,
                    firstBufferFormat: deliveredFormat,
                    firstBufferLatency: firstBufferLatency,
                    startedAt: startedAt,
                    setDeviceStatus: setDeviceStatus,
                    attemptNumber: attemptNumber
                )
            case .retry(let failure):
                let kind: MicrophoneFailureEvent.Kind
                let stage: MicrophoneFailureEvent.Stage
                let reason: MicrophoneFailureEvent.Reason
                let underlying: Error
                switch failure {
                case .noCanonicalFrames:
                    kind = .noAudioAfterStart
                    stage = .firstBuffer
                    reason = .noBuffers
                    underlying = RecorderError.noAudioCaptured
                case .engineStopped:
                    kind = .initializationFailed
                    stage = .postStartValidation
                    reason = .engineStopped
                    underlying = RecorderError.noAudioCaptured
                case .unusableRoute:
                    kind = .initializationFailed
                    stage = .postStartValidation
                    reason = .unusableResolvedInput
                    underlying = RecorderError.noInputDevice
                case .routeMismatch:
                    kind = .initializationFailed
                    stage = .postStartValidation
                    reason = .selectedInputMismatch
                    underlying = RecorderError.selectedInputMismatch
                case .routeUnstable:
                    kind = .initializationFailed
                    stage = .postStartValidation
                    reason = .inputChanged
                    underlying = RecorderError.selectedInputMismatch
                case .deliveredFormatChanged:
                    kind = .initializationFailed
                    stage = .inputFormat
                    reason = .inputChanged
                    underlying = RecorderError.formatUnsupported
                }
                logMicrophoneFailure(
                    kind: kind,
                    stage: stage,
                    reason: reason,
                    sessionID: failureSessionID,
                    target: target,
                    preferredMicUID: preferredMicUID,
                    attemptNumber: attemptNumber,
                    requestedDeviceID: requestedDeviceID,
                    baselineSignature: requestedSignature,
                    resolvedSignature: current,
                    firstBufferFormat: snapshot.firstBufferFormat,
                    firstBufferLatency: snapshot.firstBufferLatency,
                    enginePhase: engine.isRunning ? .running : .stopped,
                    engineRunning: engine.isRunning,
                    tapInstalled: tapInstalled,
                    frames: sink.frameCount
                )
                throw MicrophoneStartupAttemptFailure(
                    underlying: underlying,
                    retryable: true
                )
            }
        }
    }

    /// Re-checks the candidate after the awaited attempt returns to the owning
    /// `start` frame. Configuration notifications and tap format changes remain
    /// observable while callbacks are inactive; any activity in that handoff
    /// gap rejects the disposable graph instead of being silently dropped.
    private func validateMicrophoneStartupCandidateForCommit(
        _ resources: MicrophoneStartupResources,
        target: SessionTarget,
        preferredMicUID: String,
        failureSessionID: UUID
    ) throws {
        let engine = resources.engine
        let sink = resources.sink
        let snapshot = resources.gate.snapshot()
        let current = Self.inputSignature(for: engine)
        if let error = sink.currentError {
            logMicrophoneFailure(
                kind: .initializationFailed,
                stage: .firstBuffer,
                reason: .sinkWriteFailed,
                sessionID: failureSessionID,
                target: target,
                preferredMicUID: preferredMicUID,
                attemptNumber: resources.attemptNumber,
                requestedDeviceID: resources.requestedDeviceID,
                baselineSignature: resources.baseline,
                resolvedSignature: current,
                firstBufferFormat: snapshot.firstBufferFormat,
                firstBufferLatency: snapshot.firstBufferLatency,
                enginePhase: engine.isRunning ? .running : .stopped,
                engineRunning: engine.isRunning,
                tapInstalled: true,
                frames: sink.frameCount,
                error: error
            )
            throw MicrophoneStartupAttemptFailure(
                underlying: error,
                retryable: false
            )
        }
        var decision = MicrophoneStartupValidationPolicy.classify(
            now: ProcessInfo.processInfo.systemUptime,
            startedAt: resources.startedAt,
            lastConfigurationChangeAt: snapshot.lastConfigurationChangeAt,
            requested: resources.baseline,
            current: current,
            engineIsRunning: engine.isRunning,
            deliveredFormatChanged: sink.inputFormatMismatchDetected,
            canonicalFrames: sink.frameCount
        )
        // This candidate had already reached `.ready`; waiting here means a
        // fresh route notification landed during the async handoff.
        if decision == .waiting {
            decision = .retry(.routeUnstable)
        }
        if decision == .ready,
           !sink.commitStartupIfInputFormatStable() {
            decision = .retry(.deliveredFormatChanged)
        }
        guard case .retry(let failure) = decision else { return }

        let kind: MicrophoneFailureEvent.Kind
        let stage: MicrophoneFailureEvent.Stage
        let reason: MicrophoneFailureEvent.Reason
        let underlying: Error
        switch failure {
        case .noCanonicalFrames:
            kind = .noAudioAfterStart
            stage = .firstBuffer
            reason = .noBuffers
            underlying = RecorderError.noAudioCaptured
        case .engineStopped:
            kind = .initializationFailed
            stage = .postStartValidation
            reason = .engineStopped
            underlying = RecorderError.noAudioCaptured
        case .unusableRoute:
            kind = .initializationFailed
            stage = .postStartValidation
            reason = .unusableResolvedInput
            underlying = RecorderError.noInputDevice
        case .routeMismatch:
            kind = .initializationFailed
            stage = .postStartValidation
            reason = .selectedInputMismatch
            underlying = RecorderError.selectedInputMismatch
        case .routeUnstable:
            kind = .initializationFailed
            stage = .postStartValidation
            reason = .inputChanged
            underlying = RecorderError.selectedInputMismatch
        case .deliveredFormatChanged:
            kind = .initializationFailed
            stage = .inputFormat
            reason = .inputChanged
            underlying = RecorderError.formatUnsupported
        }
        logMicrophoneFailure(
            kind: kind,
            stage: stage,
            reason: reason,
            sessionID: failureSessionID,
            target: target,
            preferredMicUID: preferredMicUID,
            attemptNumber: resources.attemptNumber,
            requestedDeviceID: resources.requestedDeviceID,
            baselineSignature: resources.baseline,
            resolvedSignature: current,
            firstBufferFormat: snapshot.firstBufferFormat,
            firstBufferLatency: snapshot.firstBufferLatency,
            enginePhase: engine.isRunning ? .running : .stopped,
            engineRunning: engine.isRunning,
            tapInstalled: true,
            frames: sink.frameCount
        )
        throw MicrophoneStartupAttemptFailure(
            underlying: underlying,
            retryable: true
        )
    }

    private func disposeMicrophoneStartupResources(
        _ resources: MicrophoneStartupResources
    ) {
        resources.gate.deactivate()
        NotificationCenter.default.removeObserver(resources.configurationObserver)
        resources.engine.inputNode.removeTap(onBus: 0)
        resources.engine.stop()
        resources.sink.finish()
        try? FileManager.default.removeItem(at: resources.journalURL)
    }

    private func rollbackMicrophoneStartup() {
        if let startupExtensionEntryURL {
            RecordingExtensionArtifacts.rollbackProvisionalStartup(
                in: startupExtensionEntryURL
            )
        }
        startupExtensionEntryURL = nil
        extensionSession = nil
        removeConfigurationChangeObserver()
        engine = nil
        sink = nil
        activeSinkID = nil
        recordingTimeline = nil
        entryURL = nil
        baselineInputSignature = nil
        recordingStartUptime = nil
        inputTapInstalled = false
        configurationChangePending = false
        isHandlingConfigurationChange = false
        isStartingMicrophone = false
        captureHealth = .inactive
        captureHealthMessage = nil
        clearMicrophoneFailureContext()
        state = .idle
    }

    /// Starts ScreenCaptureKit only after the microphone journal is live. The
    /// task is intentionally not awaited: TCC or stream startup can suspend,
    /// but neither is allowed to delay the first microphone frame.
    private func beginOptionalSystemAudioCapture(
        canonicalFormat: AVAudioFormat,
        timeline: UniversalRecordingTimeline,
        entryURL: URL
    ) {
        let captureID = UUID()
        let service = UniversalSystemAudioCaptureService(
            canonicalFormat: canonicalFormat,
            timeline: timeline,
            entryURL: entryURL
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleSystemAudioEvent(event, captureID: captureID)
            }
        }
        systemAudioCaptureID = captureID
        systemAudioCapture = service
        systemAudioStatus = .awaitingPermission
        systemAudioLiveness = .init(activeSince: ProcessInfo.processInfo.systemUptime)
        let priorCleanupTask = systemAudioCleanupTask
        systemAudioStartTask = Task { @MainActor [weak self, service] in
            if let priorCleanupTask { await priorCleanupTask.value }
            guard let self, self.systemAudioCaptureID == captureID else {
                _ = service.stop(discard: true)
                await service.waitForTeardown()
                return
            }
            let fallback = await service.start()
            guard self.systemAudioCaptureID == captureID else {
                _ = service.stop(discard: true)
                await service.waitForTeardown()
                return
            }
            guard self.state == .recording || self.state == .paused else { return }
            if let fallback {
                self.degradeSystemAudio(fallback, captureID: captureID)
            } else {
                let transition = OptionalSystemAudioCapturePolicy.transition(
                    from: self.systemAudioStatus,
                    event: .streamStarted
                )
                guard !self.systemAudioTeardownInFlight,
                      transition.status.acceptsSystemAudio else {
                    if self.systemAudioCaptureID == captureID {
                        self.systemAudioStartTask = nil
                    }
                    return
                }
                self.systemAudioStatus = transition.status
                if transition.status == .capturing {
                    self.systemAudioLiveness = .init(
                        activeSince: ProcessInfo.processInfo.systemUptime
                    )
                }
                if self.state == .paused { service.pause() }
                DebugLog.append("recorder: optional Mac audio stream started")
            }
            if self.systemAudioCaptureID == captureID {
                self.systemAudioStartTask = nil
            }
        }
    }

    private func handleSystemAudioEvent(
        _ event: UniversalSystemAudioCaptureEvent,
        captureID: UUID
    ) {
        guard systemAudioCaptureID == captureID,
              state == .recording || state == .paused,
              !systemAudioTeardownInFlight,
              systemAudioStatus.acceptsRuntimeCallbacks else { return }
        switch event {
        case .buffer(let peak, let meaningfulSignal, let uptime):
            systemAudioPeak = peak
            systemAudioLiveness?.observeBuffer(at: uptime)
            if meaningfulSignal {
                systemAudioStatus = OptionalSystemAudioCapturePolicy.transition(
                    from: systemAudioStatus,
                    event: .meaningfulBufferCaptured
                ).status
            }
        case .failed(let reason):
            degradeSystemAudio(reason, captureID: captureID)
        }
    }

    /// An optional-source failure closes the stream immediately but retains any
    /// already-qualified sparse chunks for the final offline render.
    private func degradeSystemAudio(
        _ reason: OptionalSystemAudioFallbackReason,
        captureID: UUID
    ) {
        guard systemAudioCaptureID == captureID,
              !systemAudioTeardownInFlight,
              let service = systemAudioCapture else { return }
        systemAudioTeardownInFlight = true
        systemAudioStatus = .microphoneOnly(reason)
        systemAudioStartTask?.cancel()
        systemAudioArtifactURL = service.stop() ?? systemAudioArtifactURL
        DebugLog.append("recorder: Mac audio degraded (\(reason)); microphone continues")
    }

    /// Invalidates callbacks and detaches the SCK output synchronously, but
    /// deliberately does not await a possibly TCC-suspended startup task. The
    /// cleanup chain is awaited before a future optional capture, never by the
    /// authoritative microphone finalization.
    private func finishOptionalSystemAudioCapture(discard: Bool) -> URL? {
        let service = systemAudioCapture
        let startTask = systemAudioStartTask
        let priorCleanupTask = systemAudioCleanupTask
        systemAudioCaptureID = nil
        startTask?.cancel()

        var artifact = systemAudioArtifactURL
        if let service {
            artifact = service.stop(discard: discard) ?? artifact
        }
        if startTask != nil || service != nil {
            let cleanupID = UUID()
            systemAudioCleanupID = cleanupID
            systemAudioCleanupTask = OptionalCaptureCleanupScheduler.schedule(
                prior: priorCleanupTask,
                suspendedStart: startTask,
                cleanup: { [service] in
                    if let service {
                        _ = service.stop(discard: discard)
                        await service.waitForTeardown()
                    }
                },
                completion: { @MainActor [weak self] in
                    guard let self, self.systemAudioCleanupID == cleanupID else { return }
                    self.systemAudioCleanupTask = nil
                    self.systemAudioCleanupID = nil
                }
            )
        }

        systemAudioStartTask = nil
        systemAudioCapture = nil
        systemAudioArtifactURL = nil
        systemAudioLiveness = nil
        systemAudioTeardownInFlight = false
        if discard, let artifact {
            try? FileManager.default.removeItem(at: artifact)
            return nil
        }
        return artifact
    }

    func pause() {
        guard state == .recording else { return }
        if case .replacementTake? = sessionTarget { return }
        systemAudioCapture?.pause()
        engine?.pause()
        recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
        state = .paused
        captureHealthTask?.cancel()
        captureHealthTask = nil
        if extensionSession != nil {
            try? extensionSession?.transition(to: .paused)
            persistExtensionSession(in: entryURL)
        }
    }

    func resume() {
        guard state == .paused else { return }
        if case .replacementTake? = sessionTarget { return }
        guard !requiresStopAfterInputChange else {
            alertMessage = Self.inputChangeSaveMessage
            return
        }
        guard let engine, let baselineInputSignature else {
            logMicrophoneFailure(
                kind: .captureStalled,
                stage: .resume,
                reason: .engineStopped,
                enginePhase: .stopped,
                engineRunning: false
            )
            return
        }
        let current = Self.inputSignature(for: engine)
        guard baselineInputSignature.isCompatible(with: current) else {
            configurationChangeCount += 1
            quarantineUnstableInput(
                engine: engine,
                event: configurationChangeCount,
                current: current,
                message: Self.inputChangeSaveMessage,
                reason: "input changed before resume"
            )
            return
        }
        do {
            recordingTimeline?.beginSegment(atFrame: sink?.frameCount ?? 0)
            try engine.start()
            systemAudioCapture?.resume()
            resetSystemAudioLivenessAfterResume()
            state = .recording
            configurationChangePending = false
            beginCaptureHealthMonitoring(framesWritten: sink?.frameCount ?? 0)
            if extensionSession != nil {
                try? extensionSession?.transition(to: .capturing)
                persistExtensionSession(in: entryURL)
            }
        } catch {
            recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
            logMicrophoneFailure(
                kind: .captureStalled,
                stage: .resume,
                reason: .resumeFailed,
                resolvedSignature: current,
                enginePhase: .stopped,
                engineRunning: engine.isRunning,
                error: error
            )
            alertMessage = "Could not resume recording: \(error.localizedDescription)"
        }
    }

    private func receiveConfigurationChange() async {
        configurationChangePending = true
        guard !isHandlingConfigurationChange else { return }

        isHandlingConfigurationChange = true
        defer { isHandlingConfigurationChange = false }
        while configurationChangePending,
              state == .recording || state == .paused {
            configurationChangePending = false
            await evaluateConfigurationChange()
        }
    }

    private func evaluateConfigurationChange() async {
        guard state == .recording || state == .paused,
              let engine,
              let baselineInputSignature else { return }

        configurationChangeCount += 1
        let event = configurationChangeCount
        let current = Self.inputSignature(for: engine)
        let wasRunning = engine.isRunning
        let uptime = ProcessInfo.processInfo.systemUptime
        let sinceStart = recordingStartUptime.map { uptime - $0 } ?? 0
        let decision = RecordingConfigurationDecision.classify(
            baseline: baselineInputSignature,
            current: current,
            engineIsRunning: wasRunning
        )
        DebugLog.append(
            "recorder: config_change #\(event) +\(String(format: "%.3f", sinceStart))s "
                + "baseline={\(Self.describe(baselineInputSignature))} "
                + "current={\(Self.describe(current))} engine_running=\(wasRunning) "
                + "decision=\(String(describing: decision))"
        )

        // A manually paused engine is expected not to be running. Do not
        // restart it for a benign graph notification, but quarantine it if the
        // input changed while capture was paused.
        if state == .paused {
            if baselineInputSignature.isCompatible(with: current) {
                configurationChangeCircuitBreaker.reset()
                DebugLog.append(
                    "recorder: config_change #\(event) compatible while manually paused; ignored"
                )
            } else {
                quarantineUnstableInput(
                    engine: engine,
                    event: event,
                    current: current,
                    message: Self.inputChangeSaveMessage,
                    reason: "input changed while paused"
                )
            }
            return
        }

        // Compatible notifications while the engine remains live are common
        // during route settling and do not represent failed recovery. Counting
        // them let three benign notifications quarantine an otherwise healthy
        // microphone graph.
        if decision == .keepRunning {
            configurationChangeCircuitBreaker.reset()
            return
        }
        let circuitBreakerTripped =
            configurationChangeCircuitBreaker.registerChange(at: uptime)

        if circuitBreakerTripped {
            quarantineUnstableInput(
                engine: engine,
                event: event,
                current: current,
                message: Self.repeatedInputChangeSaveMessage,
                reason: "rapid configuration-change circuit breaker"
            )
            return
        }

        switch decision {
        case .keepRunning:
            return // handled above
        case .restartEngine:
            await restartEngineAfterBenignConfigurationChange(
                engine,
                baseline: baselineInputSignature,
                event: event
            )
        case .pauseForInputChange:
            quarantineUnstableInput(
                engine: engine,
                event: event,
                current: current,
                message: Self.inputChangeSaveMessage,
                reason: "input changed"
            )
        }
    }

    /// AVAudioEngine can stop while CoreAudio rebuilds a graph even though
    /// the microphone itself did not change. The existing input tap stays
    /// installed, so preparing and starting the same engine preserves the
    /// single RecordingSink and liveTee ordering without duplicating buffers.
    private func restartEngineAfterBenignConfigurationChange(
        _ engine: AVAudioEngine,
        baseline: RecordingInputSignature,
        event: Int
    ) async {
        systemAudioCapture?.pause()
        engine.pause()
        recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
        let retryDelays: [UInt64] = [0, 50_000_000, 150_000_000, 300_000_000]
        var lastError: Error?

        for delay in retryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard state == .recording, self.engine === engine else { return }

            let current = Self.inputSignature(for: engine)
            guard baseline.isCompatible(with: current) else {
                quarantineUnstableInput(
                    engine: engine,
                    event: event,
                    current: current,
                    message: Self.inputChangeSaveMessage,
                    reason: "input changed during engine restart"
                )
                return
            }
            if engine.isRunning {
                recordingTimeline?.beginSegment(atFrame: sink?.frameCount ?? 0)
                systemAudioCapture?.resume()
                resetSystemAudioLivenessAfterResume()
                DebugLog.append(
                    "recorder: config_change #\(event) recovered before restart "
                        + "input={\(Self.describe(current))}"
                )
                return
            }

            do {
                recordingTimeline?.beginSegment(atFrame: sink?.frameCount ?? 0)
                engine.prepare()
                try engine.start()
                systemAudioCapture?.resume()
                resetSystemAudioLivenessAfterResume()
                DebugLog.append(
                    "recorder: config_change #\(event) restarted engine "
                        + "input={\(Self.describe(current))}"
                )
                return
            } catch {
                recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
                lastError = error
                logMicrophoneFailure(
                    kind: .captureStalled,
                    stage: .activeCapture,
                    reason: .engineStartFailed,
                    resolvedSignature: current,
                    enginePhase: .stopped,
                    engineRunning: engine.isRunning,
                    error: error
                )
                DebugLog.append(
                    "recorder: config_change #\(event) restart attempt failed: \(error)"
                )
            }
        }

        guard state == .recording, self.engine === engine else { return }
        let detail = lastError?.localizedDescription ?? "CoreAudio did not restart the engine."
        quarantineUnstableInput(
            engine: engine,
            event: event,
            current: Self.inputSignature(for: engine),
            message: """
            Recording paused because the microphone connection could not recover. \
            Audio captured so far is safe. Stop & Save this recording, then start \
            a new recording after the microphone stabilizes. \(detail)
            """,
            reason: "engine recovery exhausted"
        )
    }

    private static let inputChangeSaveMessage = """
        The audio input changed or disappeared. Audio captured so far is safe. \
        Stop & Save this recording, then start a new recording after choosing \
        a stable microphone.
        """

    private static let repeatedInputChangeSaveMessage = """
        Recording paused because the microphone connection changed repeatedly. \
        Audio captured so far is safe. Stop & Save this recording, wait for the \
        headset to stabilize, then start a new recording.
        """

    /// Severs the active Core Audio graph while leaving the crash-safe CAF and
    /// RecordingSink open for normal Stop & Save finalization. This prevents a
    /// multipoint headset from driving an unbounded stop/restart loop.
    private func quarantineUnstableInput(
        engine: AVAudioEngine,
        event: Int,
        current: RecordingInputSignature,
        message: String,
        reason: String
    ) {
        guard state == .recording || state == .paused else { return }
        removeConfigurationChangeObserver()
        configurationChangePending = false
        systemAudioCapture?.pause()
        engine.stop()
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
        state = .paused
        requiresStopAfterInputChange = true
        if extensionSession != nil {
            try? extensionSession?.transition(to: .paused)
            persistExtensionSession(in: entryURL)
        }
        alertMessage = message
        logMicrophoneFailure(
            kind: .captureStalled,
            stage: .activeCapture,
            reason: .inputChanged,
            resolvedSignature: current,
            enginePhase: .stopped,
            engineRunning: engine.isRunning,
            tapInstalled: false
        )
        DebugLog.append(
            "recorder: config_change #\(event) quarantined graph (\(reason)) "
                + "current={\(Self.describe(current))}"
        )
    }

    private func removeConfigurationChangeObserver() {
        guard let configChangeObserver else { return }
        NotificationCenter.default.removeObserver(configChangeObserver)
        self.configChangeObserver = nil
    }

    private static func inputSignature(for engine: AVAudioEngine) -> RecordingInputSignature {
        let input = engine.inputNode
        let deviceID = AudioInputDevices.currentInputDeviceID(for: input.audioUnit)
        return inputSignature(forDeviceID: deviceID)
    }

    /// Reads identity, availability, channels, and nominal rate from one
    /// physical Core Audio device. Combining AudioUnit's current device ID with
    /// `inputNode.outputFormat` produced hybrid signatures during route churn
    /// (for example device 78 paired with the default aggregate's 44.1 kHz).
    private static func inputSignature(
        forDeviceID deviceID: AudioDeviceID?
    ) -> RecordingInputSignature {
        return RecordingInputSignature(
            deviceID: deviceID,
            sampleRate: deviceID.flatMap(AudioInputDevices.nominalSampleRate) ?? 0,
            channelCount: UInt32(deviceID.map(AudioInputDevices.inputChannelCount) ?? 0),
            deviceIsAvailable: deviceID.map(AudioInputDevices.isUsableInputDevice) ?? false
        )
    }

    private static func describe(_ signature: RecordingInputSignature) -> String {
        let device = signature.deviceID.map(String.init) ?? "nil"
        return "device=\(device),rate=\(String(format: "%.1f", signature.sampleRate)),"
            + "channels=\(signature.channelCount),available=\(signature.deviceIsAvailable)"
    }

    private func applySinkUpdate(
        sinkID: UUID,
        elapsed: Double,
        peaksTail: [Float],
        error: Error?,
        inputFormatChanged: Bool,
        framesWritten: Int64,
        bufferPeak: Float
    ) {
        // Rejected attempts may already have queued MainActor work when their
        // graph is torn down. Only the sink accepted at the activation barrier
        // is allowed to mutate live state or quarantine the current engine.
        guard activeSinkID == sinkID else { return }
        guard state == .recording || state == .paused else { return }
        self.elapsed = elapsed
        livePeaks = peaksTail
        if state == .recording {
            captureHealthMonitor?.observe(
                framesWritten: framesWritten,
                bufferPeak: bufferPeak,
                at: ProcessInfo.processInfo.systemUptime
            )
            updateCaptureHealth()
        }
        if inputFormatChanged,
           !requiresStopAfterInputChange,
           let engine {
            configurationChangeCount += 1
            quarantineUnstableInput(
                engine: engine,
                event: configurationChangeCount,
                current: Self.inputSignature(for: engine),
                message: Self.inputChangeSaveMessage,
                reason: "tap delivered an incompatible input format"
            )
            return
        }
        if case .replacementTake(let target)? = sessionTarget,
           elapsed >= target.region.duration,
           !replacementBoundaryRequested {
            replacementBoundaryRequested = true
            onReplacementBoundaryReached?()
        }
        if let error, !reportedSinkError {
            reportedSinkError = true
            logMicrophoneFailure(
                kind: .captureStalled,
                stage: .activeCapture,
                reason: .sinkWriteFailed,
                error: error
            )
            pause()
            alertMessage = "Recording paused — audio could not be written: \(error.localizedDescription)"
        }
    }

    private func beginCaptureHealthMonitoring(framesWritten: Int64) {
        captureHealthTask?.cancel()
        let uptime = ProcessInfo.processInfo.systemUptime
        captureHealthMonitor = RecordingCaptureHealthMonitor(
            startedAt: uptime,
            framesWritten: framesWritten
        )
        captureHealth = .awaitingFirstBuffer
        captureHealthMessage = nil
        captureHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.updateCaptureHealth()
            }
        }
    }

    private func updateCaptureHealth() {
        guard state == .recording, let captureHealthMonitor else { return }
        let newState = captureHealthMonitor.state(
            at: ProcessInfo.processInfo.systemUptime
        )
        let stateChanged = newState != captureHealth
        captureHealth = newState
        captureHealthMessage = switch newState {
        case .noBuffers:
            "No audio is arriving from the selected microphone. Stop and try another input."
        case .noSignal:
            "No microphone signal is detected. Check that the selected input is connected and unmuted."
        case .stalled:
            "Audio stopped arriving from the selected microphone. Stop and save what was captured."
        case .inactive, .awaitingFirstBuffer, .healthy:
            nil
        }
        if systemAudioStatus.acceptsSystemAudio,
           let systemAudioLiveness {
            let uptime = ProcessInfo.processInfo.systemUptime
            if systemAudioLiveness.isStalled(at: uptime, grace: 4),
               let captureID = systemAudioCaptureID {
                degradeSystemAudio(.stalled, captureID: captureID)
            }
        }
        if stateChanged, let captureHealthMessage {
            DebugLog.append("recorder: capture health \(String(describing: newState)): \(captureHealthMessage)")
            switch newState {
            case .noBuffers:
                logMicrophoneFailure(
                    kind: .noAudioAfterStart,
                    stage: .firstBuffer,
                    reason: .noBuffers
                )
            case .noSignal:
                logMicrophoneFailure(
                    kind: .noAudioAfterStart,
                    stage: .activeCapture,
                    reason: .perfectlySilent
                )
            case .stalled:
                logMicrophoneFailure(
                    kind: .captureStalled,
                    stage: .activeCapture,
                    reason: .captureStalled
                )
            case .inactive, .awaitingFirstBuffer, .healthy:
                break
            }
        }
    }

    /// Emits the definitive microphone-only result before optional Mac audio
    /// can promote the aggregate capture to `.captured` and hide a dead mic.
    private func logTerminalMicrophoneFailure(
        _ result: RecordingSink.Result,
        stage: MicrophoneFailureEvent.Stage
    ) {
        if let error = result.error {
            logMicrophoneFailure(
                kind: .captureStalled,
                stage: stage,
                reason: .sinkWriteFailed,
                frames: result.frames,
                error: error
            )
        }
        switch MicrophoneTerminalCaptureState.classify(
            frames: result.frames,
            hasSignal: result.hasSignal
        ) {
        case .noFrames:
            logMicrophoneFailure(
                kind: .noAudioAfterStart,
                stage: stage,
                reason: .noFrames,
                frames: 0
            )
        case .perfectlySilent:
            logMicrophoneFailure(
                kind: .perfectlySilentClip,
                stage: stage,
                reason: .perfectlySilent,
                frames: result.frames,
                elapsedSeconds: Double(result.frames) / sampleRate
            )
        case .signal:
            break
        }
    }

    private func resetSystemAudioLivenessAfterResume() {
        guard systemAudioStatus.acceptsSystemAudio else { return }
        systemAudioLiveness?.beginActivePeriod(at: ProcessInfo.processInfo.systemUptime)
    }

    private func stopCaptureHealthMonitoring() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        captureHealthMonitor = nil
    }

    // MARK: - Stop / finalize

    /// Stops and finalizes the recording. Returns the entry's vault-relative
    /// path on success (also on partial success — the alert says what failed).
    func stop() async -> FinalizationOutcome? {
        guard state == .recording || state == .paused,
              let sink, let entryURL, let sessionTarget else { return nil }
        state = .finalizing
        stopCaptureHealthMonitoring()
        if extensionSession != nil {
            try? extensionSession?.transition(to: .finalizingSegment)
            persistExtensionSession(in: entryURL)
        }
        removeConfigurationChangeObserver()
        configurationChangePending = false

        systemAudioCapture?.pause()
        if inputTapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine?.stop()
        recordingTimeline?.endSegment(atFrame: sink.frameCount)
        let result = sink.finish()
        logTerminalMicrophoneFailure(result, stage: .finalization)
        let systemArtifact = finishOptionalSystemAudioCapture(discard: false)
        self.engine = nil
        self.sink = nil
        activeSinkID = nil
        recordingTimeline = nil
        self.entryURL = nil
        baselineInputSignature = nil
        recordingStartUptime = nil

        let relPath = currentEntryPath
        let duration = Double(result.frames) / sampleRate
        var captureResult = Self.classifyCaptureResult(
            frames: result.frames,
            microphoneHasSignal: result.hasSignal,
            firstMeaningfulSystemFrame: nil
        )
        var extensionSegmentURL: URL?
        var replacementTake: ReplacementTake?
        var replacementTakeURL: URL?
        var canonicalAudioInstalled = false
        var finalizationSucceeded = false
        let microphoneJournalURL = entryURL.appending(path: Self.partialFileName)
        var finalJournalURL = microphoneJournalURL
        var finalPeaks = result.peaks
        if case .newEntry = sessionTarget {
            let stagedURL = entryURL.appending(
                path: UniversalRecordingArtifacts.mixedJournalFileName
            )
            if let systemArtifact, result.frames > 0 {
                let selection = await Task.detached {
                    UniversalRecordingFileResolver.renderOrUseMicrophone(
                        microphoneURL: microphoneJournalURL,
                        microphoneFrames: result.frames,
                        microphonePeaks: result.peaks,
                        systemJournalURL: systemArtifact,
                        stagedURL: stagedURL
                    )
                }.value
                finalJournalURL = selection.journalURL
                finalPeaks = selection.peaks
                if let fallback = selection.fallbackReason {
                    systemAudioStatus = .microphoneOnly(fallback)
                    DebugLog.append(
                        "recorder: optional Mac audio mix failed; preserving microphone"
                    )
                } else {
                    let degradedDuringCapture = systemAudioStatus
                    systemAudioStatus = Self.systemAudioStatusAfterSuccessfulMix(
                        systemAudioStatus
                    )
                    captureResult = Self.classifyCaptureResult(
                        frames: result.frames,
                        microphoneHasSignal: result.hasSignal,
                        firstMeaningfulSystemFrame: selection.firstSystemFrame
                    )
                    DebugLog.append(
                        "recorder: mixed Mac audio from canonical frame "
                            + "\(selection.firstSystemFrame ?? 0)"
                    )
                    if case .microphoneOnly(let reason) = degradedDuringCapture {
                        DebugLog.append(
                            "recorder: mixed Mac audio is partial; capture had "
                                + "already degraded (\(reason))"
                        )
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: stagedURL)
                if systemAudioStatus.acceptsSystemAudio {
                    systemAudioStatus = .microphoneOnly(.noMeaningfulAudio)
                } else {
                    switch systemAudioStatus {
                    case .notRequested, .awaitingPermission, .starting:
                        systemAudioStatus = .microphoneOnly(.startFailed)
                    default:
                        break
                    }
                }
            }
        } else if let systemArtifact {
            // Edit workflows are intentionally microphone-only.
            try? FileManager.default.removeItem(at: systemArtifact)
        }
        do {
            guard result.frames > 0 else { throw RecorderError.noAudioCaptured }
            switch sessionTarget {
            case .newEntry:
                try await Self.finalize(
                    entryURL: entryURL,
                    created: entryCreated,
                    frames: result.frames,
                    duration: duration,
                    peaks: finalPeaks,
                    quality: recordingQuality,
                    journalURL: finalJournalURL,
                    microphoneJournalURL: microphoneJournalURL
                )
                canonicalAudioInstalled = true
                finalizationSucceeded = true
            case .extensionOf:
                guard captureResult == .captured else {
                    throw RecorderError.noAudioSignal
                }
                extensionSegmentURL = try await Self.finalizeExtensionSegment(
                    entryURL: entryURL,
                    frames: result.frames,
                    duration: duration,
                    quality: recordingQuality
                )
                extensionSession?.segmentDuration = duration
                try extensionSession?.transition(to: .segmentReady)
                persistExtensionSession(in: entryURL)
                finalizationSucceeded = true
            case .replacementTake(let target):
                guard captureResult == .captured else {
                    throw RecorderError.noAudioSignal
                }
                let finalized = try await Self.finalizeReplacementTake(
                    entryURL: entryURL,
                    target: target,
                    capturedFrames: Int64(result.frames),
                    quality: recordingQuality
                )
                replacementTake = finalized.take
                replacementTakeURL = finalized.url
                finalizationSucceeded = true
            }
            if requiresStopAfterInputChange, captureResult == .captured {
                alertMessage = nil
            }
            if captureResult == .noSignal {
                alertMessage = "The recording was retained, but no audio signal was detected. It was not queued for transcription."
            }
            if let writeError = result.error {
                alertMessage = """
                The recording was saved, but part of the audio could not be written: \
                \(writeError.localizedDescription)
                """
            }
        } catch RecorderError.noAudioCaptured {
            let partialName = switch sessionTarget {
            case .newEntry: Self.partialFileName
            case .extensionOf: RecordingExtensionArtifacts.partialFileName
            case .replacementTake: AudioReplacementArtifacts.partialFileName
            }
            try? FileManager.default.removeItem(at: entryURL.appending(path: partialName))
            alertMessage = RecorderError.noAudioCaptured.localizedDescription
            finalizationSucceeded = true
        } catch RecorderError.noAudioSignal {
            let partialName = switch sessionTarget {
            case .newEntry: Self.partialFileName
            case .extensionOf: RecordingExtensionArtifacts.partialFileName
            case .replacementTake: AudioReplacementArtifacts.partialFileName
            }
            try? FileManager.default.removeItem(at: entryURL.appending(path: partialName))
            alertMessage = RecorderError.noAudioSignal.localizedDescription
            finalizationSucceeded = true
        } catch RecordingExtensionError.segmentTooShort {
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: RecordingExtensionArtifacts.partialFileName)
            )
            alertMessage = "The extension was too short to append. The existing recording was not changed."
            finalizationSucceeded = true
        } catch {
            extensionSession?.fail(error.localizedDescription)
            persistExtensionSession(in: entryURL)
            alertMessage = "The recording could not be finalized: \(error.localizedDescription)"
        }
        configurationChangeCircuitBreaker.reset()
        requiresStopAfterInputChange = false

        if case .extensionOf = sessionTarget {
            retainedExtensionEntryURL = entryURL
        } else {
            state = .idle
            currentEntryPath = nil
            self.sessionTarget = nil
            elapsed = 0
            livePeaks = []
            captureHealth = .inactive
            systemAudioPeak = 0
        }
        DebugLog.append(
            "recorder: stopped [\(relPath ?? "?")] duration=\(duration) "
                + "capture_result=\(String(describing: captureResult))"
        )
        clearMicrophoneFailureContext()
        guard let relPath else { return nil }
        return FinalizationOutcome(
            entryRelativePath: relPath,
            target: sessionTarget,
            duration: duration,
            captureResult: captureResult,
            canonicalAudioInstalled: canonicalAudioInstalled,
            finalizationSucceeded: finalizationSucceeded,
            systemAudioStatus: systemAudioStatus,
            extensionSegmentURL: extensionSegmentURL,
            replacementTake: replacementTake,
            replacementTakeURL: replacementTakeURL
        )
    }

    /// Abandons an in-progress replacement attempt without promoting the
    /// partial journal to a take. Replacement capture is temporary until the
    /// user explicitly bakes, so Cancel must have a true discard path rather
    /// than going through normal recording finalization.
    func cancelReplacementCapture() async {
        guard case .replacementTake? = sessionTarget,
              state == .recording || state == .paused else { return }
        _ = await cancelActiveCapture()
    }

    /// Quiesces every live capture resource while deliberately retaining the
    /// authoritative microphone journal and edit-session metadata for startup
    /// recovery. Used only after the user chooses Quit and Recover Later.
    func preserveActiveCaptureForRecovery() async {
        guard state == .recording || state == .paused else { return }
        state = .finalizing
        removeConfigurationChangeObserver()
        stopCaptureHealthMonitoring()
        configurationChangePending = false
        systemAudioCapture?.pause()
        if let engine {
            if inputTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            engine.stop()
        }
        recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
        if let result = sink?.finish() {
            logTerminalMicrophoneFailure(result, stage: .recoveryPreservation)
        }
        // Recovery is intentionally microphone-only. The sparse companion is
        // not a canonical file and must not survive as an ambiguous artifact.
        _ = finishOptionalSystemAudioCapture(discard: true)
        engine = nil
        sink = nil
        activeSinkID = nil
        recordingTimeline = nil
        entryURL = nil
        baselineInputSignature = nil
        recordingStartUptime = nil
        clearMicrophoneFailureContext()
        DebugLog.append("recorder: live resources closed; microphone journal retained for recovery")
    }

    /// Stops a live capture without finalizing or promoting its journal.
    /// The caller owns any higher-level cleanup, such as removing the empty
    /// folder created for a brand-new recording or restoring playback for an
    /// existing entry.
    func cancelActiveCapture() async -> (target: SessionTarget, entryRelativePath: RelativePath)? {
        guard state == .recording || state == .paused,
              let target = sessionTarget,
              let entryRelativePath = currentEntryPath else { return nil }
        // MainActor methods are reentrant across the awaited ScreenCaptureKit
        // shutdown below. Close the active-state gate first so a simultaneous
        // menu/shortcut Stop cannot finalize the sink while cancellation is
        // about to discard the same journal, and a new Start cannot overlap the
        // old stream's output removal.
        state = .finalizing
        removeConfigurationChangeObserver()
        stopCaptureHealthMonitoring()
        systemAudioCapture?.pause()
        if let engine {
            if inputTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            engine.stop()
        }
        recordingTimeline?.endSegment(atFrame: sink?.frameCount ?? 0)
        if let result = sink?.finish() {
            logTerminalMicrophoneFailure(result, stage: .cancellation)
        }
        _ = finishOptionalSystemAudioCapture(discard: true)
        if let entryURL {
            let partialFileName = switch target {
            case .newEntry: Self.partialFileName
            case .extensionOf: RecordingExtensionArtifacts.partialFileName
            case .replacementTake: AudioReplacementArtifacts.partialFileName
            }
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: partialFileName)
            )
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: UniversalRecordingArtifacts.mixedJournalFileName)
            )
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: UniversalRecordingArtifacts.systemAudioFileName)
            )
            if case .extensionOf = target {
                try? FileManager.default.removeItem(
                    at: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
                )
            }
        }
        engine = nil
        sink = nil
        activeSinkID = nil
        recordingTimeline = nil
        entryURL = nil
        retainedExtensionEntryURL = nil
        extensionSession = nil
        baselineInputSignature = nil
        recordingStartUptime = nil
        configurationChangePending = false
        configurationChangeCircuitBreaker.reset()
        requiresStopAfterInputChange = false
        currentEntryPath = nil
        sessionTarget = nil
        elapsed = 0
        livePeaks = []
        captureHealth = .inactive
        captureHealthMessage = nil
        systemAudioStatus = .notRequested
        systemAudioPeak = 0
        replacementBoundaryRequested = false
        onReplacementBoundaryReached = nil
        clearMicrophoneFailureContext()
        state = .idle
        return (target, entryRelativePath)
    }

    /// Finishes the app-wide operation after composition either succeeds or
    /// leaves the finalized segment available for retry/recovery.
    func completeExtensionWorkflow(error: Error? = nil) {
        guard extensionSession != nil else { return }
        if let error {
            extensionSession?.fail(error.localizedDescription)
            persistExtensionSession(in: retainedExtensionEntryURL)
            alertMessage = "The extension was saved but could not be appended: \(error.localizedDescription)"
        } else if let entryURL = retainedExtensionEntryURL {
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
            )
            extensionSession = nil
        }
        state = .idle
        currentEntryPath = nil
        sessionTarget = nil
        elapsed = 0
        livePeaks = []
        captureHealth = .inactive
        captureHealthMessage = nil
        retainedExtensionEntryURL = nil
    }

    private func persistExtensionSession(in entryURL: URL?) {
        guard let entryURL, let extensionSession else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(extensionSession) {
            try? AtomicFile.write(
                data,
                to: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
            )
        }
    }

    /// This write is part of the extension startup transaction and therefore
    /// cannot be best-effort: the manifest must exist before any canonical CAF
    /// frames can be written, or a crash would leave an unclassifiable artifact.
    private func persistProvisionalExtensionSession(
        _ session: RecordingExtensionSession,
        in entryURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            try encoder.encode(session),
            to: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
        )
    }

    /// Remux CAF → `audio.m4a` (passthrough, no re-encode), write
    /// `waveform.json` from the live-accumulated peaks, write the stub
    /// transcript. Falls back to keeping the audio as `audio.caf` if the
    /// remux fails — the vault accepts any audio extension.
    nonisolated static func finalize(
        entryURL: URL,
        created: Date,
        frames: Int64,
        duration: Double,
        peaks: [Float],
        quality: RecordingQuality,
        journalURL: URL,
        microphoneJournalURL: URL,
        /// Internal deterministic fault boundary used by integration tests.
        /// Production callers leave this nil. It deliberately runs only after
        /// visible audio is installed and outside the encode-fallback scope.
        afterVisibleAudioInstalled: (@Sendable (URL) throws -> Void)? = nil,
        /// Internal deterministic crash boundary for the lossless fallback,
        /// between the staged copy and its atomic promotion. Production callers
        /// leave this nil.
        afterStagedCAFCopied: (@Sendable (URL) throws -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        let m4aURL = entryURL.appending(path: "audio.m4a")
        let stagedM4AURL = entryURL.appending(
            path: UniversalRecordingArtifacts.stagedCanonicalAudioFileName
        )
        let cafURL = entryURL.appending(path: "audio.caf")
        let stagedCAFURL = entryURL.appending(
            path: UniversalRecordingArtifacts.stagedCanonicalCAFFileName
        )

        var encodingError: Error?
        do {
            try await Task.detached {
                try CrashTolerantAudioJournal.encodeM4A(
                    from: journalURL,
                    to: stagedM4AURL,
                    encoding: quality.outputEncoding
                )
                let validation = try AVAudioFile(forReading: stagedM4AURL)
                defer { validation.close() }
                guard Int64(validation.length) == frames,
                      validation.processingFormat.channelCount == 1,
                      abs(validation.processingFormat.sampleRate - 44_100) < 0.5 else {
                    throw RecorderError.formatUnsupported
                }
            }.value
        } catch {
            encodingError = error
        }

        let visibleAudioURL: URL
        if let encodingError {
            // The source may be the mixed journal, but `.recording.caf` is the
            // recovery marker and microphone master. Copying keeps both hidden
            // journals authoritative until visible audio and metadata are safe.
            //
            // The copy lands on a hidden staging name first: a crash mid-copy
            // would otherwise leave a truncated-but-readable `audio.caf` that
            // startup recovery adopts before deleting the intact journal. Only
            // the same-directory rename below publishes canonical audio.
            try Self.removeIfPresent(stagedCAFURL, using: fm)
            try fm.copyItem(at: journalURL, to: stagedCAFURL)
            try afterStagedCAFCopied?(stagedCAFURL)
            try Self.removeIfPresent(cafURL, using: fm)
            try fm.moveItem(at: stagedCAFURL, to: cafURL)
            visibleAudioURL = cafURL
            DebugLog.append(
                "recorder: encode to m4a failed (copied PCM audio.caf): \(encodingError)"
            )
        } else {
            try Self.removeIfPresent(m4aURL, using: fm)
            try fm.moveItem(at: stagedM4AURL, to: m4aURL)
            visibleAudioURL = m4aURL
        }

        // Once visible audio exists, every failure must leave the microphone
        // journal discoverable. In particular, this hook and the metadata
        // writes are outside the encode catch so they cannot trigger CAF
        // fallback or retire the recovery marker.
        try afterVisibleAudioInstalled?(visibleAudioURL)
        try WaveformData(duration: duration, peaks: peaks)
            .write(to: WaveformData.url(inEntry: entryURL))
        try EntryCreator.writeRecordingStub(entryURL: entryURL, created: created, duration: duration)

        try Self.cleanupFinalizationJournals(
            journalURL: journalURL,
            microphoneJournalURL: microphoneJournalURL,
            stagedM4AURL: stagedM4AURL
        ) { url in
            try Self.removeIfPresent(url, using: fm)
        }
    }

    /// A stall, invalid timing, or a sidecar-write failure stops the optional
    /// stream but deliberately keeps the chunks already qualified before it, so
    /// the offline render still succeeds. Its success proves only that the
    /// retained prefix was mixed — not that Mac audio was captured for the
    /// whole recording. Promoting such a session to `.captured` would claim
    /// exactly that, so a degradation reached during capture is preserved.
    nonisolated static func systemAudioStatusAfterSuccessfulMix(
        _ status: OptionalSystemAudioCaptureStatus
    ) -> OptionalSystemAudioCaptureStatus {
        if case .microphoneOnly = status { return status }
        return .captured
    }

    /// Removes derived finalization files first and the microphone recovery
    /// marker last. The throwing closure is intentionally injectable so the
    /// failure ordering is deterministic under integration test. If any
    /// derived deletion fails, `.recording.caf` is never attempted.
    nonisolated static func cleanupFinalizationJournals(
        journalURL: URL,
        microphoneJournalURL: URL,
        stagedM4AURL: URL,
        removeItem: (URL) throws -> Void
    ) throws {
        let microphonePath = microphoneJournalURL.standardizedFileURL.path
        var seenPaths: Set<String> = []
        for url in [stagedM4AURL, journalURL] {
            let path = url.standardizedFileURL.path
            guard path != microphonePath, seenPaths.insert(path).inserted else { continue }
            try removeItem(url)
        }
        try removeItem(microphoneJournalURL)
    }

    private nonisolated static func removeIfPresent(
        _ url: URL, using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A simultaneous idempotent recovery/cleanup may have won.
        }
    }

    /// Finalizes only the newly captured tail. It deliberately does not write
    /// entry metadata, waveform, or transcript; the visible entry is untouched
    /// until composition validates and the safe swap succeeds.
    nonisolated static func finalizeExtensionSegment(
        entryURL: URL,
        frames: Int64,
        duration: Double,
        quality: RecordingQuality,
        /// Internal deterministic promotion-failure boundary. Production
        /// callers leave this nil.
        afterStagedM4AValidated: (@Sendable (URL) throws -> Void)? = nil,
        /// Internal deterministic crash boundary for the lossless fallback,
        /// between the staged copy and its atomic promotion. Production callers
        /// leave this nil.
        afterStagedCAFCopied: (@Sendable (URL) throws -> Void)? = nil
    ) async throws -> URL {
        guard duration >= AudioExtensionComposer.minimumSegmentDuration else {
            throw RecordingExtensionError.segmentTooShort
        }
        let fm = FileManager.default
        let partialURL = entryURL.appending(path: RecordingExtensionArtifacts.partialFileName)
        let stagedM4AURL = entryURL.appending(
            path: RecordingExtensionArtifacts.stagedSegmentM4AFileName
        )
        let m4aURL = entryURL.appending(path: RecordingExtensionArtifacts.segmentM4AFileName)
        let cafURL = entryURL.appending(path: RecordingExtensionArtifacts.segmentCAFFileName)
        let stagedCAFURL = entryURL.appending(
            path: RecordingExtensionArtifacts.stagedSegmentCAFFileName
        )

        var m4aFailure: Error?
        do {
            try await Task.detached {
                try CrashTolerantAudioJournal.encodeM4A(
                    from: partialURL,
                    to: stagedM4AURL,
                    encoding: quality.outputEncoding
                )
                try Self.validateFinalizedExtensionSegment(
                    stagedM4AURL, expectedFrames: frames
                )
            }.value
            try afterStagedM4AValidated?(stagedM4AURL)
            try Self.removeIfPresent(m4aURL, using: fm)
            // Both paths live beside one another, so this rename is the atomic
            // commit point. The authoritative CAF remains untouched until it
            // has succeeded and the final name is independently readable.
            try fm.moveItem(at: stagedM4AURL, to: m4aURL)
            try Self.validateFinalizedExtensionSegment(
                m4aURL, expectedFrames: frames
            )
        } catch {
            m4aFailure = error
        }

        if let m4aFailure {
            do {
                // Neither a partial encode nor a failed promotion is a usable
                // extension segment. Clear both before installing the known-
                // valid PCM journal under its committed fallback name.
                try Self.removeIfPresent(stagedM4AURL, using: fm)
                try Self.removeIfPresent(m4aURL, using: fm)
                try Self.removeIfPresent(stagedCAFURL, using: fm)
                // Copy instead of move: a failed copy or validation must leave
                // `.extension-recording.caf` discoverable for recovery. The
                // copy lands on a hidden staging name because a crash mid-copy
                // would otherwise leave a truncated file under the committed
                // candidate name, where recovery would prefer it over the
                // intact journal it came from.
                try fm.copyItem(at: partialURL, to: stagedCAFURL)
                try afterStagedCAFCopied?(stagedCAFURL)
                try Self.validateFinalizedExtensionSegment(
                    stagedCAFURL, expectedFrames: frames
                )
                try Self.removeIfPresent(cafURL, using: fm)
                try fm.moveItem(at: stagedCAFURL, to: cafURL)
            } catch {
                // Best effort prevents an invalid committed-looking candidate;
                // the authoritative partial is deliberately never removed.
                try? fm.removeItem(at: stagedCAFURL)
                try? fm.removeItem(at: cafURL)
                throw error
            }
            DebugLog.append(
                "extension segment M4A promotion failed (copied CAF): \(m4aFailure)"
            )
            try Self.removeIfPresent(partialURL, using: fm)
            return cafURL
        }

        // A pre-existing fallback is not authoritative once a validated M4A
        // has committed. Any cleanup failure occurs before the partial marker,
        // so extension recovery can finish the transaction idempotently.
        try Self.removeIfPresent(stagedCAFURL, using: fm)
        try Self.removeIfPresent(cafURL, using: fm)
        try Self.removeIfPresent(partialURL, using: fm)
        return m4aURL
    }

    private nonisolated static func validateFinalizedExtensionSegment(
        _ url: URL, expectedFrames: Int64
    ) throws {
        let validation = try AVAudioFile(forReading: url)
        defer { validation.close() }
        guard expectedFrames > 0,
              Int64(validation.length) == expectedFrames,
              validation.processingFormat.channelCount == 1,
              abs(validation.processingFormat.sampleRate - 44_100) < 0.5 else {
            throw RecorderError.formatUnsupported
        }
    }

    private nonisolated static func finalizeReplacementTake(
        entryURL: URL,
        target: ReplacementRecordingTarget,
        capturedFrames: Int64,
        quality: RecordingQuality
    ) async throws -> (take: ReplacementTake, url: URL) {
        let fm = FileManager.default
        let partialURL = entryURL.appending(path: AudioReplacementArtifacts.partialFileName)
        let sessionDirectory = entryURL.appending(
            path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory
        )
        try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let takeID = UUID()
        let takeName = AudioReplacementArtifacts.takeFileName(id: takeID)
        let outputURL = sessionDirectory.appending(path: takeName)
        let exactCAF = sessionDirectory.appending(path: ".exact-\(takeID.uuidString).caf")

        let input = try AVAudioFile(forReading: partialURL)
        let eligibleFrames = min(Int64(input.length), target.region.frameCount)
        let output = try AVAudioFile(
            forWriting: exactCAF,
            settings: input.fileFormat.settings,
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved
        )
        var remaining = AVAudioFramePosition(eligibleFrames)
        while remaining > 0 {
            let capacity = AVAudioFrameCount(min(remaining, 4096))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat, frameCapacity: capacity
            ) else { throw RecorderError.formatUnsupported }
            try input.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        try await Task.detached {
            try CrashTolerantAudioJournal.encodeM4A(
                from: exactCAF, to: outputURL, encoding: quality.outputEncoding
            )
        }.value
        try? fm.removeItem(at: exactCAF)
        try? fm.removeItem(at: partialURL)

        let status: ReplacementTakeStatus = ReplacementTakeEligibility.classify(
            capturedFrames: capturedFrames,
            capturedSampleRate: target.region.sampleRate,
            for: target.region
        ) == .eligible || capturedFrames >= target.region.frameCount ? .complete : .incomplete
        let take = ReplacementTake(
            id: takeID,
            number: target.takeNumber,
            fileName: takeName,
            capturedFrames: eligibleFrames,
            sampleRate: target.region.sampleRate,
            createdAt: .now,
            status: status
        )
        return (take, outputURL)
    }
}

enum RecorderError: LocalizedError, Equatable {
    case recordingAlreadyActive
    case recordingContextChanged
    case noInputDevice
    case selectedInputUnavailable
    case selectedInputMismatch
    case formatUnsupported
    case exportUnavailable
    case noAudioCaptured
    case noAudioSignal

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            return "Another recording is already active or still starting."
        case .recordingContextChanged:
            return "The active vault changed while the recording was starting."
        case .noInputDevice:
            return "No audio input device is available."
        case .selectedInputUnavailable:
            return "The selected microphone is not available or could not be opened. Choose another microphone or System Default."
        case .selectedInputMismatch:
            return "Core Audio did not connect the selected microphone. Choose another microphone or System Default."
        case .formatUnsupported:
            return "The input device's audio format is not supported."
        case .exportUnavailable:
            return "The recording could not be converted to M4A."
        case .noAudioCaptured:
            return "No audio frames were captured. The empty recording was not saved or sent for transcription."
        case .noAudioSignal:
            return "Audio frames arrived, but they contained no detectable signal. The recording was not used for an audio edit or sent for transcription."
        }
    }

    var isStartOwnershipConflict: Bool {
        self == .recordingAlreadyActive || self == .recordingContextChanged
    }
}

/// Lock-guarded relay from the audio tap to an optional live-transcription
/// handler. Attach/detach happens on the main actor while `send` runs on the
/// audio thread; with no handler attached, `send` is a cheap no-op.
final class LiveAudioTee: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ newHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(buffer)
    }
}

/// Lock-backed rendezvous between AVFAudio's realtime tap and the MainActor
/// startup task. A single snapshot keeps first-buffer format/latency and the
/// last route notification coherent for the startup policy and failure log.
private final class MicrophoneStartupGate: @unchecked Sendable {
    struct Snapshot {
        var lastConfigurationChangeAt: TimeInterval?
        var firstBufferFormat: AVAudioFormat?
        var firstBufferLatency: TimeInterval?
    }

    private let lock = NSLock()
    private var startedAt: TimeInterval?
    private var lastConfigurationChangeAt: TimeInterval?
    private var firstBufferFormat: AVAudioFormat?
    private var firstBufferLatency: TimeInterval?
    private var active = false
    private var committed = false

    func begin(at uptime: TimeInterval) {
        lock.lock()
        startedAt = uptime
        lastConfigurationChangeAt = nil
        firstBufferFormat = nil
        firstBufferLatency = nil
        active = true
        committed = false
        lock.unlock()
    }

    func observeConfigurationChange(at uptime: TimeInterval) {
        lock.lock()
        if active, uptime.isFinite {
            lastConfigurationChangeAt = uptime
        }
        lock.unlock()
    }

    func observeFirstCanonicalBuffer(
        format: AVAudioFormat,
        at uptime: TimeInterval
    ) {
        lock.lock()
        if active, firstBufferFormat == nil, let startedAt,
           uptime.isFinite, uptime >= startedAt {
            firstBufferFormat = format
            firstBufferLatency = uptime - startedAt
        }
        lock.unlock()
    }

    var isCommitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            lastConfigurationChangeAt: lastConfigurationChangeAt,
            firstBufferFormat: firstBufferFormat,
            firstBufferLatency: firstBufferLatency
        )
    }

    func commit() {
        lock.lock()
        if active { committed = true }
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        active = false
        committed = false
        lock.unlock()
    }
}

/// Owns the objects the audio tap touches. Everything is guarded by one lock:
/// the tap runs on an audio thread while pause/stop happen on the main
/// actor, and `finish()` must observe the final state exactly once.
private final class RecordingSink: @unchecked Sendable {
    struct Result {
        var frames: Int64
        var peaks: [Float]
        var error: Error?
        var hasSignal: Bool
    }

    private let lock = NSLock()
    private let file: AVAudioFile
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    private let normalizer: RecordingAudioNormalizer
    private var builder: WaveformBuilder
    private var framesWritten: Int64 = 0
    private var writeError: Error?
    private var finished = false
    private var reportedSourceFormatMismatch = false
    private var startupCommitted = false
    private var hasSignal = false
    private let onUpdate: @Sendable (
        _ elapsed: Double,
        _ peaksTail: [Float],
        _ error: Error?,
        _ inputFormatChanged: Bool,
        _ framesWritten: Int64,
        _ bufferPeak: Float
    ) -> Void

    init(
        file: AVAudioFile,
        targetFormat: AVAudioFormat,
        onUpdate: @escaping @Sendable (
            Double, [Float], Error?, Bool, Int64, Float
        ) -> Void
    ) {
        self.file = file
        self.targetFormat = targetFormat
        self.normalizer = RecordingAudioNormalizer(targetFormat: targetFormat)
        self.builder = WaveformBuilder(sampleRate: targetFormat.sampleRate)
        self.onUpdate = onUpdate
    }

    @discardableResult
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writeError == nil else { return nil }
        if let sourceFormat, buffer.format != sourceFormat {
            if !reportedSourceFormatMismatch {
                reportedSourceFormatMismatch = true
                // Before activation, the polling contract rejects this sink.
                // After activation, queue exactly one runtime quarantine update.
                if startupCommitted {
                    notifyLocked(inputFormatChanged: true)
                }
            }
            return nil
        } else if sourceFormat == nil {
            // A nil-format input tap negotiates against the selected physical
            // route. Adopt the first format AVFAudio actually delivers instead
            // of comparing it with a stale pre-start aggregate format.
            sourceFormat = buffer.format
        }

        let normalized: NormalizedRecordingAudio
        do {
            normalized = try normalizer.normalize(buffer)
        } catch {
            writeError = error
            notifyLocked()
            return nil
        }
        let output = normalized.buffer

        guard output.frameLength > 0 else { return nil }
        do {
            try file.write(from: output)
            framesWritten += Int64(output.frameLength)
            var canonicalPeak: Float = 0
            if let channel = output.floatChannelData?[0] {
                let samples = UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                )
                for sample in samples {
                    canonicalPeak = max(canonicalPeak, abs(sample))
                }
                builder.append(samples)
            }
            if canonicalPeak >= RecordingCaptureHealthMonitor.signalThreshold {
                hasSignal = true
            }
            notifyLocked(bufferPeak: canonicalPeak)
        } catch {
            writeError = error
            notifyLocked()
        }
        return writeError == nil ? output : nil
    }

    var frameCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return framesWritten
    }

    var currentError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return writeError
    }

    var inputFormatMismatchDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedSourceFormatMismatch
    }

    /// Linearizes the startup boundary with the realtime tap. A format change
    /// observed before this lock is acquired rejects the disposable attempt;
    /// one observed afterward is an active-capture route change and follows the
    /// existing quarantine path.
    func commitStartupIfInputFormatStable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reportedSourceFormatMismatch else { return false }
        startupCommitted = true
        return true
    }

    var targetAudioFormat: AVAudioFormat { targetFormat }

    /// Idempotent; closes the file so the finalizer can read it.
    @discardableResult
    func finish() -> Result {
        lock.lock()
        defer { lock.unlock() }
        if !finished {
            finished = true
            builder.finish()
            file.close()
        }
        return Result(
            frames: framesWritten,
            peaks: builder.peaks,
            error: writeError,
            hasSignal: hasSignal
        )
    }

    private func notifyLocked(
        inputFormatChanged: Bool = false,
        bufferPeak: Float = 0
    ) {
        onUpdate(
            Double(framesWritten) / targetFormat.sampleRate,
            Array(builder.peaks.suffix(240)),
            writeError,
            inputFormatChanged,
            framesWritten,
            bufferPeak
        )
    }
}
