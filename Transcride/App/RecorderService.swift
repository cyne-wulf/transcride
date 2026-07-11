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
    enum SessionTarget: Equatable, Sendable {
        case newEntry
        case extensionOf(RecordingExtensionTarget)
    }

    struct FinalizationOutcome: Sendable {
        var entryRelativePath: RelativePath
        var target: SessionTarget
        var duration: Double
        var extensionSegmentURL: URL?
    }

    enum State {
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
    /// Recorded audio time in seconds (excludes pauses).
    private(set) var elapsed: Double = 0
    /// Tail of the live waveform (canonical resolution, newest last).
    private(set) var livePeaks: [Float] = []
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
    private var reportedSinkError = false

    var isActive: Bool { state != .idle }

    // MARK: - Permission

    static func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Start / pause / resume

    /// Starts recording into `entryURL` (an already-created entry folder).
    func start(
        entryURL: URL,
        relativePath: RelativePath,
        quality: RecordingQuality,
        preferredMicUID: String,
        target: SessionTarget = .newEntry
    ) throws {
        guard state == .idle else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        var preferredDeviceStatus: OSStatus?
        if !preferredMicUID.isEmpty,
           let device = AudioInputDevices.allInputDevices().first(where: { $0.uid == preferredMicUID }),
           let unit = input.audioUnit {
            var deviceID = device.deviceID
            preferredDeviceStatus = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let partialName = switch target {
        case .newEntry: Self.partialFileName
        case .extensionOf: RecordingExtensionArtifacts.partialFileName
        }
        let cafURL = entryURL.appending(path: partialName)
        let file = try AVAudioFile(
            forWriting: cafURL,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let targetFormat = file.processingFormat
        let converter: AVAudioConverter?
        if inputFormat == targetFormat {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw RecorderError.formatUnsupported
            }
            converter = made
        }

        let sink = RecordingSink(
            file: file,
            converter: converter,
            targetFormat: targetFormat
        ) { [weak self] elapsed, peaksTail, error in
            Task { @MainActor [weak self] in
                self?.applySinkUpdate(elapsed: elapsed, peaksTail: peaksTail, error: error)
            }
        }
        // The tap block runs on an AVFAudio realtime queue. It must be
        // @Sendable so it's nonisolated — a plain closure formed in this
        // @MainActor method carries a runtime main-actor check and traps
        // the moment the first buffer arrives off-main.
        let liveTee = self.liveTee
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            sink.process(buffer)
            liveTee.send(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.finish()
            try? FileManager.default.removeItem(at: cafURL)
            throw error
        }

        let baselineInputSignature = Self.inputSignature(for: engine)
        guard baselineInputSignature.isUsable else {
            input.removeTap(onBus: 0)
            engine.stop()
            sink.finish()
            try? FileManager.default.removeItem(at: cafURL)
            throw RecorderError.noInputDevice
        }

        self.engine = engine
        self.sink = sink
        self.entryURL = entryURL
        self.sampleRate = targetFormat.sampleRate
        recordingQuality = quality
        currentEntryPath = relativePath
        sessionTarget = target
        if case .extensionOf(let extensionTarget) = target {
            extensionSession = RecordingExtensionSession(target: extensionTarget)
            persistExtensionSession(in: entryURL)
        } else {
            extensionSession = nil
        }
        entryCreated = EntryFolderName(parsing: entryURL.lastPathComponent)?.date ?? .now
        elapsed = 0
        livePeaks = []
        alertMessage = nil
        self.baselineInputSignature = baselineInputSignature
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        configurationChangeCount = 0
        configurationChangePending = false
        isHandlingConfigurationChange = false
        reportedSinkError = false
        state = .recording

        // REC-3: if the input device disappears (or the graph reconfigures)
        // mid-recording, pause with everything so far safely on disk.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in await self?.receiveConfigurationChange() }
        }
        let preferredStatusDescription = preferredDeviceStatus.map(String.init) ?? "default"
        DebugLog.append(
            "recorder: started [\(relativePath)] quality=\(quality.rawValue) "
                + "input={\(Self.describe(baselineInputSignature))} "
                + "preferred_uid=\(preferredMicUID.isEmpty ? "<system-default>" : preferredMicUID) "
                + "set_device_status=\(preferredStatusDescription) engine_running=\(engine.isRunning)"
        )
    }

    func pause() {
        guard state == .recording else { return }
        engine?.pause()
        state = .paused
        if extensionSession != nil {
            try? extensionSession?.transition(to: .paused)
            persistExtensionSession(in: entryURL)
        }
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try engine?.start()
            state = .recording
            if extensionSession != nil {
                try? extensionSession?.transition(to: .capturing)
                persistExtensionSession(in: entryURL)
            }
        } catch {
            alertMessage = "Could not resume recording: \(error.localizedDescription)"
        }
    }

    private func receiveConfigurationChange() async {
        configurationChangePending = true
        guard !isHandlingConfigurationChange else { return }

        isHandlingConfigurationChange = true
        defer { isHandlingConfigurationChange = false }
        while configurationChangePending, state == .recording {
            configurationChangePending = false
            await evaluateConfigurationChange()
        }
    }

    private func evaluateConfigurationChange() async {
        guard state == .recording,
              let engine,
              let baselineInputSignature else { return }

        configurationChangeCount += 1
        let event = configurationChangeCount
        let current = Self.inputSignature(for: engine)
        let wasRunning = engine.isRunning
        let sinceStart = recordingStartUptime.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
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

        switch decision {
        case .keepRunning:
            return
        case .restartEngine:
            await restartEngineAfterBenignConfigurationChange(
                engine,
                baseline: baselineInputSignature,
                event: event
            )
        case .pauseForInputChange:
            pauseForInputChange(engine: engine, event: event, current: current)
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
        let retryDelays: [UInt64] = [0, 50_000_000, 150_000_000, 300_000_000]
        var lastError: Error?

        for delay in retryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard state == .recording, self.engine === engine else { return }

            let current = Self.inputSignature(for: engine)
            guard baseline.isCompatible(with: current) else {
                pauseForInputChange(engine: engine, event: event, current: current)
                return
            }
            if engine.isRunning {
                DebugLog.append(
                    "recorder: config_change #\(event) recovered before restart "
                        + "input={\(Self.describe(current))}"
                )
                return
            }

            do {
                engine.prepare()
                try engine.start()
                DebugLog.append(
                    "recorder: config_change #\(event) restarted engine "
                        + "input={\(Self.describe(current))}"
                )
                return
            } catch {
                lastError = error
                DebugLog.append(
                    "recorder: config_change #\(event) restart attempt failed: \(error)"
                )
            }
        }

        guard state == .recording, self.engine === engine else { return }
        engine.pause()
        state = .paused
        let detail = lastError?.localizedDescription ?? "CoreAudio did not restart the engine."
        alertMessage = "Recording paused — the microphone is still available, but audio capture could not restart: \(detail)"
        DebugLog.append("recorder: config_change #\(event) recovery exhausted; paused")
    }

    private func pauseForInputChange(
        engine: AVAudioEngine,
        event: Int,
        current: RecordingInputSignature
    ) {
        guard state == .recording else { return }
        engine.pause()
        state = .paused
        alertMessage = """
        The audio input changed or disappeared, so the recording was paused. \
        Nothing was lost — press resume to continue on the current input, or stop to finish.
        """
        DebugLog.append(
            "recorder: config_change #\(event) input changed; paused current={\(Self.describe(current))}"
        )
    }

    private static func inputSignature(for engine: AVAudioEngine) -> RecordingInputSignature {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let deviceID = AudioInputDevices.currentInputDeviceID(for: input.audioUnit)
        return RecordingInputSignature(
            deviceID: deviceID,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            deviceIsAvailable: deviceID.map(AudioInputDevices.isUsableInputDevice) ?? false
        )
    }

    private static func describe(_ signature: RecordingInputSignature) -> String {
        let device = signature.deviceID.map(String.init) ?? "nil"
        return "device=\(device),rate=\(String(format: "%.1f", signature.sampleRate)),"
            + "channels=\(signature.channelCount),available=\(signature.deviceIsAvailable)"
    }

    private func applySinkUpdate(elapsed: Double, peaksTail: [Float], error: Error?) {
        guard state == .recording || state == .paused else { return }
        self.elapsed = elapsed
        livePeaks = peaksTail
        if let error, !reportedSinkError {
            reportedSinkError = true
            pause()
            alertMessage = "Recording paused — audio could not be written: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop / finalize

    /// Stops and finalizes the recording. Returns the entry's vault-relative
    /// path on success (also on partial success — the alert says what failed).
    func stop() async -> FinalizationOutcome? {
        guard state == .recording || state == .paused,
              let engine, let sink, let entryURL, let sessionTarget else { return nil }
        state = .finalizing
        if extensionSession != nil {
            try? extensionSession?.transition(to: .finalizingSegment)
            persistExtensionSession(in: entryURL)
        }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        configurationChangePending = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let result = sink.finish()
        self.engine = nil
        self.sink = nil
        self.entryURL = nil
        baselineInputSignature = nil
        recordingStartUptime = nil

        let relPath = currentEntryPath
        let duration = Double(result.frames) / sampleRate
        var extensionSegmentURL: URL?
        do {
            switch sessionTarget {
            case .newEntry:
                try await Self.finalize(
                    entryURL: entryURL,
                    created: entryCreated,
                    duration: duration,
                    peaks: result.peaks,
                    quality: recordingQuality
                )
            case .extensionOf:
                extensionSegmentURL = try await Self.finalizeExtensionSegment(
                    entryURL: entryURL, duration: duration, quality: recordingQuality
                )
                extensionSession?.segmentDuration = duration
                try extensionSession?.transition(to: .segmentReady)
                persistExtensionSession(in: entryURL)
            }
            if let writeError = result.error {
                alertMessage = """
                The recording was saved, but part of the audio could not be written: \
                \(writeError.localizedDescription)
                """
            }
        } catch RecordingExtensionError.segmentTooShort {
            try? FileManager.default.removeItem(
                at: entryURL.appending(path: RecordingExtensionArtifacts.partialFileName)
            )
            alertMessage = "The extension was too short to append. The existing recording was not changed."
        } catch {
            extensionSession?.fail(error.localizedDescription)
            persistExtensionSession(in: entryURL)
            alertMessage = "The recording could not be finalized: \(error.localizedDescription)"
        }

        if case .newEntry = sessionTarget {
            state = .idle
            currentEntryPath = nil
            self.sessionTarget = nil
            elapsed = 0
            livePeaks = []
        } else {
            retainedExtensionEntryURL = entryURL
        }
        DebugLog.append("recorder: stopped [\(relPath ?? "?")] duration=\(duration)")
        guard let relPath else { return nil }
        return FinalizationOutcome(
            entryRelativePath: relPath,
            target: sessionTarget,
            duration: duration,
            extensionSegmentURL: extensionSegmentURL
        )
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

    /// Remux CAF → `audio.m4a` (passthrough, no re-encode), write
    /// `waveform.json` from the live-accumulated peaks, write the stub
    /// transcript. Falls back to keeping the audio as `audio.caf` if the
    /// remux fails — the vault accepts any audio extension.
    private nonisolated static func finalize(
        entryURL: URL,
        created: Date,
        duration: Double,
        peaks: [Float],
        quality: RecordingQuality
    ) async throws {
        let cafURL = entryURL.appending(path: partialFileName)
        let m4aURL = entryURL.appending(path: "audio.m4a")

        do {
            try await Task.detached {
                try CrashTolerantAudioJournal.encodeM4A(
                    from: cafURL, to: m4aURL, encoding: quality.outputEncoding
                )
            }.value
            try FileManager.default.removeItem(at: cafURL)
        } catch {
            try? FileManager.default.removeItem(at: m4aURL)
            try FileManager.default.moveItem(at: cafURL, to: entryURL.appending(path: "audio.caf"))
            DebugLog.append("recorder: encode to m4a failed (kept PCM audio.caf): \(error)")
        }

        try WaveformData(duration: duration, peaks: peaks)
            .write(to: WaveformData.url(inEntry: entryURL))
        try EntryCreator.writeRecordingStub(entryURL: entryURL, created: created, duration: duration)
    }

    /// Finalizes only the newly captured tail. It deliberately does not write
    /// entry metadata, waveform, or transcript; the visible entry is untouched
    /// until composition validates and the safe swap succeeds.
    private nonisolated static func finalizeExtensionSegment(
        entryURL: URL, duration: Double, quality: RecordingQuality
    ) async throws -> URL {
        guard duration >= AudioExtensionComposer.minimumSegmentDuration else {
            throw RecordingExtensionError.segmentTooShort
        }
        let cafURL = entryURL.appending(path: RecordingExtensionArtifacts.partialFileName)
        let m4aURL = entryURL.appending(path: RecordingExtensionArtifacts.segmentM4AFileName)
        do {
            try await Task.detached {
                try CrashTolerantAudioJournal.encodeM4A(
                    from: cafURL, to: m4aURL, encoding: quality.outputEncoding
                )
            }.value
            try FileManager.default.removeItem(at: cafURL)
            return m4aURL
        } catch {
            let retained = entryURL.appending(path: RecordingExtensionArtifacts.segmentCAFFileName)
            try? FileManager.default.removeItem(at: retained)
            try FileManager.default.moveItem(at: cafURL, to: retained)
            DebugLog.append("extension segment remux failed (kept CAF): \(error)")
            return retained
        }
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case formatUnsupported
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device is available."
        case .formatUnsupported:
            return "The input device's audio format is not supported."
        case .exportUnavailable:
            return "The recording could not be converted to M4A."
        }
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

/// Hands one tap buffer to an AVAudioConverter input block (which the SDK
/// marks @Sendable) exactly once. Only touched synchronously inside
/// `RecordingSink.process`, never concurrently.
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
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
    }

    private let lock = NSLock()
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var builder: WaveformBuilder
    private var framesWritten: Int64 = 0
    private var writeError: Error?
    private var finished = false
    private let onUpdate: @Sendable (_ elapsed: Double, _ peaksTail: [Float], _ error: Error?) -> Void

    init(
        file: AVAudioFile,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat,
        onUpdate: @escaping @Sendable (Double, [Float], Error?) -> Void
    ) {
        self.file = file
        self.converter = converter
        self.targetFormat = targetFormat
        self.builder = WaveformBuilder(sampleRate: targetFormat.sampleRate)
        self.onUpdate = onUpdate
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writeError == nil else { return }

        let output: AVAudioPCMBuffer
        if let converter {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }
            let feed = ConverterFeed(buffer: buffer)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                guard let buffer = feed.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                writeError = conversionError ?? RecorderError.formatUnsupported
                notifyLocked()
                return
            }
            output = converted
        } else {
            output = buffer
        }

        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
            framesWritten += Int64(output.frameLength)
            if let channel = output.floatChannelData?[0] {
                builder.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        } catch {
            writeError = error
        }
        notifyLocked()
    }

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
        return Result(frames: framesWritten, peaks: builder.peaks, error: writeError)
    }

    private func notifyLocked() {
        onUpdate(
            Double(framesWritten) / targetFormat.sampleRate,
            Array(builder.peaks.suffix(240)),
            writeError
        )
    }
}
