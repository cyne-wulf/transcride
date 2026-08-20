import AVFoundation
import Testing

@Suite("Recording audio processing")
struct RecordingAudioProcessingTests {
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    )!

    private func floatFormat(
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool = false
    ) throws -> AVAudioFormat {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerSample * (interleaved ? channels : 1),
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * (interleaved ? channels : 1),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        if channels <= 2 {
            return try #require(AVAudioFormat(streamDescription: &description))
        }
        let layout = try #require(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder
                | AudioChannelLayoutTag(channels)
        ))
        return try #require(AVAudioFormat(
            streamDescription: &description,
            channelLayout: layout
        ))
    }

    private func int16Format(
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool
    ) throws -> AVAudioFormat {
        try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ))
    }

    @Test func foldsEveryDiscreteInputChannelIntoMono() throws {
        let source = try floatFormat(sampleRate: 44_100, channels: 3)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 256))
        input.frameLength = 256
        let channels = try #require(input.floatChannelData)
        for frame in 0..<256 {
            channels[0][frame] = 0
            channels[1][frame] = 0.6
            channels[2][frame] = 0.3
        }

        let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
        let mono = try #require(result.buffer.floatChannelData?[0])
        #expect(result.buffer.frameLength == 256)
        #expect(abs(mono[0] - 0.3) < 0.000_1)
        #expect(abs(result.peak - 0.3) < 0.000_1)
    }

    @Test func signalOnEveryPossibleChannelSurvivesDownmix() throws {
        let source = try floatFormat(sampleRate: 44_100, channels: 3)
        for activeChannel in 0..<3 {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 64))
            input.frameLength = 64
            let channels = try #require(input.floatChannelData)
            for channel in 0..<3 {
                for frame in 0..<64 {
                    channels[channel][frame] = channel == activeChannel ? 0.6 : 0
                }
            }

            let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
            let mono = try #require(result.buffer.floatChannelData?[0])
            #expect(abs(mono[0] - 0.2) < 0.000_1)
            #expect(abs(result.peak - 0.2) < 0.000_1)
        }
    }

    @Test func resamplesFoldedAudioToJournalFormat() throws {
        let source = try floatFormat(sampleRate: 48_000, channels: 3)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4_800))
        input.frameLength = 4_800
        let channels = try #require(input.floatChannelData)
        for frame in 0..<4_800 {
            channels[0][frame] = 0
            channels[1][frame] = 0.2
            channels[2][frame] = 0.4
        }

        let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
        #expect(result.buffer.format.sampleRate == 44_100)
        #expect(result.buffer.format.channelCount == 1)
        #expect(result.buffer.frameLength > 4_350)
        #expect(result.buffer.frameLength < 4_480)
        #expect(result.peak > 0.19)
    }

    @Test func successiveResampledBuffersStayContinuous() throws {
        let source = try floatFormat(sampleRate: 48_000, channels: 1)
        let normalizer = RecordingAudioNormalizer(targetFormat: target)
        var output: [Float] = []

        for _ in 0..<20 {
            let input = try #require(AVAudioPCMBuffer(
                pcmFormat: source,
                frameCapacity: 2_560
            ))
            input.frameLength = 2_560
            let channel = try #require(input.floatChannelData?[0])
            for frame in 0..<2_560 { channel[frame] = 0.25 }

            let result = try normalizer.normalize(input)
            let normalized = try #require(result.buffer.floatChannelData?[0])
            output.append(contentsOf: UnsafeBufferPointer(
                start: normalized,
                count: Int(result.buffer.frameLength)
            ))
        }

        // Twenty 2,560-frame buffers at 48 kHz span exactly 47,040 frames at
        // 44.1 kHz. More importantly, no callback boundary may insert a
        // one-frame dropout into otherwise constant audio.
        #expect(abs(output.count - 47_040) <= 2)
        let steadyState = output.dropFirst(64)
        #expect(steadyState.allSatisfy { abs($0 - 0.25) < 0.01 })
    }

    @Test func foldsInterleavedFloatInput() throws {
        let source = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: true
        ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 64))
        input.frameLength = 64
        let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let samples = try #require(
            buffers[0].mData?.assumingMemoryBound(to: Float.self)
        )
        for frame in 0..<64 {
            samples[frame * 2] = 0
            samples[frame * 2 + 1] = 0.5
        }

        let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
        let mono = try #require(result.buffer.floatChannelData?[0])
        #expect(abs(mono[0] - 0.25) < 0.000_1)
        #expect(abs(result.peak - 0.25) < 0.000_1)
    }

    @Test func logicalFrameCountExcludesPaddedCaptureTail() throws {
        let source = try floatFormat(sampleRate: 44_100, channels: 1)
        let input = try #require(AVAudioPCMBuffer(
            pcmFormat: source,
            frameCapacity: 8
        ))
        input.frameLength = 8
        let channel = try #require(input.floatChannelData?[0])
        for frame in 0..<5 { channel[frame] = 0.25 }
        for frame in 5..<8 { channel[frame] = 1 }

        try RecordingAudioBufferBounds.applyLogicalFrameCount(5, to: input)
        let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
        let mono = try #require(result.buffer.floatChannelData?[0])

        #expect(input.frameLength == 5)
        #expect(result.buffer.frameLength == 5)
        #expect((0..<5).allSatisfy { abs(mono[$0] - 0.25) < 0.000_1 })
        #expect(abs(result.peak - 0.25) < 0.000_1)
        #expect(throws: RecordingAudioProcessingError.self) {
            try RecordingAudioBufferBounds.applyLogicalFrameCount(9, to: input)
        }
    }

    @Test func foldsNativeInt16InputFormats() throws {
        for interleaved in [false, true] {
            let source = try int16Format(
                sampleRate: 44_100,
                channels: 2,
                interleaved: interleaved
            )
            let input = try #require(AVAudioPCMBuffer(
                pcmFormat: source,
                frameCapacity: 64
            ))
            input.frameLength = 64
            let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            if interleaved {
                let samples = try #require(
                    buffers[0].mData?.assumingMemoryBound(to: Int16.self)
                )
                for frame in 0..<64 {
                    samples[frame * 2] = 0
                    samples[frame * 2 + 1] = 16_384
                }
            } else {
                let silent = try #require(
                    buffers[0].mData?.assumingMemoryBound(to: Int16.self)
                )
                let active = try #require(
                    buffers[1].mData?.assumingMemoryBound(to: Int16.self)
                )
                for frame in 0..<64 {
                    silent[frame] = 0
                    active[frame] = 16_384
                }
            }

            let result = try RecordingAudioNormalizer(targetFormat: target).normalize(input)
            let mono = try #require(result.buffer.floatChannelData?[0])
            #expect(result.buffer.frameLength == 64)
            #expect(abs(mono[0] - 0.25) < 0.000_1)
            #expect(abs(result.peak - 0.25) < 0.000_1)
        }
    }
}
