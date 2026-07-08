import AVFoundation
import Foundation

enum WaveformError: LocalizedError {
    case noAudioTrack
    case cannotRead

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "The file has no audio track."
        case .cannotRead: return "The audio could not be decoded."
        }
    }
}

/// Generates `WaveformData` by decoding an audio file (or the audio track of
/// a video file) with AVAssetReader. Streams in small chunks so a 2-hour file
/// never holds more than one decode buffer in memory. Cancellation-aware:
/// aborts promptly when the surrounding task is cancelled.
enum WaveformGenerator {
    static func generate(fromAudioAt url: URL) async throws -> WaveformData {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }
        let assetDuration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? WaveformError.cannotRead
        }

        var builder: WaveformBuilder?
        var sampleRate: Double = 44100
        var chunk: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            if builder == nil {
                if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                   asbd.mSampleRate > 0 {
                    sampleRate = asbd.mSampleRate
                }
                builder = WaveformBuilder(sampleRate: sampleRate)
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteCount / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            if chunk.count < floatCount { chunk = [Float](repeating: 0, count: floatCount) }
            chunk.withUnsafeMutableBufferPointer { dest in
                _ = CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: byteCount, destination: dest.baseAddress!
                )
            }
            chunk.withUnsafeBufferPointer { all in
                builder?.append(UnsafeBufferPointer(rebasing: all[0..<floatCount]))
            }
        }

        guard reader.status == .completed, var builder else {
            throw reader.error ?? WaveformError.cannotRead
        }
        builder.finish()

        let decodedDuration = Double(builder.sampleCount) / sampleRate
        return WaveformData(
            duration: decodedDuration > 0 ? decodedDuration : assetDuration,
            peaks: builder.peaks
        )
    }
}
