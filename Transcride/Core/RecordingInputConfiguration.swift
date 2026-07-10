import Foundation

/// Primitive snapshot of the hardware input feeding a recording engine.
///
/// Kept in Core so configuration-change decisions can be tested without
/// constructing AVAudioEngine/CoreAudio objects.
struct RecordingInputSignature: Equatable, Sendable {
    var deviceID: UInt32?
    var sampleRate: Double
    var channelCount: UInt32
    var deviceIsAvailable: Bool

    var isUsable: Bool {
        guard let deviceID else { return false }
        return deviceID != 0
            && deviceIsAvailable
            && sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
    }

    func isCompatible(with other: RecordingInputSignature) -> Bool {
        isUsable
            && other.isUsable
            && deviceID == other.deviceID
            && channelCount == other.channelCount
            && abs(sampleRate - other.sampleRate) < 0.5
    }
}

enum RecordingConfigurationDecision: Equatable, Sendable {
    /// The input is unchanged and the engine is already accepting buffers.
    case keepRunning
    /// The input is unchanged, but CoreAudio stopped the engine while rebuilding its graph.
    case restartEngine
    /// The input disappeared, changed identity, or changed to an incompatible format.
    case pauseForInputChange

    static func classify(
        baseline: RecordingInputSignature,
        current: RecordingInputSignature,
        engineIsRunning: Bool
    ) -> Self {
        guard baseline.isCompatible(with: current) else {
            return .pauseForInputChange
        }
        return engineIsRunning ? .keepRunning : .restartEngine
    }
}
