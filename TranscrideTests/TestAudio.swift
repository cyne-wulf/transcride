import AVFoundation
import Foundation

enum TestAudio {
    /// Writes a mono 44.1 kHz 16-bit WAV of `seconds` filled with a constant
    /// `amplitude` sample — a known signal whose expected peaks are exactly
    /// `amplitude`. Returns the file URL; the caller removes its directory.
    static func makeWAV(
        seconds: Double, amplitude: Float, name: String = "test.wav"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)

        let sampleRate = 44_100.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = amplitude }
        try file.write(from: buffer)
        file.close()
        return url
    }
}
