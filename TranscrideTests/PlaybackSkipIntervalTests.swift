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
