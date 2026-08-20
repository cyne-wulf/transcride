@preconcurrency import AVFoundation
import Foundation

struct NormalizedRecordingAudio {
    var buffer: AVAudioPCMBuffer
    var peak: Float
}

enum RecordingAudioProcessingError: LocalizedError {
    case unsupportedInputFormat
    case invalidFrameCount
    case nonFiniteSamples
    case bufferAllocationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            "The captured audio format is not supported."
        case .invalidFrameCount:
            "The captured audio buffer reported an invalid frame count."
        case .nonFiniteSamples:
            "The captured audio contained invalid samples."
        case .bufferAllocationFailed:
            "An audio conversion buffer could not be allocated."
        case .conversionFailed(let detail):
            "Captured audio could not be converted: \(detail)"
        }
    }
}

/// `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` derives `frameLength` from
/// the AudioBufferList's byte capacity. Capture APIs such as ScreenCaptureKit
/// can hand out a padded list whose logical sample count is smaller. Keeping
/// the padded tail inserts a discontinuity at every callback boundary, so the
/// media sample count must be applied before normalization.
enum RecordingAudioBufferBounds {
    static func applyLogicalFrameCount(
        _ logicalFrameCount: Int,
        to buffer: AVAudioPCMBuffer
    ) throws {
        guard logicalFrameCount > 0,
              logicalFrameCount <= Int(buffer.frameCapacity),
              let frameCount = AVAudioFrameCount(exactly: logicalFrameCount) else {
            throw RecordingAudioProcessingError.invalidFrameCount
        }
        buffer.frameLength = frameCount
    }
}

/// Converts captured PCM to the recorder's canonical mono format. Channel
/// folding is explicit: AVAudioConverter defaults to remapping channel zero
/// when converting N channels to mono, which produced a real 21-minute silent
/// recording when a three-channel built-in mic exposed silence on channel 0.
final class RecordingAudioNormalizer {
    let targetFormat: AVAudioFormat

    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        precondition(targetFormat.channelCount == 1)
        self.targetFormat = targetFormat
    }

    func normalize(_ input: AVAudioPCMBuffer) throws -> NormalizedRecordingAudio {
        guard input.frameLength > 0,
              input.format.channelCount > 0,
              input.format.sampleRate.isFinite,
              input.format.sampleRate > 0
        else { throw RecordingAudioProcessingError.unsupportedInputFormat }

        let frameCount = Int(input.frameLength)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: input.frameLength
        ), let destination = mono.floatChannelData?[0]
        else { throw RecordingAudioProcessingError.bufferAllocationFailed }
        mono.frameLength = input.frameLength

        let channelCount = Int(input.format.channelCount)
        let isInterleaved = input.format.isInterleaved
        let bytesPerSample: Int
        switch input.format.commonFormat {
        case .pcmFormatFloat32: bytesPerSample = MemoryLayout<Float>.size
        case .pcmFormatFloat64: bytesPerSample = MemoryLayout<Double>.size
        case .pcmFormatInt16: bytesPerSample = MemoryLayout<Int16>.size
        case .pcmFormatInt32: bytesPerSample = MemoryLayout<Int32>.size
        case .otherFormat:
            throw RecordingAudioProcessingError.unsupportedInputFormat
        @unknown default:
            throw RecordingAudioProcessingError.unsupportedInputFormat
        }
        let expectedBytesPerFrame = bytesPerSample * (isInterleaved ? channelCount : 1)
        let streamDescription = input.format.streamDescription
        guard Int(streamDescription.pointee.mBytesPerFrame) == expectedBytesPerFrame else {
            throw RecordingAudioProcessingError.unsupportedInputFormat
        }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input.audioBufferList)
        )
        let expectedBufferCount = isInterleaved ? 1 : channelCount
        let requiredBytes = frameCount * expectedBytesPerFrame
        guard audioBuffers.count == expectedBufferCount,
              audioBuffers.allSatisfy({
                  $0.mData != nil && Int($0.mDataByteSize) >= requiredBytes
              }) else {
            throw RecordingAudioProcessingError.unsupportedInputFormat
        }

        @inline(__always)
        func sample(channel: Int, frame: Int) -> Float {
            let bufferIndex = isInterleaved ? 0 : channel
            let sampleIndex = isInterleaved
                ? frame * channelCount + channel
                : frame
            let data = audioBuffers[bufferIndex].mData!
            switch input.format.commonFormat {
            case .pcmFormatFloat32:
                return data.assumingMemoryBound(to: Float.self)[sampleIndex]
            case .pcmFormatFloat64:
                return Float(data.assumingMemoryBound(to: Double.self)[sampleIndex])
            case .pcmFormatInt16:
                return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex])
                    / 32_768
            case .pcmFormatInt32:
                return Float(Double(data.assumingMemoryBound(to: Int32.self)[sampleIndex])
                    / 2_147_483_648)
            case .otherFormat:
                return 0
            @unknown default:
                return 0
            }
        }
        var foldedPeak: Float = 0
        for channelIndex in 0..<channelCount {
            for frame in 0..<frameCount {
                guard sample(channel: channelIndex, frame: frame).isFinite else {
                    throw RecordingAudioProcessingError.nonFiniteSamples
                }
            }
        }

        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += sample(channel: channelIndex, frame: frame)
            }
            let sample = max(-1, min(1, sum * scale))
            destination[frame] = sample
            foldedPeak = max(foldedPeak, abs(sample))
        }

        guard abs(monoFormat.sampleRate - targetFormat.sampleRate) >= 0.5 else {
            return NormalizedRecordingAudio(buffer: mono, peak: foldedPeak)
        }

        if resampler == nil || resamplerInputFormat != monoFormat {
            guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
                throw RecordingAudioProcessingError.unsupportedInputFormat
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter.primeMethod = .none
            resampler = converter
            resamplerInputFormat = monoFormat
        }
        guard let resampler else {
            throw RecordingAudioProcessingError.unsupportedInputFormat
        }
        let ratio = targetFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(mono.frameLength) * ratio)) + 64
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { throw RecordingAudioProcessingError.bufferAllocationFailed }

        let inputState = ConverterInputState(buffer: mono)
        var conversionError: NSError?
        let status = resampler.convert(to: converted, error: &conversionError) {
            requestedPackets, inputStatus in
            guard let buffer = inputState.take(
                maximumFrames: AVAudioFrameCount(max(1, requestedPackets))
            ) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw RecordingAudioProcessingError.conversionFailed(
                conversionError?.localizedDescription ?? "Unknown conversion error"
            )
        }
        return NormalizedRecordingAudio(buffer: converted, peak: foldedPeak)
    }
}

private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var offset: AVAudioFrameCount = 0
    private var retainedSlice: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(maximumFrames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard offset < buffer.frameLength,
              let source = buffer.floatChannelData?[0] else { return nil }
        let count = min(maximumFrames, buffer.frameLength - offset)
        if offset == 0, count == buffer.frameLength {
            offset = count
            retainedSlice = buffer
            return buffer
        }
        guard let slice = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: count
        ), let destination = slice.floatChannelData?[0] else { return nil }
        slice.frameLength = count
        destination.update(
            from: source.advanced(by: Int(offset)),
            count: Int(count)
        )
        offset += count
        retainedSlice = slice
        return slice
    }
}
