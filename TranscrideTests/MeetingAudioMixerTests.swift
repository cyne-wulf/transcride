import Testing

@Suite("Meeting audio mixer")
struct MeetingAudioMixerTests {
    @Test func alignsInputsByTimestampInsteadOfCallbackOrder() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 4)

        #expect(mixer.append(
            source: .microphone,
            samples: [0.5, 0.5, 0.5, 0.5],
            startFrame: 100
        ).isEmpty)
        #expect(mixer.append(
            source: .system,
            samples: [0.25, 0.25, 0.25, 0.25],
            startFrame: 100
        ).isEmpty)

        let ready = mixer.append(
            source: .system,
            samples: [0.25, 0.25, 0.25, 0.25],
            startFrame: 104
        )
        #expect(ready == [[0.75, 0.75, 0.75, 0.75]])

        #expect(mixer.append(
            source: .microphone,
            samples: [0.5, 0.5, 0.5, 0.5],
            startFrame: 104
        ).isEmpty)
        #expect(mixer.flush() == [[0.75, 0.75, 0.75, 0.75]])
    }

    @Test func preservesSoloInputAndFillsTimelineGapsWithZero() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 4)

        #expect(mixer.append(
            source: .microphone,
            samples: [0.3, 0.3, 0.3, 0.3],
            startFrame: 0
        ).isEmpty)
        let ready = mixer.append(
            source: .microphone,
            samples: [0.6, 0.6, 0.6, 0.6],
            startFrame: 8
        )

        #expect(ready == [
            [0.3, 0.3, 0.3, 0.3],
            [0, 0, 0, 0],
        ])
        #expect(mixer.flush() == [[0.6, 0.6, 0.6, 0.6]])
    }

    @Test func interpolatesOnlyASingleMissingSourceFrame() {
        var oneFrameGap = MeetingAudioMixer(chunkFrames: 6, reorderFrames: 0)
        _ = oneFrameGap.append(
            source: .system,
            samples: [0.4, 0.4],
            startFrame: 0
        )
        let repaired = oneFrameGap.append(
            source: .system,
            samples: [0.4, 0.4, 0.4],
            startFrame: 3
        )
        #expect(repaired == [[0.4, 0.4, 0.4, 0.4, 0.4, 0.4]])

        var twoFrameGap = MeetingAudioMixer(chunkFrames: 6, reorderFrames: 0)
        _ = twoFrameGap.append(
            source: .microphone,
            samples: [0.4, 0.4],
            startFrame: 0
        )
        let preservedSilence = twoFrameGap.append(
            source: .microphone,
            samples: [0.4, 0.4],
            startFrame: 4
        )
        #expect(preservedSilence == [[0.4, 0.4, 0, 0, 0.4, 0.4]])
    }

    @Test func sumsAtUnityAndLimitsOverlaps() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 4)
        _ = mixer.append(
            source: .system,
            samples: [0.75, -0.8, 0.25, -0.25],
            startFrame: 0
        )
        _ = mixer.append(
            source: .microphone,
            samples: [0.6, -0.7, 0.5, -0.5],
            startFrame: 0
        )

        let ready = mixer.append(
            source: .system,
            samples: [0, 0, 0, 0],
            startFrame: 4
        )
        #expect(ready == [[1, -1, 0.75, -0.75]])
    }

    @Test func ignoresSamplesThatArriveBeyondReorderHorizon() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 4)
        let first = mixer.append(
            source: .system,
            samples: Array(repeating: 0.2, count: 12),
            startFrame: 0
        )
        #expect(first.count == 2)

        let late = mixer.append(
            source: .microphone,
            samples: Array(repeating: 0.9, count: 8),
            startFrame: 0
        )
        #expect(late.isEmpty)
        #expect(mixer.flush() == [[0.2, 0.2, 0.2, 0.2]])
    }

    @Test func keepsPendingStorageBoundedForLargeBuffers() {
        let chunkFrames = 64
        let reorderFrames: Int64 = 128
        var mixer = MeetingAudioMixer(
            chunkFrames: chunkFrames,
            reorderFrames: reorderFrames
        )

        let ready = mixer.append(
            source: .system,
            samples: Array(repeating: 0.1, count: 50_000),
            startFrame: 0
        )

        #expect(ready.allSatisfy { $0.count == chunkFrames })
        #expect(mixer.pendingStoredSampleCount <= Int(reorderFrames) + chunkFrames)
        #expect(mixer.flush().allSatisfy { $0.count == chunkFrames })
    }

    @Test func resetBeginsAnIndependentTimelineSegment() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 8)
        _ = mixer.append(
            source: .system,
            samples: [0.9, 0.9],
            startFrame: 1_000_000
        )
        mixer.resetSegment()

        _ = mixer.append(
            source: .microphone,
            samples: [0.4, 0.4, 0.4],
            startFrame: 10
        )
        #expect(mixer.flush() == [[0.4, 0.4, 0.4, 0]])
    }

    @Test func flushPadsFinalChunkAndClearsState() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 8)
        _ = mixer.append(
            source: .system,
            samples: [0.1, 0.2, 0.3],
            startFrame: 50
        )

        #expect(mixer.flush() == [[0.1, 0.2, 0.3, 0]])
        #expect(mixer.pendingStoredSampleCount == 0)
        #expect(mixer.flush().isEmpty)
    }

    @Test func sanitizesNonFiniteSamples() {
        var mixer = MeetingAudioMixer(chunkFrames: 4, reorderFrames: 0)
        let ready = mixer.append(
            source: .system,
            samples: [.nan, .infinity, -.infinity, 0.25],
            startFrame: 0
        )
        #expect(ready == [[0, 0, 0, 0.25]])
    }
}

@Suite("Universal recording mixer")
struct UniversalRecordingMixerTests {
    private let immediateMix = UniversalRecordingMixer(
        configuration: .init(
            meaningfulSystemAmplitude: 0.1,
            microphoneGain: 0.75,
            systemGain: 0.25,
            transitionFrames: 1
        )
    )

    @Test func noSystemReturnsBitEquivalentMicrophoneAudio() {
        let microphone: [Float] = [
            Float(bitPattern: 0x0000_0001),
            Float(bitPattern: 0x8000_0000),
            -0.75,
            Float.pi,
        ]

        let result = UniversalRecordingMixer().render(
            microphone: microphone,
            systemAudio: .notRequested
        )

        #expect(result.samples.map(\.bitPattern) == microphone.map(\.bitPattern))
        #expect(result.status == .microphoneOnly(.systemNotRequested))
    }

    @Test func everySystemFailureReturnsBitEquivalentMicrophoneAudio() {
        let microphone: [Float] = [-0.25, -0.0, 0.25, 0.75]

        for reason in [
            OptionalSystemAudioFallbackReason.permissionDenied,
            .permissionRestricted,
            .startFailed,
            .stalled,
            .invalidTiming,
            .invalidFormat,
            .sidecarWriteFailed,
            .mixFailed,
            .noMeaningfulAudio,
        ] {
            let result = UniversalRecordingMixer().render(
                microphone: microphone,
                systemAudio: .unavailable(reason)
            )
            #expect(result.samples.map(\.bitPattern) == microphone.map(\.bitPattern))
            #expect(result.status == .microphoneOnly(.systemUnavailable(reason)))
        }
    }

    @Test func digitalSilenceNeverChangesMicrophoneSamples() {
        let microphone: [Float] = [-0.0, 0.2, -0.3, 0.4]
        let result = UniversalRecordingMixer().render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [
                    .init(startFrame: 0, samples: [0, 0.000_9, 0, -0.000_9]),
                ],
                degradation: nil
            )
        )

        #expect(result.samples.map(\.bitPattern) == microphone.map(\.bitPattern))
        #expect(result.status == .microphoneOnly(.noMeaningfulSystemSignal))
    }

    @Test func alignsSystemByTimestampAndIncludesQualifiedPreRoll() {
        let microphone = Array(repeating: Float(0.4), count: 8)
        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [
                    .init(startFrame: 2, samples: [0.01, 0.2, 0.4]),
                ],
                degradation: nil
            )
        )

        #expect(result.samples.count == microphone.count)
        #expect(result.samples[0] == 0.4)
        #expect(result.samples[1] == 0.4)
        #expect(abs(result.samples[2] - 0.3025) < 0.000_01)
        #expect(abs(result.samples[3] - 0.35) < 0.000_01)
        #expect(abs(result.samples[4] - 0.4) < 0.000_01)
        #expect(result.samples[5] == 0.4)
        #expect(result.status == .mixed(
            firstMeaningfulSystemFrame: 3,
            degradation: nil
        ))
    }

    @Test func systemAudioCannotPrependOrExtendTheMicrophoneTimeline() {
        let microphone = Array(repeating: Float(0.4), count: 4)
        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [
                    .init(startFrame: -2, samples: [1, 1, 0.2, 0.2, 0.2, 0.2, 1, 1]),
                ],
                degradation: nil
            )
        )

        #expect(result.samples.count == 4)
        #expect(result.samples.allSatisfy { abs($0 - 0.35) < 0.000_01 })
        #expect(result.status == .mixed(
            firstMeaningfulSystemFrame: 0,
            degradation: nil
        ))
    }

    @Test func fixedLinearHeadroomAvoidsHardClipping() {
        let headroomMixer = UniversalRecordingMixer(
            configuration: .init(
                meaningfulSystemAmplitude: 0.1,
                microphoneGain: 0.75,
                systemGain: 0.20,
                transitionFrames: 1
            )
        )
        let microphone: [Float] = [0.9, -0.9, 1, -1]
        let system: [Float] = [0.8, -0.8, 1, -1]
        let result = headroomMixer.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [.init(startFrame: 0, samples: system)],
                degradation: nil
            )
        )

        let expected: [Float] = [0.835, -0.835, 0.95, -0.95]
        #expect(zip(result.samples, expected).allSatisfy {
            abs($0.0 - $0.1) < 0.000_01
        })
        #expect(result.samples.allSatisfy { abs($0) <= 0.95 })
    }

    @Test func preservesFrameIndicesForSeekAndKaraokeTimelines() {
        let microphone: [Float] = [0, 0.8, 0, 0, 0]
        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [.init(startFrame: 3, samples: [0.4])],
                degradation: nil
            )
        )

        #expect(result.samples.count == microphone.count)
        #expect(result.samples[0] == 0)
        #expect(result.samples[1] == 0.8)
        #expect(result.samples[2] == 0)
        #expect(abs(result.samples[3] - 0.1) < 0.000_01)
        #expect(result.samples[4] == 0)
        #expect(result.status == .mixed(
            firstMeaningfulSystemFrame: 3,
            degradation: nil
        ))
    }

    @Test func transitionEnvelopeRetainsHeadroomWithoutAStepGainChange() {
        let mixer = UniversalRecordingMixer(
            configuration: .init(
                meaningfulSystemAmplitude: 0.1,
                microphoneGain: 0.5,
                systemGain: 0.5,
                transitionFrames: 4
            )
        )
        let result = mixer.render(
            microphone: Array(repeating: 0.8, count: 6),
            systemAudio: .captured(
                chunks: [.init(startFrame: 0, samples: Array(repeating: 0.4, count: 4))],
                degradation: nil
            )
        )

        let expected: [Float] = [0.75, 0.7, 0.65, 0.6, 0.65, 0.7]
        #expect(zip(result.samples, expected).allSatisfy {
            abs($0.0 - $0.1) < 0.000_01
        })
        #expect(result.samples.allSatisfy { abs($0) <= 1 })
    }

    @Test func prolongedSystemSilenceRestoresBitEquivalentMicrophoneAudio() {
        let mixer = UniversalRecordingMixer(
            configuration: .init(
                meaningfulSystemAmplitude: 0.1,
                microphoneGain: 0.75,
                systemGain: 0.20,
                transitionFrames: 2
            )
        )
        let microphone = Array(repeating: Float(0.4), count: 12)
        let result = mixer.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [
                    .init(
                        startFrame: 0,
                        samples: [0.4, 0, 0]
                    ),
                ],
                degradation: nil
            )
        )

        #expect(result.samples.count == microphone.count)
        #expect(result.samples[0] != microphone[0])
        #expect(result.samples[4...].map(\.bitPattern)
            == microphone[4...].map(\.bitPattern))
    }

    @Test func partialTrackCanMixBeforeStallAndReportsDegradation() {
        let microphone = Array(repeating: Float(0.4), count: 6)
        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [.init(startFrame: 1, samples: [0.2, 0.2])],
                degradation: .stalled
            )
        )

        let expected: [Float] = [0.4, 0.35, 0.35, 0.4, 0.4, 0.4]
        #expect(zip(result.samples, expected).allSatisfy {
            abs($0.0 - $0.1) < 0.000_01
        })
        #expect(result.status == .mixed(
            firstMeaningfulSystemFrame: 1,
            degradation: .stalled
        ))
    }

    @Test func invalidSystemTrackFallsBackWithoutTouchingMicrophone() {
        let microphone: [Float] = [-0.0, 0.2, 0.4]
        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: .captured(
                chunks: [.init(startFrame: 0, samples: [0.2, .nan, 0.2])],
                degradation: nil
            )
        )

        #expect(result.samples.map(\.bitPattern) == microphone.map(\.bitPattern))
        #expect(result.status == .microphoneOnly(.invalidSystemSamples))
    }

    @Test func overlappingSystemChunksAreRejectedWithoutTouchingMicrophone() {
        let microphone = Array(repeating: Float.zero, count: 3)
        let systemAudio = UniversalRecordingSystemAudio.captured(
            chunks: [
                .init(startFrame: 0, samples: [0.2, 0.2, 0.2]),
                .init(startFrame: 1, samples: [0.4, 0.4]),
            ],
            degradation: nil
        )

        let result = immediateMix.render(
            microphone: microphone,
            systemAudio: systemAudio
        )
        #expect(result.samples.map(\.bitPattern) == microphone.map(\.bitPattern))
        #expect(result.status == .microphoneOnly(.invalidSystemTimeline))
    }
}
