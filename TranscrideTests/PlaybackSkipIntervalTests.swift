import Foundation
import Testing

@Suite("Contextual playback skip interval")
struct PlaybackSkipIntervalTests {
    @Test(
        "Uses the expected interval throughout each duration band",
        arguments: [
            (duration: 0.001, expected: 1),
            (duration: 4.999, expected: 1),
            (duration: 5.0, expected: 2),
            (duration: 14.999, expected: 2),
            (duration: 15.0, expected: 3),
            (duration: 19.999, expected: 3),
            (duration: 20.0, expected: 5),
            (duration: 29.999, expected: 5),
            (duration: 30.0, expected: 10),
            (duration: 59.999, expected: 10),
            (duration: 60.0, expected: 15),
            (duration: 299.999, expected: 15),
            (duration: 300.0, expected: 30),
            (duration: 599.999, expected: 30),
            (duration: 600.0, expected: 60),
            (duration: 3_600.0, expected: 60),
        ]
    )
    func durationBand(duration: Double, expected: Int) {
        #expect(PlaybackSkipInterval.seconds(forClipDuration: duration) == expected)
    }

    @Test func unresolvedOrInvalidDurationsKeepThePreviousInterval() {
        #expect(PlaybackSkipInterval.seconds(forClipDuration: 0) == 15)
        #expect(PlaybackSkipInterval.seconds(forClipDuration: -.infinity) == 15)
        #expect(PlaybackSkipInterval.seconds(forClipDuration: -1) == 15)
        #expect(PlaybackSkipInterval.seconds(forClipDuration: .infinity) == 15)
        #expect(PlaybackSkipInterval.seconds(forClipDuration: .nan) == 15)
    }
}

@Suite("Output latency compensation")
struct PlaybackLatencyCompensationTests {
    private func audible(
        transport: Double,
        anchor: Double = 0,
        latency: Double = 0.2,
        rate: Double = 1,
        isPlaying: Bool = true
    ) -> Double {
        PlaybackLatencyCompensation.audibleTime(
            transport: transport, anchor: anchor, latency: latency,
            rate: rate, isPlaying: isPlaying
        )
    }

    private func isClose(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 1e-9
    }

    @Test func playingAudioIsHeardOneDeviceLatencyBehindTheTransportClock() {
        #expect(isClose(audible(transport: 30), 29.8))
        #expect(isClose(audible(transport: 30, latency: 0.005), 29.995))
    }

    @Test func compensationIsMeasuredInMediaTimeSoItScalesWithRate() {
        // 200 ms of device latency covers 400 ms of a 2x transcript.
        #expect(isClose(audible(transport: 30, rate: 2), 29.6))
        #expect(isClose(audible(transport: 30, rate: 0.5), 29.9))
    }

    @Test func nothingBeforeTheSeekAnchorHasReachedTheDeviceYet() {
        // Immediately after a silence skip to 30 s the highlight holds at the
        // destination instead of jumping a latency backwards into the gap.
        #expect(audible(transport: 30, anchor: 30) == 30)
        #expect(audible(transport: 30.1, anchor: 30) == 30)
        #expect(isClose(audible(transport: 30.25, anchor: 30), 30.05))
        // A stale anchor ahead of the transport clock never pushes it forward.
        #expect(audible(transport: 5, anchor: 90) == 5)
    }

    @Test func pausedPlaybackReportsTheTransportPositionItWillResumeFrom() {
        #expect(audible(transport: 30, isPlaying: false) == 30)
        #expect(audible(transport: 30, anchor: 12, isPlaying: false) == 30)
    }

    @Test func implausibleDeviceReportsAreCappedAndFailuresPassThrough() {
        #expect(isClose(
            audible(transport: 30, latency: 9), 30 - PlaybackLatencyCompensation.maximumLatency
        ))
        // A failed or absent CoreAudio read is exactly the old behavior.
        #expect(audible(transport: 30, latency: 0) == 30)
        #expect(audible(transport: 30, latency: -1) == 30)
        #expect(audible(transport: 30, latency: .nan) == 30)
        #expect(audible(transport: 30, latency: .infinity) == 30)
    }

    @Test func degenerateClockValuesAreNeverAmplified() {
        #expect(audible(transport: .nan).isNaN)
        #expect(isClose(audible(transport: 30, anchor: .nan), 29.8))
        #expect(audible(transport: 30, rate: 0) == 30)
        #expect(audible(transport: 30, rate: .nan) == 30)
        // Early playback cannot report a negative moment.
        #expect(audible(transport: 0.1) == 0)
    }
}
