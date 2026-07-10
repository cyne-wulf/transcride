import Testing

@Suite("Recording input configuration changes")
struct RecordingInputConfigurationTests {
    private let baseline = RecordingInputSignature(
        deviceID: 71,
        sampleRate: 48_000,
        channelCount: 1,
        deviceIsAvailable: true
    )

    @Test func benignNotificationKeepsRunningEngine() {
        #expect(
            RecordingConfigurationDecision.classify(
                baseline: baseline,
                current: baseline,
                engineIsRunning: true
            ) == .keepRunning
        )
    }

    @Test func benignNotificationRestartsStoppedEngine() {
        #expect(
            RecordingConfigurationDecision.classify(
                baseline: baseline,
                current: baseline,
                engineIsRunning: false
            ) == .restartEngine
        )
    }

    @Test func changedDevicePausesRecording() {
        var changed = baseline
        changed.deviceID = 99
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test func changedSampleRatePausesRecording() {
        var changed = baseline
        changed.sampleRate = 44_100
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test func changedChannelCountPausesRecording() {
        var changed = baseline
        changed.channelCount = 2
        #expect(classify(changed) == .pauseForInputChange)
    }

    @Test(arguments: [
        RecordingInputSignature(
            deviceID: nil, sampleRate: 48_000, channelCount: 1, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 0, channelCount: 1, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 48_000, channelCount: 0, deviceIsAvailable: true
        ),
        RecordingInputSignature(
            deviceID: 71, sampleRate: 48_000, channelCount: 1, deviceIsAvailable: false
        ),
    ])
    func invalidCurrentInputPausesRecording(current: RecordingInputSignature) {
        #expect(classify(current) == .pauseForInputChange)
    }

    private func classify(_ current: RecordingInputSignature) -> RecordingConfigurationDecision {
        RecordingConfigurationDecision.classify(
            baseline: baseline,
            current: current,
            engineIsRunning: true
        )
    }
}
