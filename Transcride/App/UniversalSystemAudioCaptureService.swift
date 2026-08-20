@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The hidden system-audio sidecar is intentionally not an audio file. It is a
/// sparse sequence of canonical mono chunks and their positions on the
/// microphone journal's timeline. Silence before the first useful Mac sound or
/// between useful regions therefore consumes no disk space.
struct UniversalRecordingTimelinePlacement: Equatable, Sendable {
    var startFrame: Int64
    var sourceOffset: Int
    var frameCount: Int
}

/// Lock-guarded bridge between AVAudioEngine host timestamps and the canonical
/// 44.1 kHz microphone journal. ScreenCaptureKit PTS values are converted to
/// the host clock before entering this mapper; callback arrival time is never
/// used as media time.
final class UniversalRecordingTimeline: @unchecked Sendable {
    private struct Anchor {
        var frame: Int64
        var hostSeconds: TimeInterval
    }

    private struct Segment {
        var startFrame: Int64
        var endFrame: Int64?
        var coveredEndFrame: Int64
        var coveredEndHostSeconds: TimeInterval?
        var anchors: [Anchor]
        /// Largest microphone buffer observed in this segment, in canonical
        /// frames. The tap delivers in fixed-size buffers, so this is how far
        /// `coveredEndFrame` routinely lags real time between callbacks.
        var maximumObservedBufferFrames: Int64
    }

    /// Mapping error above which a microphone tap gap is treated as a real
    /// discontinuity rather than device-clock drift. It is also the slack
    /// added to the open segment's projection allowance, so the two can never
    /// drift apart: anything this rule would let Mac audio project past is,
    /// by the same rule, already a segment boundary.
    static let discontinuityTolerance: TimeInterval = 0.05

    private let lock = NSLock()
    private let sampleRate: Double
    private var segments: [Segment] = []
    /// Frame just past the most recently returned placement. The sidecar is an
    /// append-only, strictly ordered journal, so a placement may only ever move
    /// forward; see `placement(forHostTime:sourceFrameCount:)`.
    private var lastPlacedEndFrame: Int64?

    init(sampleRate: Double) {
        precondition(sampleRate.isFinite && sampleRate > 0)
        self.sampleRate = sampleRate
    }

    func beginSegment(atFrame frame: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if let index = segments.indices.last, segments[index].endFrame == nil {
            segments[index].endFrame = max(segments[index].startFrame, frame)
        }
        let startFrame = max(0, frame)
        segments.append(Segment(
            startFrame: startFrame,
            endFrame: nil,
            coveredEndFrame: startFrame,
            coveredEndHostSeconds: nil,
            anchors: [],
            maximumObservedBufferFrames: 0
        ))
    }

    func observeMicrophoneBuffer(
        startFrame: Int64,
        frameCount: Int,
        hostTime: UInt64
    ) {
        guard hostTime > 0, frameCount > 0 else { return }
        let seconds = AVAudioTime.seconds(forHostTime: hostTime)
        guard seconds.isFinite else { return }
        let (endFrame, overflow) = startFrame.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { return }
        let endSeconds = seconds + Double(frameCount) / sampleRate

        lock.lock()
        defer { lock.unlock() }
        guard let index = segments.indices.last,
              segments[index].endFrame == nil,
              startFrame >= segments[index].startFrame else { return }
        if let previous = segments[index].anchors.last {
            guard startFrame >= previous.frame, seconds >= previous.hostSeconds else { return }
            let canonicalElapsed = Double(startFrame - previous.frame) / sampleRate
            let hostElapsed = seconds - previous.hostSeconds
            // A tap discontinuity must not let Mac audio fill wall-clock time
            // that the authoritative microphone journal did not retain. Close
            // the old mapping at the next canonical frame and start a new one
            // at the callback's actual host timestamp. Normal device-clock
            // drift is orders of magnitude below this 50 ms boundary.
            if abs(hostElapsed - canonicalElapsed) > Self.discontinuityTolerance {
                segments[index].endFrame = startFrame
                segments.append(Segment(
                    startFrame: startFrame,
                    endFrame: nil,
                    coveredEndFrame: endFrame,
                    coveredEndHostSeconds: endSeconds,
                    anchors: [Anchor(frame: startFrame, hostSeconds: seconds)],
                    maximumObservedBufferFrames: Int64(frameCount)
                ))
                return
            }
        }
        segments[index].anchors.append(Anchor(frame: startFrame, hostSeconds: seconds))
        segments[index].coveredEndFrame = max(segments[index].coveredEndFrame, endFrame)
        segments[index].coveredEndHostSeconds = max(
            segments[index].coveredEndHostSeconds ?? endSeconds,
            endSeconds
        )
        segments[index].maximumObservedBufferFrames = max(
            segments[index].maximumObservedBufferFrames,
            Int64(frameCount)
        )
    }

    func endSegment(atFrame frame: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = segments.indices.last, segments[index].endFrame == nil else { return }
        segments[index].endFrame = max(segments[index].startFrame, frame)
    }

    /// Maps a ScreenCaptureKit buffer onto the microphone journal's frame
    /// timeline, or returns nil when no retained microphone frames correspond
    /// to it.
    ///
    /// This method is deliberately *stateful*: a returned placement advances
    /// `lastPlacedEndFrame`, which every later placement is trimmed against. It
    /// is called from exactly one place — the ScreenCaptureKit sample handler —
    /// under the same lock as every other timeline mutation.
    ///
    /// The two adjustments it may make are a head trim (drop source frames from
    /// the front, moving `startFrame` *forward*) and a tail clip (shorten
    /// `frameCount`). Neither can move a placement backwards, so successive
    /// placements are strictly non-overlapping and monotonically ordered —
    /// precisely the invariant `SparseSystemAudioJournal.write` enforces, which
    /// would otherwise fail the whole capture with `sidecarWriteFailed` the
    /// first time an anchor rebase mapped a buffer slightly backwards.
    func placement(
        forHostTime hostTime: UInt64,
        sourceFrameCount: Int
    ) -> UniversalRecordingTimelinePlacement? {
        guard hostTime > 0, sourceFrameCount > 0 else { return nil }
        let bufferStart = AVAudioTime.seconds(forHostTime: hostTime)
        guard bufferStart.isFinite else { return nil }
        let bufferEnd = bufferStart + Double(sourceFrameCount) / sampleRate

        lock.lock()
        defer { lock.unlock() }

        for segment in segments.reversed() {
            guard let firstAnchor = segment.anchors.first else { continue }
            let segmentStartTime = firstAnchor.hostSeconds
            guard let coveredEndTime = segment.coveredEndHostSeconds else { continue }
            // `coveredEnd*` only advances when a microphone tap callback runs,
            // and the tap delivers in ~100 ms buffers, so between callbacks it
            // is stale by up to a full buffer. Holding Mac audio to that stale
            // edge drops or clips every buffer that arrives in the gap — and
            // ScreenCaptureKit never re-delivers, while the sidecar rejects
            // backfill — which shreds the track into a comb of silences at the
            // tap cadence. An open segment may therefore be projected one
            // observed buffer plus the discontinuity tolerance past its covered
            // end. A stall larger than that closes the segment instead, so Mac
            // audio still cannot fill wall-clock time the journal never kept.
            let allowance = segment.endFrame == nil
                ? segment.maximumObservedBufferFrames
                    + Int64((Self.discontinuityTolerance * sampleRate).rounded())
                : 0
            let segmentEndTime = coveredEndTime + Double(allowance) / sampleRate
            guard bufferEnd > segmentStartTime, bufferStart < segmentEndTime else { continue }

            let referenceTime = max(bufferStart, segmentStartTime)
            let anchor = segment.anchors.last(where: { $0.hostSeconds <= referenceTime })
                ?? firstAnchor
            let rawStart = anchor.frame
                + Int64(((bufferStart - anchor.hostSeconds) * sampleRate).rounded())
            var sourceOffset = 0
            var placedStart = rawStart
            let lowerBound = max(segment.startFrame, lastPlacedEndFrame ?? Int64.min)
            if placedStart < lowerBound {
                let trim = lowerBound - placedStart
                guard trim < Int64(sourceFrameCount) else { continue }
                sourceOffset = Int(trim)
                placedStart = lowerBound
            }
            let mappedEndFrame = min(
                segment.endFrame ?? Int64.max,
                segment.coveredEndFrame + allowance
            )
            guard placedStart < mappedEndFrame else { continue }
            let count = min(sourceFrameCount - sourceOffset, Int(mappedEndFrame - placedStart))
            guard count > 0 else { continue }
            lastPlacedEndFrame = placedStart + Int64(count)
            return .init(
                startFrame: placedStart,
                sourceOffset: sourceOffset,
                frameCount: count
            )
        }
        return nil
    }
}

enum UniversalSystemAudioCaptureEvent: Sendable {
    case buffer(peak: Float, meaningfulSignal: Bool, uptime: TimeInterval)
    case failed(OptionalSystemAudioFallbackReason)
}

/// ScreenCaptureKit system-audio adapter. It never opens a microphone and its
/// lifecycle is deliberately subordinate to the already-running microphone
/// recorder: every error is reported as an optional-source degradation.
final class UniversalSystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate,
                                                @unchecked Sendable {
    typealias EventHandler = @Sendable (UniversalSystemAudioCaptureEvent) -> Void

    private static let sampleRate: Double = 44_100

    private let queue = DispatchQueue(
        label: "com.ashandevine.transcride.optional-system-audio",
        qos: .userInitiated
    )
    private let canonicalFormat: AVAudioFormat
    private let timeline: UniversalRecordingTimeline
    private let onEvent: EventHandler
    private let journal: SparseSystemAudioJournal
    private var normalizer: RecordingAudioNormalizer

    // Lifecycle fields are touched only by @MainActor methods.
    private var stream: SCStream?
    private var outputAttached = false
    private var startingCapture = false
    private var stopRequested = false
    private var teardownTask: Task<Void, Never>?

    // Callback fields are confined to `queue`.
    private var acceptingSamples = false
    private var stoppingExpectedly = false
    private var synchronizationClock: CMClock?
    private var failureReported = false
    private var startupFailure: OptionalSystemAudioFallbackReason?

    init(
        canonicalFormat: AVAudioFormat,
        timeline: UniversalRecordingTimeline,
        entryURL: URL,
        onEvent: @escaping EventHandler
    ) {
        precondition(canonicalFormat.commonFormat == .pcmFormatFloat32)
        precondition(!canonicalFormat.isInterleaved)
        precondition(canonicalFormat.channelCount == 1)
        precondition(abs(canonicalFormat.sampleRate - Self.sampleRate) < 0.5)
        self.canonicalFormat = canonicalFormat
        self.timeline = timeline
        self.onEvent = onEvent
        self.normalizer = RecordingAudioNormalizer(targetFormat: canonicalFormat)
        self.journal = SparseSystemAudioJournal(
            url: entryURL.appending(path: UniversalRecordingArtifacts.systemAudioFileName)
        )
        super.init()
    }

    /// Returns nil after a usable stream starts. A non-nil reason is only a
    /// system-audio fallback; callers must keep the microphone session active.
    @MainActor
    func start() async -> OptionalSystemAudioFallbackReason? {
        guard !stopRequested else { return .startFailed }
        do {
            let content = try await SCShareableContent.current
            guard !stopRequested, !Task.isCancelled else { return .startFailed }
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: {
                $0.displayID == mainDisplayID
            }) ?? content.displays.first else {
                return .startFailed
            }
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = Int(Self.sampleRate)
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = false

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            outputAttached = true
            guard !stopRequested, !Task.isCancelled else {
                detachOutput(from: stream)
                return .startFailed
            }
            self.stream = stream
            queue.sync {
                acceptingSamples = false
                stoppingExpectedly = false
                failureReported = false
                startupFailure = nil
            }
            startingCapture = true
            do {
                try await stream.startCapture()
            } catch {
                startingCapture = false
                await tearDown(stream: stream)
                return Self.fallbackReason(for: error)
            }
            startingCapture = false
            guard !stopRequested, !Task.isCancelled else {
                await tearDown(stream: stream)
                return .startFailed
            }
            guard let clock = stream.synchronizationClock else {
                await tearDown(stream: stream)
                return .invalidTiming
            }
            let activationFailure: OptionalSystemAudioFallbackReason? = queue.sync {
                if let startupFailure {
                    failureReported = true
                    acceptingSamples = false
                    return startupFailure
                }
                synchronizationClock = clock
                acceptingSamples = true
                return nil
            }
            if let activationFailure {
                await tearDown(stream: stream)
                return activationFailure
            }
            return nil
        } catch {
            return Self.fallbackReason(for: error)
        }
    }

    @MainActor
    func pause() {
        queue.sync { acceptingSamples = false }
    }

    @MainActor
    func resume() {
        queue.sync {
            guard synchronizationClock != nil, !failureReported, !stoppingExpectedly else { return }
            acceptingSamples = true
        }
    }

    /// Stops capture and returns a sparse artifact only if meaningful Mac audio
    /// was observed. If startup is still suspended in TCC, this marks it
    /// cancelled and returns immediately; the start continuation performs its
    /// own explicit teardown before it can accept a sample.
    @MainActor
    func stop(discard: Bool = false) -> URL? {
        stopRequested = true
        queue.sync {
            acceptingSamples = false
            stoppingExpectedly = true
        }

        if let stream {
            // Output removal is synchronous and must never wait behind a TCC or
            // ScreenCaptureKit continuation. `start()` observes stopRequested
            // after every suspension; an already-active stream is stopped by a
            // tracked background task after its output has been detached.
            detachOutput(from: stream)
            if !startingCapture, teardownTask == nil {
                teardownTask = Task { @MainActor [weak self, stream] in
                    try? await stream.stopCapture()
                    guard let self else { return }
                    if self.stream === stream { self.stream = nil }
                }
            }
        }

        let artifact = queue.sync { journal.finish() }
        if discard, let artifact {
            try? FileManager.default.removeItem(at: artifact)
            return nil
        }
        return artifact
    }

    /// Awaited only by the optional-source cleanup chain, never by microphone
    /// finalization. This serializes a future optional capture without making
    /// Stop & Save wait on ScreenCaptureKit.
    @MainActor
    func waitForTeardown() async {
        if let teardownTask { await teardownTask.value }
        teardownTask = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, acceptingSamples, sampleBuffer.isValid else { return }
        do {
            try consume(sampleBuffer)
        } catch let reason as UniversalSystemAudioCaptureFailure {
            fail(reason.fallbackReason)
        } catch {
            fail(.invalidFormat)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in
            guard let self, !self.stoppingExpectedly else { return }
            guard self.synchronizationClock != nil else {
                self.startupFailure = .stalled
                return
            }
            self.fail(.stalled)
        }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer) throws {
        guard let clock = synchronizationClock else {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid, !pts.isIndefinite,
              let description = sampleBuffer.formatDescription else {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        let hostTime = CMSyncConvertTime(
            pts,
            from: clock,
            to: CMClockGetHostTimeClock()
        )
        guard hostTime.isValid, !hostTime.isIndefinite else {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        let hostUnits = CMClockConvertHostTimeToSystemUnits(hostTime)

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let normalized: NormalizedRecordingAudio = try sampleBuffer.withAudioBufferList {
            list, _ in
            guard let borrowed = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: list.unsafePointer
            ) else { throw UniversalSystemAudioCaptureFailure.invalidFormat }
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard let logicalFrameCount = Int(exactly: sampleCount) else {
                throw UniversalSystemAudioCaptureFailure.invalidFormat
            }
            try RecordingAudioBufferBounds.applyLogicalFrameCount(
                logicalFrameCount,
                to: borrowed
            )
            return try normalizer.normalize(borrowed)
        }
        guard normalized.buffer.frameLength > 0,
              let placement = timeline.placement(
                forHostTime: hostUnits,
                sourceFrameCount: Int(normalized.buffer.frameLength)
              ),
              let channel = normalized.buffer.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(
            start: channel.advanced(by: placement.sourceOffset),
            count: placement.frameCount
        ))
        let retainedPeak = samples.reduce(Float.zero) { max($0, abs($1)) }
        do {
            try journal.append(
                samples: samples,
                startFrame: placement.startFrame,
                peak: retainedPeak
            )
        } catch {
            throw UniversalSystemAudioCaptureFailure.sidecarWriteFailed
        }
        onEvent(.buffer(
            peak: retainedPeak,
            meaningfulSignal: retainedPeak >= journal.meaningfulSignalThreshold,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func fail(_ reason: OptionalSystemAudioFallbackReason) {
        guard !failureReported, !stoppingExpectedly else { return }
        failureReported = true
        acceptingSamples = false
        onEvent(.failed(reason))
    }

    @MainActor
    private func tearDown(stream: SCStream) async {
        queue.sync {
            acceptingSamples = false
            stoppingExpectedly = true
        }
        detachOutput(from: stream)
        try? await stream.stopCapture()
        if self.stream === stream { self.stream = nil }
    }

    @MainActor
    private func detachOutput(from stream: SCStream) {
        if outputAttached {
            try? stream.removeStreamOutput(self, type: .audio)
            outputAttached = false
        }
    }

    private static func fallbackReason(for error: Error) -> OptionalSystemAudioFallbackReason {
        let nsError = error as NSError
        // ScreenCaptureKit's public SCStreamErrorUserDeclined raw value.
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            return .permissionDenied
        }
        return .startFailed
    }
}
