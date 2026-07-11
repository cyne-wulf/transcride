import AVFoundation
import Foundation

enum RecordingOutputEncoding: Sendable {
    case aac
    case alac

    var fileSettings: [String: Any] {
        switch self {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16,
            ]
        }
    }
}

/// The live journal is deliberately fixed-width PCM. Unlike AAC/ALAC, PCM
/// needs no packet table written during `close()`: after abrupt process death,
/// readers can derive every packet and the duration directly from file size.
enum CrashTolerantAudioJournal {
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Encodes a completed PCM journal to the user's selected M4A quality.
    /// The journal remains untouched unless the caller removes it after this
    /// method returns successfully.
    static func encodeM4A(
        from journalURL: URL,
        to outputURL: URL,
        encoding: RecordingOutputEncoding
    ) throws {
        let input = try AVAudioFile(forReading: journalURL)
        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: encoding.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw RecorderJournalError.bufferAllocationFailed
        }
        while input.framePosition < input.length {
            buffer.frameLength = 0
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        output.close()
        input.close()
    }
}

enum RecorderJournalError: LocalizedError {
    case bufferAllocationFailed

    var errorDescription: String? {
        "The recovery audio buffer could not be allocated."
    }
}
