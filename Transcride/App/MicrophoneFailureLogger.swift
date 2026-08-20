import CryptoKit
import Foundation
import OSLog

/// A durable, always-on diagnostic record for microphone failures.
///
/// This deliberately accepts only bounded diagnostic metadata. It has no field
/// for an entry URL, vault path, audio buffer, device display name, or an error
/// description, so callers cannot accidentally persist recording content or
/// user-authored filenames. Error identity is limited to domain and code.
struct MicrophoneFailureEvent: Sendable {
    enum Kind: String, Codable, Sendable {
        case initializationFailed = "initialization_failed"
        case noAudioAfterStart = "no_audio_after_start"
        case perfectlySilentClip = "perfectly_silent_clip"
        case captureStalled = "capture_stalled"
    }

    enum Target: String, Codable, Sendable {
        case newEntry = "new_entry"
        case extensionRecording = "extension_recording"
        case replacementTake = "replacement_take"
        case unknown
    }

    enum Stage: String, Codable, Sendable {
        case permission
        case deviceSelection = "device_selection"
        case inputFormat = "input_format"
        case journalCreation = "journal_creation"
        case tapInstallation = "tap_installation"
        case engineStart = "engine_start"
        case postStartValidation = "post_start_validation"
        case firstBuffer = "first_buffer"
        case activeCapture = "active_capture"
        case resume
        case finalization
        case cancellation
        case recoveryPreservation = "recovery_preservation"
        case crashRecovery = "crash_recovery"
    }

    /// Controlled reason codes keep localized error text and paths out of the
    /// durable log while still making failures groupable across app versions.
    enum Reason: String, Codable, Sendable {
        case permissionDenied = "permission_denied"
        case permissionRestricted = "permission_restricted"
        case selectedInputUnavailable = "selected_input_unavailable"
        case noInputDevice = "no_input_device"
        case unsupportedInputFormat = "unsupported_input_format"
        case journalCreationFailed = "journal_creation_failed"
        case tapInstallationFailed = "tap_installation_failed"
        case engineStartFailed = "engine_start_failed"
        case selectedInputMismatch = "selected_input_mismatch"
        case unusableResolvedInput = "unusable_resolved_input"
        case noBuffers = "no_buffers"
        case noFrames = "no_frames"
        case perfectlySilent = "perfectly_silent"
        case captureStalled = "capture_stalled"
        case engineStopped = "engine_stopped"
        case inputChanged = "input_changed"
        case sinkWriteFailed = "sink_write_failed"
        case resumeFailed = "resume_failed"
        case unknown
    }

    struct PreferredRoute: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Sendable {
            case systemDefault = "system_default"
            case selectedDevice = "selected_device"
            case unknown
        }

        var mode: Mode
        /// A one-way, truncated SHA-256 fingerprint used only to correlate
        /// repeated failures on the same selected route. Raw device UIDs can
        /// contain hardware addresses and must never enter the retained log.
        var uidFingerprint: String?

        static let systemDefault = Self(mode: .systemDefault, uidFingerprint: nil)
        static let unknown = Self(mode: .unknown, uidFingerprint: nil)

        static func selectedDevice(uid: String) -> Self {
            let digest = SHA256.hash(data: Data(uid.utf8))
            let fingerprint = digest.prefix(12).map {
                String(format: "%02x", $0)
            }.joined()
            return Self(mode: .selectedDevice, uidFingerprint: fingerprint)
        }
    }

    struct ResolvedDeviceFormat: Codable, Equatable, Sendable {
        enum SampleFormat: String, Codable, Sendable {
            case float32
            case float64
            case int16
            case int32
            case other
            case unknown
        }

        var deviceID: UInt32?
        var sampleRate: Double?
        var channelCount: UInt32?
        var sampleFormat: SampleFormat
        var isInterleaved: Bool?

        init(
            deviceID: UInt32?,
            sampleRate: Double?,
            channelCount: UInt32?,
            sampleFormat: SampleFormat = .unknown,
            isInterleaved: Bool? = nil
        ) {
            self.deviceID = deviceID
            self.sampleRate = sampleRate.flatMap { value in
                value.isFinite && value >= 0 ? value : nil
            }
            self.channelCount = channelCount
            self.sampleFormat = sampleFormat
            self.isInterleaved = isInterleaved
        }
    }

    struct EngineState: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case notCreated = "not_created"
            case created
            case prepared
            case running
            case paused
            case stopped
            case finalizing
            case unknown
        }

        var phase: Phase
        var isRunning: Bool
        var tapInstalled: Bool
        /// `installTap` is nonthrowing and can be rejected asynchronously by
        /// AVFAudio. A true value proves that the tap delivered audio which was
        /// normalized and written, rather than merely that installation was
        /// requested.
        var firstBufferConfirmed: Bool?

        init(
            phase: Phase,
            isRunning: Bool,
            tapInstalled: Bool,
            firstBufferConfirmed: Bool? = nil
        ) {
            self.phase = phase
            self.isRunning = isRunning
            self.tapInstalled = tapInstalled
            self.firstBufferConfirmed = firstBufferConfirmed
        }
    }

    struct ErrorIdentity: Codable, Equatable, Sendable {
        var domain: String
        var code: Int

        init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }

        init(_ error: Error) {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
        }
    }

    var sessionID: UUID
    var kind: Kind
    var target: Target
    var stage: Stage
    var reason: Reason
    var preferredRoute: PreferredRoute
    var attemptNumber: Int?
    var requestedDeviceID: UInt32?
    var baselineDeviceFormat: ResolvedDeviceFormat?
    var currentDeviceFormat: ResolvedDeviceFormat?
    var resolvedDeviceFormat: ResolvedDeviceFormat?
    var firstBufferFormat: ResolvedDeviceFormat?
    var firstBufferLatencySeconds: TimeInterval?
    var engineState: EngineState
    var frames: Int64
    var elapsedSeconds: TimeInterval
    var error: ErrorIdentity?

    init(
        sessionID: UUID,
        kind: Kind,
        target: Target,
        stage: Stage,
        reason: Reason,
        preferredRoute: PreferredRoute,
        resolvedDeviceFormat: ResolvedDeviceFormat?,
        engineState: EngineState,
        frames: Int64,
        elapsedSeconds: TimeInterval,
        error: ErrorIdentity? = nil,
        attemptNumber: Int? = nil,
        requestedDeviceID: UInt32? = nil,
        baselineDeviceFormat: ResolvedDeviceFormat? = nil,
        currentDeviceFormat: ResolvedDeviceFormat? = nil,
        firstBufferFormat: ResolvedDeviceFormat? = nil,
        firstBufferLatencySeconds: TimeInterval? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.target = target
        self.stage = stage
        self.reason = reason
        self.preferredRoute = preferredRoute
        self.attemptNumber = attemptNumber.map { max(1, $0) }
        self.requestedDeviceID = requestedDeviceID
        self.baselineDeviceFormat = baselineDeviceFormat
        self.currentDeviceFormat = currentDeviceFormat
        self.resolvedDeviceFormat = resolvedDeviceFormat
        self.firstBufferFormat = firstBufferFormat
        self.firstBufferLatencySeconds = firstBufferLatencySeconds.flatMap { value in
            value.isFinite ? max(0, value) : nil
        }
        self.engineState = engineState
        self.frames = max(0, frames)
        self.elapsedSeconds = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
        self.error = error
    }
}

struct MicrophoneFailureLogVersion: Equatable, Sendable {
    var appVersion: String
    var appBuild: String

    static var current: Self {
        let info = Bundle.main.infoDictionary
        return Self(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown"
        )
    }
}

/// The on-disk JSONL schema. Kept separate from the call-site event so the
/// logger, rather than every caller, owns timestamps, app identity, and unique
/// event IDs.
struct MicrophoneFailureLogRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var timestamp: String
    var appVersion: String
    var appBuild: String
    var eventID: UUID
    var sessionID: UUID
    var event: MicrophoneFailureEvent.Kind
    var target: MicrophoneFailureEvent.Target
    var stage: MicrophoneFailureEvent.Stage
    var reason: MicrophoneFailureEvent.Reason
    var preferredRoute: MicrophoneFailureEvent.PreferredRoute
    var attemptNumber: Int?
    var requestedDeviceID: UInt32?
    var baselineDeviceFormat: MicrophoneFailureEvent.ResolvedDeviceFormat?
    var currentDeviceFormat: MicrophoneFailureEvent.ResolvedDeviceFormat?
    var resolvedDeviceFormat: MicrophoneFailureEvent.ResolvedDeviceFormat?
    var firstBufferFormat: MicrophoneFailureEvent.ResolvedDeviceFormat?
    var firstBufferLatencySeconds: TimeInterval?
    var engineState: MicrophoneFailureEvent.EngineState
    var frames: Int64
    var elapsedSeconds: TimeInterval
    var error: MicrophoneFailureEvent.ErrorIdentity?
}

/// Append-only microphone failure journal stored independently of `DebugLog`.
/// Writes are synchronous because failures are rare and durability matters: a
/// successful return means the line was flushed before recording teardown can
/// continue. Every failure is best-effort and nonthrowing to callers.
final class MicrophoneFailureLogger: @unchecked Sendable {
    typealias Clock = @Sendable () -> Date

    static let shared = MicrophoneFailureLogger()
    private static let fallbackLogger = Logger(
        subsystem: "com.ashandevine.transcride",
        category: "microphone-capture-failure"
    )

    static let defaultURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appending(path: "transcride-microphone-failures.jsonl")
    }()

    let url: URL

    private let clock: Clock
    private let version: MicrophoneFailureLogVersion
    private let queue = DispatchQueue(
        label: "com.ashandevine.transcride.microphone-failure-log",
        qos: .utility
    )

    init(
        url: URL = MicrophoneFailureLogger.defaultURL,
        clock: @escaping Clock = { .now },
        version: MicrophoneFailureLogVersion = .current
    ) {
        self.url = url
        self.clock = clock
        self.version = version
    }

    /// Appends one record. The result is diagnostic only; callers must never
    /// change recording behavior based on a logging failure.
    @discardableResult
    func log(_ event: MicrophoneFailureEvent) -> Bool {
        queue.sync {
            let record = MicrophoneFailureLogRecord(
                schemaVersion: MicrophoneFailureLogRecord.currentSchemaVersion,
                timestamp: Self.timestamp(clock()),
                appVersion: version.appVersion,
                appBuild: version.appBuild,
                eventID: UUID(),
                sessionID: event.sessionID,
                event: event.kind,
                target: event.target,
                stage: event.stage,
                reason: event.reason,
                preferredRoute: event.preferredRoute,
                attemptNumber: event.attemptNumber,
                requestedDeviceID: event.requestedDeviceID,
                baselineDeviceFormat: event.baselineDeviceFormat,
                currentDeviceFormat: event.currentDeviceFormat,
                resolvedDeviceFormat: event.resolvedDeviceFormat,
                firstBufferFormat: event.firstBufferFormat,
                firstBufferLatencySeconds: event.firstBufferLatencySeconds,
                engineState: event.engineState,
                frames: event.frames,
                elapsedSeconds: event.elapsedSeconds,
                error: event.error
            )
            return append(record)
        }
    }

    private func append(_ record: MicrophoneFailureLogRecord) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(record)
            line.append(0x0A)

            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            // Correct permissions even if a prior build or manual recovery
            // created the file with a broader umask-derived mode.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            return true
        } catch {
            // Logging must never mask, replace, or perturb the microphone
            // failure the caller is already handling.
            Self.fallbackLogger.fault(
                "Durable microphone failure log append failed"
            )
            return false
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
