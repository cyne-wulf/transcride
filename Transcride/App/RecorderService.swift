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
        switch self {
        case .compressed:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        case .lossless:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16,
            ]
        }
    }
}

/// Records microphone audio into an entry folder.
///
/// Pipeline: AVAudioEngine input tap → AVAudioConverter (to mono 44.1 kHz
/// float) → AVAudioFile encoding AAC/ALAC into a hidden `.recording.caf`.
/// CAF headers are valid from the first buffer, so a crash mid-recording
/// leaves a playable partial file, never a corrupt entry. On stop the CAF is
/// remuxed (no re-encode) into the final `audio.m4a`, and `waveform.json` +
/// the stub transcript are written.
@MainActor
@Observable
final class RecorderService {
    enum State {
        case idle
        case recording
        case paused
        case finalizing
    }

    nonisolated static let partialFileName = ".recording.caf"

    private(set) var state: State = .idle
    /// Recorded audio time in seconds (excludes pauses).
    private(set) var elapsed: Double = 0
    /// Tail of the live waveform (canonical resolution, newest last).
    private(set) var livePeaks: [Float] = []
    /// Vault-relative path of the entry being recorded; nil when idle.
    private(set) var currentEntryPath: RelativePath?
    /// Recording problems surfaced to the UI (device loss, disk errors).
    var alertMessage: String?
    var isZenMode = false

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var entryURL: URL?
    private var entryCreated: Date = .now
    private var sampleRate: Double = 44_100
    private var configChangeObserver: NSObjectProtocol?
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
        preferredMicUID: String
    ) throws {
        guard state == .idle else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !preferredMicUID.isEmpty,
           let device = AudioInputDevices.allInputDevices().first(where: { $0.uid == preferredMicUID }),
           let unit = input.audioUnit {
            var deviceID = device.deviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let cafURL = entryURL.appending(path: Self.partialFileName)
        let file = try AVAudioFile(
            forWriting: cafURL,
            settings: quality.fileSettings,
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
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            sink.process(buffer)
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

        self.engine = engine
        self.sink = sink
        self.entryURL = entryURL
        self.sampleRate = targetFormat.sampleRate
        currentEntryPath = relativePath
        entryCreated = EntryFolderName(parsing: entryURL.lastPathComponent)?.date ?? .now
        elapsed = 0
        livePeaks = []
        reportedSinkError = false
        state = .recording

        // REC-3: if the input device disappears (or the graph reconfigures)
        // mid-recording, pause with everything so far safely on disk.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
        DebugLog.append("recorder: started [\(relativePath)] quality=\(quality.rawValue)")
    }

    func pause() {
        guard state == .recording else { return }
        engine?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try engine?.start()
            state = .recording
        } catch {
            alertMessage = "Could not resume recording: \(error.localizedDescription)"
        }
    }

    private func handleConfigurationChange() {
        guard state == .recording else { return }
        pause()
        alertMessage = """
        The audio input changed or disappeared, so the recording was paused. \
        Nothing was lost — press resume to continue on the current input, or stop to finish.
        """
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
    func stop() async -> RelativePath? {
        guard state == .recording || state == .paused,
              let engine, let sink, let entryURL else { return nil }
        state = .finalizing
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let result = sink.finish()
        self.engine = nil
        self.sink = nil
        self.entryURL = nil

        let relPath = currentEntryPath
        let duration = Double(result.frames) / sampleRate
        do {
            try await Self.finalize(
                entryURL: entryURL,
                created: entryCreated,
                duration: duration,
                peaks: result.peaks
            )
            if let writeError = result.error {
                alertMessage = """
                The recording was saved, but part of the audio could not be written: \
                \(writeError.localizedDescription)
                """
            }
        } catch {
            alertMessage = "The recording could not be finalized: \(error.localizedDescription)"
        }

        state = .idle
        currentEntryPath = nil
        elapsed = 0
        livePeaks = []
        DebugLog.append("recorder: stopped [\(relPath ?? "?")] duration=\(duration)")
        return relPath
    }

    /// Remux CAF → `audio.m4a` (passthrough, no re-encode), write
    /// `waveform.json` from the live-accumulated peaks, write the stub
    /// transcript. Falls back to keeping the audio as `audio.caf` if the
    /// remux fails — the vault accepts any audio extension.
    private nonisolated static func finalize(
        entryURL: URL, created: Date, duration: Double, peaks: [Float]
    ) async throws {
        let cafURL = entryURL.appending(path: partialFileName)
        let m4aURL = entryURL.appending(path: "audio.m4a")

        var remuxError: Error?
        do {
            let asset = AVURLAsset(url: cafURL)
            guard let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough
            ) else {
                throw RecorderError.exportUnavailable
            }
            try await session.export(to: m4aURL, as: .m4a)
            try FileManager.default.removeItem(at: cafURL)
        } catch {
            remuxError = error
            try? FileManager.default.removeItem(at: m4aURL)
            try FileManager.default.moveItem(at: cafURL, to: entryURL.appending(path: "audio.caf"))
            DebugLog.append("recorder: remux to m4a failed (kept audio.caf): \(error)")
        }

        try WaveformData(duration: duration, peaks: peaks)
            .write(to: WaveformData.url(inEntry: entryURL))
        try EntryCreator.writeRecordingStub(entryURL: entryURL, created: created, duration: duration)
        _ = remuxError // audio survives either way; the entry is complete
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
