import Foundation

/// Identifies the two independently timestamped inputs used by meeting mode.
enum MeetingAudioSource: Hashable, Sendable {
    case system
    case microphone
}

/// A bounded, timestamp-aware mixer for two mono streams that share a sample
/// rate. Samples are held briefly so callbacks that arrive out of order can be
/// aligned before a chunk is emitted.
///
/// The mixer deliberately uses absolute frame positions instead of callback
/// order. Its output is nevertheless a gap-free sequence of fixed-size chunks:
/// a missing source contributes zero, while overlapping sources are summed at
/// unity gain and hard-limited to the Float PCM range.
struct MeetingAudioMixer: Sendable {
    let chunkFrames: Int
    let reorderFrames: Int64

    private var systemSamples: [Int64: Float] = [:]
    private var microphoneSamples: [Int64: Float] = [:]
    private var nextOutputFrame: Int64?
    private var furthestObservedEnd: Int64?
    private var hasEmittedInSegment = false
    private var lastSystemFrame: Int64?
    private var lastSystemSample: Float = 0
    private var lastMicrophoneFrame: Int64?
    private var lastMicrophoneSample: Float = 0

    init(chunkFrames: Int = 4_410, reorderFrames: Int64 = 8_820) {
        precondition(chunkFrames > 0, "Meeting audio chunks must contain at least one frame")
        precondition(reorderFrames >= 0, "Meeting audio reorder window cannot be negative")
        self.chunkFrames = chunkFrames
        self.reorderFrames = reorderFrames
    }

    /// The number of actual source samples retained internally. Gaps are not
    /// materialized, and emitted samples are removed immediately.
    var pendingStoredSampleCount: Int {
        systemSamples.count + microphoneSamples.count
    }

    /// Adds mono samples positioned on the capture timeline and returns every
    /// chunk whose reorder window has elapsed.
    ///
    /// Samples older than already-emitted audio are ignored. Duplicate samples
    /// from the same source replace the earlier value rather than being added a
    /// second time.
    mutating func append(
        source: MeetingAudioSource,
        samples: [Float],
        startFrame: Int64
    ) -> [[Float]] {
        guard !samples.isEmpty else { return [] }

        var emitted: [[Float]] = []
        var offset = 0

        // Limit each insertion burst to one output chunk. This keeps retained
        // storage bounded by the reorder horizon even if a caller hands us a
        // very large source buffer.
        while offset < samples.count {
            let sliceEnd = min(samples.count, offset + chunkFrames)
            insert(
                source: source,
                samples: samples,
                range: offset..<sliceEnd,
                startFrame: startFrame
            )
            emitted.append(contentsOf: emitReadyChunks())
            offset = sliceEnd
        }

        return emitted
    }

    /// Emits the remainder of the current segment, padding its final chunk
    /// with zeros, and resets timeline state. This is suitable for Stop and for
    /// closing a segment at Pause before callbacks with a later timestamp resume.
    mutating func flush() -> [[Float]] {
        guard let finalEnd = furthestObservedEnd else {
            resetSegment()
            return []
        }

        var emitted: [[Float]] = []
        while let nextOutputFrame, nextOutputFrame < finalEnd {
            emitted.append(emitOneChunk())
        }
        resetSegment()
        return emitted
    }

    /// Starts an independent timeline segment and discards any withheld audio.
    /// Call `flush()` first when the pending tail should be preserved.
    mutating func resetSegment() {
        systemSamples.removeAll(keepingCapacity: true)
        microphoneSamples.removeAll(keepingCapacity: true)
        nextOutputFrame = nil
        furthestObservedEnd = nil
        hasEmittedInSegment = false
        lastSystemFrame = nil
        lastSystemSample = 0
        lastMicrophoneFrame = nil
        lastMicrophoneSample = 0
    }

    private mutating func insert(
        source: MeetingAudioSource,
        samples: [Float],
        range: Range<Int>,
        startFrame: Int64
    ) {
        for index in range {
            let (frame, frameOverflow) = startFrame.addingReportingOverflow(Int64(index))
            guard !frameOverflow else { break }
            let (frameEnd, endOverflow) = frame.addingReportingOverflow(1)
            guard !endOverflow else { break }

            if hasEmittedInSegment, let nextOutputFrame, frame < nextOutputFrame {
                continue
            }

            if nextOutputFrame == nil {
                nextOutputFrame = frame
            } else if !hasEmittedInSegment, frame < nextOutputFrame! {
                nextOutputFrame = frame
            }

            let sample = samples[index].isFinite ? samples[index] : 0
            switch source {
            case .system:
                systemSamples[frame] = sample
            case .microphone:
                microphoneSamples[frame] = sample
            }
            if furthestObservedEnd == nil || frameEnd > furthestObservedEnd! {
                furthestObservedEnd = frameEnd
            }
        }
    }

    private mutating func emitReadyChunks() -> [[Float]] {
        guard let furthestObservedEnd else { return [] }
        let watermark: Int64
        let (candidate, underflow) = furthestObservedEnd.subtractingReportingOverflow(reorderFrames)
        watermark = underflow ? Int64.min : candidate

        var emitted: [[Float]] = []
        while canEmitFullChunk(endingAtOrBefore: watermark) {
            emitted.append(emitOneChunk())
        }
        return emitted
    }

    private func canEmitFullChunk(endingAtOrBefore watermark: Int64) -> Bool {
        guard let nextOutputFrame else { return false }
        let (chunkEnd, overflow) = nextOutputFrame.addingReportingOverflow(Int64(chunkFrames))
        return !overflow && chunkEnd <= watermark
    }

    private mutating func emitOneChunk() -> [Float] {
        guard let startFrame = nextOutputFrame else { return [] }

        var chunk = Array(repeating: Float.zero, count: chunkFrames)
        for offset in 0..<chunkFrames {
            let (frame, overflow) = startFrame.addingReportingOverflow(Int64(offset))
            guard !overflow else { break }

            let system = Self.consumeSample(
                samples: &systemSamples,
                lastFrame: &lastSystemFrame,
                lastSample: &lastSystemSample,
                at: frame
            )
            let microphone = Self.consumeSample(
                samples: &microphoneSamples,
                lastFrame: &lastMicrophoneFrame,
                lastSample: &lastMicrophoneSample,
                at: frame
            )
            chunk[offset] = min(1, max(-1, system + microphone))
        }

        let (next, overflow) = startFrame.addingReportingOverflow(Int64(chunkFrames))
        nextOutputFrame = overflow ? nil : next
        hasEmittedInSegment = true
        return chunk
    }

    /// Repairs only a single missing frame bracketed by real adjacent samples
    /// from the same source. Independent timestamp rounding can otherwise turn
    /// a sub-frame callback boundary into an audible zero-sample click. Larger
    /// gaps remain silence and reset continuity rather than inventing audio.
    private static func consumeSample(
        samples: inout [Int64: Float],
        lastFrame: inout Int64?,
        lastSample: inout Float,
        at frame: Int64
    ) -> Float {
        if let sample = samples.removeValue(forKey: frame) {
            lastFrame = frame
            lastSample = sample
            return sample
        }

        let (previousFrame, previousOverflow) = frame.subtractingReportingOverflow(1)
        let (nextFrame, nextOverflow) = frame.addingReportingOverflow(1)
        if !previousOverflow,
           !nextOverflow,
           lastFrame == previousFrame,
           let nextSample = samples[nextFrame] {
            let interpolated = (lastSample + nextSample) * 0.5
            lastFrame = frame
            lastSample = interpolated
            return interpolated
        }

        lastFrame = nil
        lastSample = 0
        return 0
    }
}

// MARK: - Source-separated universal recording render

/// A block of already-normalized mono system audio positioned on the
/// microphone recording's frame timeline. Frame zero is the first microphone
/// frame; samples before zero or beyond the microphone are intentionally
/// ignored because the microphone is authoritative for recording duration.
/// Capture-clock timestamps must be mapped onto these journal frame indices
/// before rendering; this oracle never invents frames for wall-clock gaps.
struct UniversalRecordingAudioChunk: Equatable, Sendable {
    var startFrame: Int64
    var samples: [Float]

    init(startFrame: Int64, samples: [Float]) {
        self.startFrame = startFrame
        self.samples = samples
    }
}

/// The optional system-audio artifact available when a source-separated
/// recording is finalized. A degraded track may still contain useful audio
/// captured before a stall; an unavailable track has nothing safe to mix.
enum UniversalRecordingSystemAudio: Equatable, Sendable {
    case notRequested
    case unavailable(OptionalSystemAudioFallbackReason)
    case captured(
        chunks: [UniversalRecordingAudioChunk],
        degradation: OptionalSystemAudioFallbackReason?
    )
}

enum UniversalRecordingMicrophoneOnlyReason: Equatable, Sendable {
    case emptyMicrophone
    case systemNotRequested
    case systemUnavailable(OptionalSystemAudioFallbackReason)
    case noSystemFrames
    case noMeaningfulSystemSignal
    case invalidSystemSamples
    case invalidSystemTimeline
}

enum UniversalRecordingMixStatus: Equatable, Sendable {
    case microphoneOnly(UniversalRecordingMicrophoneOnlyReason)
    case mixed(
        firstMeaningfulSystemFrame: Int64,
        degradation: OptionalSystemAudioFallbackReason?
    )
}

struct UniversalRecordingMixResult: Equatable, Sendable {
    var samples: [Float]
    var status: UniversalRecordingMixStatus
}

/// Deterministic gains used only while an eligible system-audio sample is
/// present. Their sum cannot exceed one, which provides linear headroom for
/// worst-case in-phase inputs without introducing a hard clipper. The short
/// transition envelope prevents gain discontinuities at track starts, ends,
/// and capture gaps. Production sparse chunks are already qualified by the
/// bounded pre-roll/release journal, so every present sample is eligible.
struct UniversalRecordingMixConfiguration: Equatable, Sendable {
    let meaningfulSystemAmplitude: Float
    let microphoneGain: Float
    let systemGain: Float
    let transitionFrames: Int

    init(
        meaningfulSystemAmplitude: Float = 0.001,
        microphoneGain: Float = 0.75,
        systemGain: Float = 0.20,
        transitionFrames: Int = 128
    ) {
        precondition(
            meaningfulSystemAmplitude.isFinite
                && meaningfulSystemAmplitude > 0
                && meaningfulSystemAmplitude <= 1,
            "Meaningful system amplitude must be in (0, 1]"
        )
        precondition(
            microphoneGain.isFinite
                && systemGain.isFinite
                && microphoneGain >= 0
                && systemGain >= 0
                && microphoneGain + systemGain <= 1,
            "Universal recording gains must be nonnegative and sum to at most one"
        )
        precondition(transitionFrames > 0, "A mix transition must contain frames")
        self.meaningfulSystemAmplitude = meaningfulSystemAmplitude
        self.microphoneGain = microphoneGain
        self.systemGain = systemGain
        self.transitionFrames = transitionFrames
    }
}

/// Offline renderer for source-separated universal recordings.
///
/// The microphone fixes output length and is the base value at every frame.
/// System timestamps can neither prepend, append, nor fill microphone gaps. If
/// usable system audio is unavailable (including permission/start failures),
/// or never crosses the meaningful-signal threshold, the microphone array is
/// returned directly so every Float bit pattern remains unchanged.
struct UniversalRecordingMixer: Sendable {
    let configuration: UniversalRecordingMixConfiguration

    init(configuration: UniversalRecordingMixConfiguration = .init()) {
        self.configuration = configuration
    }

    func render(
        microphone: [Float],
        systemAudio: UniversalRecordingSystemAudio
    ) -> UniversalRecordingMixResult {
        guard !microphone.isEmpty else {
            return .init(
                samples: microphone,
                status: .microphoneOnly(.emptyMicrophone)
            )
        }

        let chunks: [UniversalRecordingAudioChunk]
        let degradation: OptionalSystemAudioFallbackReason?
        switch systemAudio {
        case .notRequested:
            return microphoneOnly(microphone, reason: .systemNotRequested)
        case .unavailable(let reason):
            return microphoneOnly(microphone, reason: .systemUnavailable(reason))
        case .captured(let capturedChunks, let capturedDegradation):
            guard !capturedChunks.isEmpty else {
                return microphoneOnly(microphone, reason: .noSystemFrames)
            }
            chunks = capturedChunks
            degradation = capturedDegradation
        }

        // `nil` distinguishes a capture gap from a real zero sample. Production
        // journals reject overlap because a bounded streaming renderer cannot
        // revise an already-emitted block; the deterministic oracle enforces
        // that same contract.
        var alignedSystem = Array<Float?>(repeating: nil, count: microphone.count)
        let orderedChunks = chunks
            .filter { !$0.samples.isEmpty }
            .sorted { $0.startFrame < $1.startFrame }
        guard !orderedChunks.isEmpty else {
            return microphoneOnly(microphone, reason: .noSystemFrames)
        }
        var previousEnd: Int64?
        var hasAlignedFrames = false
        for chunk in orderedChunks {
            let (chunkEnd, overflow) = chunk.startFrame.addingReportingOverflow(
                Int64(chunk.samples.count)
            )
            guard !overflow,
                  previousEnd.map({ chunk.startFrame >= $0 }) ?? true else {
                return microphoneOnly(microphone, reason: .invalidSystemTimeline)
            }
            previousEnd = chunkEnd
            for (sampleOffset, sample) in chunk.samples.enumerated() {
                let (frame, overflow) = chunk.startFrame.addingReportingOverflow(
                    Int64(sampleOffset)
                )
                guard !overflow else { break }
                guard frame >= 0, frame < Int64(microphone.count) else { continue }
                guard sample.isFinite, abs(sample) <= 1 else {
                    return microphoneOnly(microphone, reason: .invalidSystemSamples)
                }
                alignedSystem[Int(frame)] = sample
                hasAlignedFrames = true
            }
        }
        guard hasAlignedFrames else {
            return microphoneOnly(microphone, reason: .noSystemFrames)
        }

        guard let firstMeaningfulIndex = alignedSystem.firstIndex(where: { sample in
            guard let sample else { return false }
            return abs(sample) >= configuration.meaningfulSystemAmplitude
        }) else {
            return microphoneOnly(microphone, reason: .noMeaningfulSystemSignal)
        }

        var output: [Float] = []
        output.reserveCapacity(microphone.count)
        var blend: Float = 0
        let blendStep = 1 / Float(configuration.transitionFrames)
        var releaseSystemSample: Float = 0

        for frame in microphone.indices {
            let systemSample = alignedSystem[frame]
            let shouldMixSystem = systemSample != nil

            if shouldMixSystem, let systemSample {
                releaseSystemSample = systemSample
                blend = min(1, blend + blendStep)
            } else {
                blend = max(0, blend - blendStep)
            }

            guard blend > 0 else {
                // Do not multiply by 1: preserving the original value also
                // preserves signed zero and every other Float bit pattern.
                output.append(microphone[frame])
                releaseSystemSample = 0
                continue
            }

            let microphoneCoefficient = 1
                + (configuration.microphoneGain - 1) * blend
            let systemCoefficient = configuration.systemGain * blend
            output.append(
                microphone[frame] * microphoneCoefficient
                    + releaseSystemSample * systemCoefficient
            )
        }

        return .init(
            samples: output,
            status: .mixed(
                firstMeaningfulSystemFrame: Int64(firstMeaningfulIndex),
                degradation: degradation
            )
        )
    }

    private func microphoneOnly(
        _ microphone: [Float],
        reason: UniversalRecordingMicrophoneOnlyReason
    ) -> UniversalRecordingMixResult {
        .init(samples: microphone, status: .microphoneOnly(reason))
    }
}
