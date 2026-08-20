import AVFoundation
import Foundation

struct MicrophoneJournalInspection: Equatable, Sendable {
    var frames: Int64
    var hasSignal: Bool

    var terminalState: MicrophoneTerminalCaptureState {
        .classify(frames: frames, hasSignal: hasSignal)
    }
}

struct RecoveredMicrophoneCaptureObservation: Equatable, Sendable {
    var sessionID: UUID?
    var inspection: MicrophoneJournalInspection
}

enum MicrophoneJournalInspectionError: LocalizedError {
    case unreadableAudio

    var errorDescription: String? {
        "The microphone journal could not be inspected."
    }
}

/// Reads bounded chunks and stops at the first canonical sample that could
/// survive the signed-PCM16 crash journal. It never loads a long recording in
/// memory and is shared by every abrupt-crash recovery workflow.
enum MicrophoneJournalInspector {
    static func inspect(_ url: URL) throws -> MicrophoneJournalInspection {
        let input = try AVAudioFile(forReading: url)
        defer { input.close() }
        let totalFrames = Int64(input.length)
        let format = input.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 16_384
              ) else {
            throw MicrophoneJournalInspectionError.unreadableAudio
        }

        var decodedFrames: Int64 = 0
        while input.framePosition < input.length {
            buffer.frameLength = 0
            try input.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            decodedFrames += Int64(frameCount)
            guard let channels = buffer.floatChannelData else {
                throw MicrophoneJournalInspectionError.unreadableAudio
            }
            for channelIndex in 0..<Int(format.channelCount) {
                let samples = UnsafeBufferPointer(
                    start: channels[channelIndex],
                    count: frameCount
                )
                if samples.contains(where: {
                    $0.isFinite
                        && abs($0) >= RecordingCaptureHealthMonitor.signalThreshold
                }) {
                    return .init(frames: totalFrames, hasSignal: true)
                }
            }
        }
        return .init(
            frames: max(totalFrames, decodedFrames),
            hasSignal: false
        )
    }
}
