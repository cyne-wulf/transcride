@preconcurrency import AVFoundation
import Foundation

// The durable half of the optional universal-recording path: the sparse
// Mac-audio sidecar format (writer and reader) and the offline mixer that
// folds it back onto the microphone journal.
//
// This lives in Core rather than beside the ScreenCaptureKit adapter because
// abrupt-crash recovery is the last moment a microphone journal and its
// sidecar coexist: the sidecar positions every chunk by frame index on that
// journal's timeline, so a mix that is not performed there can never be
// performed at all. `InterruptedRecordingRecovery` cannot reach the app layer,
// so the format and the renderer live here with it.

/// Internal rather than private only because the ScreenCaptureKit adapter in
/// the app layer maps these to `OptionalSystemAudioFallbackReason`.
enum UniversalSystemAudioCaptureFailure: Error {
    case invalidTiming
    case invalidFormat
    case sidecarWriteFailed

    var fallbackReason: OptionalSystemAudioFallbackReason {
        switch self {
        case .invalidTiming: .invalidTiming
        case .invalidFormat: .invalidFormat
        case .sidecarWriteFailed: .sidecarWriteFailed
        }
    }
}

/// Signal-gated writer with bounded in-memory pre-roll and release hysteresis.
/// The file is created lazily at the first meaningful signal, so ordinary
/// microphone recordings leave no second durable artifact or silent growth.
final class SparseSystemAudioJournal {
    struct Configuration: Equatable, Sendable {
        var meaningfulSignalThreshold: Float = 0.001
        var preRollFrames: Int = 11_025       // 250 ms at 44.1 kHz
        var releaseFrames: Int = 22_050       // 500 ms at 44.1 kHz
    }

    static let magic = Data("TRSYS001".utf8)

    let meaningfulSignalThreshold: Float
    private let url: URL
    private let configuration: Configuration
    private var handle: FileHandle?
    private var preRoll: [UniversalRecordingAudioChunk] = []
    private var preRollFrameCount = 0
    private var releaseFramesRemaining = 0
    private var isActive = false
    private var hasMeaningfulSignal = false
    private var lastRecordEnd: Int64?
    private var finished = false

    init(url: URL, configuration: Configuration = .init()) {
        precondition(configuration.meaningfulSignalThreshold.isFinite)
        precondition(configuration.meaningfulSignalThreshold > 0)
        precondition(configuration.preRollFrames >= 0 && configuration.releaseFrames >= 0)
        self.url = url
        self.configuration = configuration
        self.meaningfulSignalThreshold = configuration.meaningfulSignalThreshold
        try? FileManager.default.removeItem(at: url)
    }

    func append(samples: [Float], startFrame: Int64, peak: Float) throws {
        guard !finished, !samples.isEmpty else { return }
        let (_, frameEndOverflow) = startFrame.addingReportingOverflow(Int64(samples.count))
        guard startFrame >= 0, !frameEndOverflow else {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw UniversalSystemAudioCaptureFailure.invalidFormat
        }
        let chunk = UniversalRecordingAudioChunk(startFrame: startFrame, samples: samples)
        let meaningful = peak.isFinite && peak >= meaningfulSignalThreshold

        if meaningful {
            if !isActive {
                try openIfNeeded()
                for buffered in preRoll { try write(buffered) }
                preRoll.removeAll(keepingCapacity: true)
                preRollFrameCount = 0
            }
            try write(chunk)
            hasMeaningfulSignal = true
            isActive = true
            releaseFramesRemaining = configuration.releaseFrames
            return
        }

        if isActive {
            let retainedCount = min(releaseFramesRemaining, samples.count)
            if retainedCount > 0 {
                try write(.init(
                    startFrame: startFrame,
                    samples: Array(samples.prefix(retainedCount))
                ))
            }
            releaseFramesRemaining -= retainedCount
            if releaseFramesRemaining == 0 {
                isActive = false
                if retainedCount < samples.count {
                    appendToPreRoll(.init(
                        startFrame: startFrame + Int64(retainedCount),
                        samples: Array(samples.dropFirst(retainedCount))
                    ))
                }
            }
        } else {
            appendToPreRoll(chunk)
        }
    }

    func finish() -> URL? {
        guard !finished else { return hasMeaningfulSignal ? url : nil }
        finished = true
        preRoll.removeAll()
        preRollFrameCount = 0
        try? handle?.close()
        handle = nil
        guard hasMeaningfulSignal else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func appendToPreRoll(_ chunk: UniversalRecordingAudioChunk) {
        guard configuration.preRollFrames > 0 else { return }
        preRoll.append(chunk)
        preRollFrameCount += chunk.samples.count
        while preRollFrameCount > configuration.preRollFrames, !preRoll.isEmpty {
            let overflow = preRollFrameCount - configuration.preRollFrames
            if preRoll[0].samples.count <= overflow {
                preRollFrameCount -= preRoll.removeFirst().samples.count
            } else {
                preRoll[0].startFrame += Int64(overflow)
                preRoll[0].samples.removeFirst(overflow)
                preRollFrameCount -= overflow
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        FileManager.default.createFile(atPath: url.path, contents: Self.magic)
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    private func write(_ chunk: UniversalRecordingAudioChunk) throws {
        guard let handle else { throw UniversalSystemAudioCaptureFailure.sidecarWriteFailed }
        let (recordEnd, overflow) = chunk.startFrame.addingReportingOverflow(
            Int64(chunk.samples.count)
        )
        if overflow || lastRecordEnd.map({ chunk.startFrame < $0 }) == true {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        guard let count = UInt32(exactly: chunk.samples.count) else {
            throw UniversalSystemAudioCaptureFailure.sidecarWriteFailed
        }
        var data = Data(capacity: 12 + chunk.samples.count * MemoryLayout<UInt32>.size)
        data.appendLittleEndian(chunk.startFrame)
        data.appendLittleEndian(count)
        for sample in chunk.samples { data.appendLittleEndian(sample.bitPattern) }
        try handle.write(contentsOf: data)
        lastRecordEnd = recordEnd
    }
}

struct UniversalRecordingFileMixResult: Sendable {
    var frames: Int64
    var peaks: [Float]
    var firstSystemFrame: Int64
}

struct UniversalRecordingFileSelection: Sendable {
    var journalURL: URL
    var peaks: [Float]
    var firstSystemFrame: Int64?
    var fallbackReason: OptionalSystemAudioFallbackReason?
}

/// Production fallback boundary shared with integration tests. Rendering is
/// attempted beside the pristine microphone master; every failure deletes the
/// untrusted stage and returns that master unchanged.
enum UniversalRecordingFileResolver {
    static func renderOrUseMicrophone(
        microphoneURL: URL,
        microphoneFrames: Int64,
        microphonePeaks: [Float],
        systemJournalURL: URL,
        stagedURL: URL
    ) -> UniversalRecordingFileSelection {
        do {
            let result = try UniversalRecordingFileMixer.render(
                microphoneURL: microphoneURL,
                systemJournalURL: systemJournalURL,
                stagedURL: stagedURL
            )
            guard result.frames == microphoneFrames else {
                throw UniversalRecordingFileMixError.invalidOutput
            }
            // Only a validated mix retires the sidecar, and this is the sole
            // place that does: it holds the only copy of the captured Mac
            // audio, so deleting it on the failure path too would turn a
            // transient error — a full disk, a lost file handle — into
            // permanent loss of half the recording. A preserved sidecar has no
            // automatic consumer; it is a salvage window, swept at launch by
            // `InterruptedRecordingRecovery` once the window has passed.
            try? FileManager.default.removeItem(at: systemJournalURL)
            return .init(
                journalURL: stagedURL,
                peaks: result.peaks,
                firstSystemFrame: result.firstSystemFrame,
                fallbackReason: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            return .init(
                journalURL: microphoneURL,
                peaks: microphonePeaks,
                firstSystemFrame: nil,
                fallbackReason: .mixFailed
            )
        }
    }
}

enum UniversalRecordingFileMixError: Error {
    case invalidMicrophoneJournal
    case invalidSystemJournal
    case invalidOutput
}

/// Streaming offline render. The microphone journal is read-only, output is
/// staged separately, and the staged CAF is reopened and length-validated
/// before RecorderService may choose it for finalization.
enum UniversalRecordingFileMixer {
    static func render(
        microphoneURL: URL,
        systemJournalURL: URL,
        stagedURL: URL,
        configuration: UniversalRecordingMixConfiguration = .init()
    ) throws -> UniversalRecordingFileMixResult {
        let microphone = try AVAudioFile(forReading: microphoneURL)
        guard microphone.length > 0,
              microphone.processingFormat.commonFormat == .pcmFormatFloat32,
              !microphone.processingFormat.isInterleaved,
              microphone.processingFormat.channelCount == 1,
              abs(microphone.processingFormat.sampleRate - 44_100) < 0.5 else {
            throw UniversalRecordingFileMixError.invalidMicrophoneJournal
        }
        let totalFrames = Int64(microphone.length)
        let sparse = try SparseSystemAudioReader(url: systemJournalURL)
        guard let firstChunk = try sparse.nextChunk() else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }

        try? FileManager.default.removeItem(at: stagedURL)
        let output = try AVAudioFile(
            forWriting: stagedURL,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = microphone.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let microphoneBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else { throw UniversalRecordingFileMixError.invalidOutput }

        var pending: (chunk: UniversalRecordingAudioChunk, offset: Int)? = (firstChunk, 0)
        var microphoneFrame: Int64 = 0
        var blend: Float = 0
        let blendStep = 1 / Float(configuration.transitionFrames)
        var releaseSystemSample: Float = 0
        var waveform = WaveformBuilder(sampleRate: format.sampleRate)
        var firstSystemFrame: Int64?

        while microphone.framePosition < microphone.length {
            microphoneBuffer.frameLength = 0
            try microphone.read(into: microphoneBuffer, frameCount: capacity)
            let count = Int(microphoneBuffer.frameLength)
            guard count > 0,
                  let microphoneSamples = microphoneBuffer.floatChannelData?[0],
                  let outputSamples = outputBuffer.floatChannelData?[0] else { break }
            outputBuffer.frameLength = microphoneBuffer.frameLength
            var systemSamples = [Float](repeating: 0, count: count)
            var systemPresent = [Bool](repeating: false, count: count)
            let blockEnd = microphoneFrame + Int64(count)

            while let current = pending {
                let chunk = current.chunk
                let remainingStart = chunk.startFrame + Int64(current.offset)
                let (remainingEnd, overflow) = chunk.startFrame.addingReportingOverflow(
                    Int64(chunk.samples.count)
                )
                guard !overflow else {
                    throw UniversalRecordingFileMixError.invalidSystemJournal
                }
                if remainingEnd <= microphoneFrame {
                    pending = try sparse.nextChunk().map { ($0, 0) }
                    continue
                }
                if remainingStart >= blockEnd { break }

                let copyStart = max(remainingStart, microphoneFrame)
                let copyEnd = min(remainingEnd, blockEnd)
                let sourceOffset = Int(copyStart - chunk.startFrame)
                let destinationOffset = Int(copyStart - microphoneFrame)
                let copyCount = Int(copyEnd - copyStart)
                guard copyCount > 0 else { break }
                for index in 0..<copyCount {
                    let sample = chunk.samples[sourceOffset + index]
                    guard sample.isFinite, abs(sample) <= 1 else {
                        throw UniversalRecordingFileMixError.invalidSystemJournal
                    }
                    systemSamples[destinationOffset + index] = sample
                    systemPresent[destinationOffset + index] = true
                }
                let consumed = sourceOffset + copyCount
                if consumed >= chunk.samples.count {
                    pending = try sparse.nextChunk().map { ($0, 0) }
                } else {
                    pending = (chunk, consumed)
                    break
                }
            }

            for index in 0..<count {
                let microphoneSample = microphoneSamples[index]
                guard microphoneSample.isFinite, abs(microphoneSample) <= 1 else {
                    throw UniversalRecordingFileMixError.invalidMicrophoneJournal
                }
                let canonicalFrame = microphoneFrame + Int64(index)
                let systemSample = systemSamples[index]
                if systemPresent[index],
                   abs(systemSample) >= configuration.meaningfulSystemAmplitude {
                    if firstSystemFrame == nil { firstSystemFrame = canonicalFrame }
                }
                let shouldMixSystem = systemPresent[index]
                if shouldMixSystem {
                    releaseSystemSample = systemSamples[index]
                    blend = min(1, blend + blendStep)
                } else {
                    blend = max(0, blend - blendStep)
                }
                if blend == 0 {
                    outputSamples[index] = microphoneSample
                    releaseSystemSample = 0
                } else {
                    let microphoneCoefficient = 1
                        + (configuration.microphoneGain - 1) * blend
                    let systemCoefficient = configuration.systemGain * blend
                    // Coefficients are nonnegative and sum to at most one, so
                    // finite normalized inputs cannot clip and no clamp is used.
                    outputSamples[index] = microphoneSample * microphoneCoefficient
                        + releaseSystemSample * systemCoefficient
                }
            }
            try output.write(from: outputBuffer)
            waveform.append(UnsafeBufferPointer(start: outputSamples, count: count))
            microphoneFrame += Int64(count)
        }

        waveform.finish()
        output.close()
        microphone.close()
        // `pending` may already be a valid record wholly beyond the
        // microphone-authoritative EOF. Drain the rest of the sparse stream so
        // a corrupt or overlapping trailing record cannot escape validation
        // merely because it would not contribute an output sample.
        while try sparse.nextChunk() != nil {}
        guard microphoneFrame == totalFrames, let firstSystemFrame else {
            throw UniversalRecordingFileMixError.invalidOutput
        }
        let validation = try AVAudioFile(forReading: stagedURL)
        let validatedLength = Int64(validation.length)
        let validatedFormat = validation.processingFormat
        validation.close()
        guard validatedLength == totalFrames,
              validatedFormat.channelCount == 1,
              abs(validatedFormat.sampleRate - 44_100) < 0.5 else {
            throw UniversalRecordingFileMixError.invalidOutput
        }
        return .init(
            frames: totalFrames,
            peaks: waveform.peaks,
            firstSystemFrame: firstSystemFrame
        )
    }
}

private final class SparseSystemAudioReader {
    private let handle: FileHandle
    private var previousEnd: Int64?

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        guard try handle.readExactly(SparseSystemAudioJournal.magic.count)
            == SparseSystemAudioJournal.magic else {
            try? handle.close()
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
    }

    deinit { try? handle.close() }

    func nextChunk() throws -> UniversalRecordingAudioChunk? {
        guard let firstByte = try handle.read(upToCount: 1), !firstByte.isEmpty else { return nil }
        var header = firstByte
        header.append(try handle.readExactly(11))
        guard header.count == 12 else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let startFrame = header.littleEndianInt64(at: 0)
        let count = Int(header.littleEndianUInt32(at: 8))
        let (_, frameEndOverflow) = startFrame.addingReportingOverflow(Int64(count))
        guard startFrame >= 0, count > 0, count <= 1_000_000, !frameEndOverflow else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let endFrame = startFrame + Int64(count)
        if let previousEnd, startFrame < previousEnd {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let payload = try handle.readExactly(count * MemoryLayout<UInt32>.size)
        guard payload.count == count * MemoryLayout<UInt32>.size else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let bits = payload.littleEndianUInt32(at: index * 4)
            let sample = Float(bitPattern: bits)
            guard sample.isFinite, abs(sample) <= 1 else {
                throw UniversalRecordingFileMixError.invalidSystemJournal
            }
            samples.append(sample)
        }
        previousEnd = endFrame
        return .init(startFrame: startFrame, samples: samples)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[self.index(startIndex, offsetBy: offset + index)]) << (index * 8)
        }
        return value
    }

    func littleEndianInt64(at offset: Int) -> Int64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[self.index(startIndex, offsetBy: offset + index)]) << (index * 8)
        }
        return Int64(bitPattern: value)
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let part = try read(upToCount: count - result.count), !part.isEmpty else { break }
            result.append(part)
        }
        return result
    }
}
