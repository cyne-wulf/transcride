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
    }

    private let lock = NSLock()
    private let sampleRate: Double
    private var segments: [Segment] = []

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
            anchors: []
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
            if abs(hostElapsed - canonicalElapsed) > 0.05 {
                segments[index].endFrame = startFrame
                segments.append(Segment(
                    startFrame: startFrame,
                    endFrame: nil,
                    coveredEndFrame: endFrame,
                    coveredEndHostSeconds: endSeconds,
                    anchors: [Anchor(frame: startFrame, hostSeconds: seconds)]
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
    }

    func endSegment(atFrame frame: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = segments.indices.last, segments[index].endFrame == nil else { return }
        segments[index].endFrame = max(segments[index].startFrame, frame)
    }

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
            guard let segmentEndTime = segment.coveredEndHostSeconds else { continue }
            guard bufferEnd > segmentStartTime, bufferStart < segmentEndTime else { continue }

            let referenceTime = max(bufferStart, segmentStartTime)
            let anchor = segment.anchors.last(where: { $0.hostSeconds <= referenceTime })
                ?? firstAnchor
            let rawStart = anchor.frame
                + Int64(((bufferStart - anchor.hostSeconds) * sampleRate).rounded())
            var sourceOffset = 0
            var placedStart = rawStart
            if placedStart < segment.startFrame {
                let trim = segment.startFrame - placedStart
                guard trim < Int64(sourceFrameCount) else { continue }
                sourceOffset = Int(trim)
                placedStart = segment.startFrame
            }
            var count = sourceFrameCount - sourceOffset
            let mappedEndFrame = min(
                segment.endFrame ?? segment.coveredEndFrame,
                segment.coveredEndFrame
            )
            guard placedStart < mappedEndFrame else { continue }
            count = min(count, Int(mappedEndFrame - placedStart))
            guard count > 0 else { continue }
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

private enum UniversalSystemAudioCaptureFailure: Error {
    case invalidTiming
    case invalidFormat
    case sidecarWriteFailed

    var fallbackReason: OptionalSystemAudioFallbackReason {
        switch self {
        case .invalidTiming: .invalidTiming
        case .invalidFormat: .invalidFormat
        case .sidecarWriteFailed: .sidecarWriteFailed
        }
    }
}

/// Signal-gated writer with bounded in-memory pre-roll and release hysteresis.
/// The file is created lazily at the first meaningful signal, so ordinary
/// microphone recordings leave no second durable artifact or silent growth.
final class SparseSystemAudioJournal {
    struct Configuration: Equatable, Sendable {
        var meaningfulSignalThreshold: Float = 0.001
        var preRollFrames: Int = 11_025       // 250 ms at 44.1 kHz
        var releaseFrames: Int = 22_050       // 500 ms at 44.1 kHz
    }

    static let magic = Data("TRSYS001".utf8)

    let meaningfulSignalThreshold: Float
    private let url: URL
    private let configuration: Configuration
    private var handle: FileHandle?
    private var preRoll: [UniversalRecordingAudioChunk] = []
    private var preRollFrameCount = 0
    private var releaseFramesRemaining = 0
    private var isActive = false
    private var hasMeaningfulSignal = false
    private var lastRecordEnd: Int64?
    private var finished = false

    init(url: URL, configuration: Configuration = .init()) {
        precondition(configuration.meaningfulSignalThreshold.isFinite)
        precondition(configuration.meaningfulSignalThreshold > 0)
        precondition(configuration.preRollFrames >= 0 && configuration.releaseFrames >= 0)
        self.url = url
        self.configuration = configuration
        self.meaningfulSignalThreshold = configuration.meaningfulSignalThreshold
        try? FileManager.default.removeItem(at: url)
    }

    func append(samples: [Float], startFrame: Int64, peak: Float) throws {
        guard !finished, !samples.isEmpty else { return }
        let (_, frameEndOverflow) = startFrame.addingReportingOverflow(Int64(samples.count))
        guard startFrame >= 0, !frameEndOverflow else {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw UniversalSystemAudioCaptureFailure.invalidFormat
        }
        let chunk = UniversalRecordingAudioChunk(startFrame: startFrame, samples: samples)
        let meaningful = peak.isFinite && peak >= meaningfulSignalThreshold

        if meaningful {
            if !isActive {
                try openIfNeeded()
                for buffered in preRoll { try write(buffered) }
                preRoll.removeAll(keepingCapacity: true)
                preRollFrameCount = 0
            }
            try write(chunk)
            hasMeaningfulSignal = true
            isActive = true
            releaseFramesRemaining = configuration.releaseFrames
            return
        }

        if isActive {
            let retainedCount = min(releaseFramesRemaining, samples.count)
            if retainedCount > 0 {
                try write(.init(
                    startFrame: startFrame,
                    samples: Array(samples.prefix(retainedCount))
                ))
            }
            releaseFramesRemaining -= retainedCount
            if releaseFramesRemaining == 0 {
                isActive = false
                if retainedCount < samples.count {
                    appendToPreRoll(.init(
                        startFrame: startFrame + Int64(retainedCount),
                        samples: Array(samples.dropFirst(retainedCount))
                    ))
                }
            }
        } else {
            appendToPreRoll(chunk)
        }
    }

    func finish() -> URL? {
        guard !finished else { return hasMeaningfulSignal ? url : nil }
        finished = true
        preRoll.removeAll()
        preRollFrameCount = 0
        try? handle?.close()
        handle = nil
        guard hasMeaningfulSignal else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func appendToPreRoll(_ chunk: UniversalRecordingAudioChunk) {
        guard configuration.preRollFrames > 0 else { return }
        preRoll.append(chunk)
        preRollFrameCount += chunk.samples.count
        while preRollFrameCount > configuration.preRollFrames, !preRoll.isEmpty {
            let overflow = preRollFrameCount - configuration.preRollFrames
            if preRoll[0].samples.count <= overflow {
                preRollFrameCount -= preRoll.removeFirst().samples.count
            } else {
                preRoll[0].startFrame += Int64(overflow)
                preRoll[0].samples.removeFirst(overflow)
                preRollFrameCount -= overflow
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        FileManager.default.createFile(atPath: url.path, contents: Self.magic)
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    private func write(_ chunk: UniversalRecordingAudioChunk) throws {
        guard let handle else { throw UniversalSystemAudioCaptureFailure.sidecarWriteFailed }
        let (recordEnd, overflow) = chunk.startFrame.addingReportingOverflow(
            Int64(chunk.samples.count)
        )
        if overflow || lastRecordEnd.map({ chunk.startFrame < $0 }) == true {
            throw UniversalSystemAudioCaptureFailure.invalidTiming
        }
        guard let count = UInt32(exactly: chunk.samples.count) else {
            throw UniversalSystemAudioCaptureFailure.sidecarWriteFailed
        }
        var data = Data(capacity: 12 + chunk.samples.count * MemoryLayout<UInt32>.size)
        data.appendLittleEndian(chunk.startFrame)
        data.appendLittleEndian(count)
        for sample in chunk.samples { data.appendLittleEndian(sample.bitPattern) }
        try handle.write(contentsOf: data)
        lastRecordEnd = recordEnd
    }
}

struct UniversalRecordingFileMixResult: Sendable {
    var frames: Int64
    var peaks: [Float]
    var firstSystemFrame: Int64
}

struct UniversalRecordingFileSelection: Sendable {
    var journalURL: URL
    var peaks: [Float]
    var firstSystemFrame: Int64?
    var fallbackReason: OptionalSystemAudioFallbackReason?
}

/// Production fallback boundary shared with integration tests. Rendering is
/// attempted beside the pristine microphone master; every failure deletes the
/// untrusted stage and returns that master unchanged.
enum UniversalRecordingFileResolver {
    static func renderOrUseMicrophone(
        microphoneURL: URL,
        microphoneFrames: Int64,
        microphonePeaks: [Float],
        systemJournalURL: URL,
        stagedURL: URL
    ) -> UniversalRecordingFileSelection {
        defer { try? FileManager.default.removeItem(at: systemJournalURL) }
        do {
            let result = try UniversalRecordingFileMixer.render(
                microphoneURL: microphoneURL,
                systemJournalURL: systemJournalURL,
                stagedURL: stagedURL
            )
            guard result.frames == microphoneFrames else {
                throw UniversalRecordingFileMixError.invalidOutput
            }
            return .init(
                journalURL: stagedURL,
                peaks: result.peaks,
                firstSystemFrame: result.firstSystemFrame,
                fallbackReason: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            return .init(
                journalURL: microphoneURL,
                peaks: microphonePeaks,
                firstSystemFrame: nil,
                fallbackReason: .mixFailed
            )
        }
    }
}

enum UniversalRecordingFileMixError: Error {
    case invalidMicrophoneJournal
    case invalidSystemJournal
    case invalidOutput
}

/// Streaming offline render. The microphone journal is read-only, output is
/// staged separately, and the staged CAF is reopened and length-validated
/// before RecorderService may choose it for finalization.
enum UniversalRecordingFileMixer {
    static func render(
        microphoneURL: URL,
        systemJournalURL: URL,
        stagedURL: URL,
        configuration: UniversalRecordingMixConfiguration = .init()
    ) throws -> UniversalRecordingFileMixResult {
        let microphone = try AVAudioFile(forReading: microphoneURL)
        guard microphone.length > 0,
              microphone.processingFormat.commonFormat == .pcmFormatFloat32,
              !microphone.processingFormat.isInterleaved,
              microphone.processingFormat.channelCount == 1,
              abs(microphone.processingFormat.sampleRate - 44_100) < 0.5 else {
            throw UniversalRecordingFileMixError.invalidMicrophoneJournal
        }
        let totalFrames = Int64(microphone.length)
        let sparse = try SparseSystemAudioReader(url: systemJournalURL)
        guard let firstChunk = try sparse.nextChunk() else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }

        try? FileManager.default.removeItem(at: stagedURL)
        let output = try AVAudioFile(
            forWriting: stagedURL,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = microphone.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let microphoneBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else { throw UniversalRecordingFileMixError.invalidOutput }

        var pending: (chunk: UniversalRecordingAudioChunk, offset: Int)? = (firstChunk, 0)
        var microphoneFrame: Int64 = 0
        var blend: Float = 0
        let blendStep = 1 / Float(configuration.transitionFrames)
        var releaseSystemSample: Float = 0
        var waveform = WaveformBuilder(sampleRate: format.sampleRate)
        var firstSystemFrame: Int64?

        while microphone.framePosition < microphone.length {
            microphoneBuffer.frameLength = 0
            try microphone.read(into: microphoneBuffer, frameCount: capacity)
            let count = Int(microphoneBuffer.frameLength)
            guard count > 0,
                  let microphoneSamples = microphoneBuffer.floatChannelData?[0],
                  let outputSamples = outputBuffer.floatChannelData?[0] else { break }
            outputBuffer.frameLength = microphoneBuffer.frameLength
            var systemSamples = [Float](repeating: 0, count: count)
            var systemPresent = [Bool](repeating: false, count: count)
            let blockEnd = microphoneFrame + Int64(count)

            while let current = pending {
                let chunk = current.chunk
                let remainingStart = chunk.startFrame + Int64(current.offset)
                let (remainingEnd, overflow) = chunk.startFrame.addingReportingOverflow(
                    Int64(chunk.samples.count)
                )
                guard !overflow else {
                    throw UniversalRecordingFileMixError.invalidSystemJournal
                }
                if remainingEnd <= microphoneFrame {
                    pending = try sparse.nextChunk().map { ($0, 0) }
                    continue
                }
                if remainingStart >= blockEnd { break }

                let copyStart = max(remainingStart, microphoneFrame)
                let copyEnd = min(remainingEnd, blockEnd)
                let sourceOffset = Int(copyStart - chunk.startFrame)
                let destinationOffset = Int(copyStart - microphoneFrame)
                let copyCount = Int(copyEnd - copyStart)
                guard copyCount > 0 else { break }
                for index in 0..<copyCount {
                    let sample = chunk.samples[sourceOffset + index]
                    guard sample.isFinite, abs(sample) <= 1 else {
                        throw UniversalRecordingFileMixError.invalidSystemJournal
                    }
                    systemSamples[destinationOffset + index] = sample
                    systemPresent[destinationOffset + index] = true
                }
                let consumed = sourceOffset + copyCount
                if consumed >= chunk.samples.count {
                    pending = try sparse.nextChunk().map { ($0, 0) }
                } else {
                    pending = (chunk, consumed)
                    break
                }
            }

            for index in 0..<count {
                let microphoneSample = microphoneSamples[index]
                guard microphoneSample.isFinite, abs(microphoneSample) <= 1 else {
                    throw UniversalRecordingFileMixError.invalidMicrophoneJournal
                }
                let canonicalFrame = microphoneFrame + Int64(index)
                let systemSample = systemSamples[index]
                if systemPresent[index],
                   abs(systemSample) >= configuration.meaningfulSystemAmplitude {
                    if firstSystemFrame == nil { firstSystemFrame = canonicalFrame }
                }
                let shouldMixSystem = systemPresent[index]
                if shouldMixSystem {
                    releaseSystemSample = systemSamples[index]
                    blend = min(1, blend + blendStep)
                } else {
                    blend = max(0, blend - blendStep)
                }
                if blend == 0 {
                    outputSamples[index] = microphoneSample
                    releaseSystemSample = 0
                } else {
                    let microphoneCoefficient = 1
                        + (configuration.microphoneGain - 1) * blend
                    let systemCoefficient = configuration.systemGain * blend
                    // Coefficients are nonnegative and sum to at most one, so
                    // finite normalized inputs cannot clip and no clamp is used.
                    outputSamples[index] = microphoneSample * microphoneCoefficient
                        + releaseSystemSample * systemCoefficient
                }
            }
            try output.write(from: outputBuffer)
            waveform.append(UnsafeBufferPointer(start: outputSamples, count: count))
            microphoneFrame += Int64(count)
        }

        waveform.finish()
        output.close()
        microphone.close()
        // `pending` may already be a valid record wholly beyond the
        // microphone-authoritative EOF. Drain the rest of the sparse stream so
        // a corrupt or overlapping trailing record cannot escape validation
        // merely because it would not contribute an output sample.
        while try sparse.nextChunk() != nil {}
        guard microphoneFrame == totalFrames, let firstSystemFrame else {
            throw UniversalRecordingFileMixError.invalidOutput
        }
        let validation = try AVAudioFile(forReading: stagedURL)
        let validatedLength = Int64(validation.length)
        let validatedFormat = validation.processingFormat
        validation.close()
        guard validatedLength == totalFrames,
              validatedFormat.channelCount == 1,
              abs(validatedFormat.sampleRate - 44_100) < 0.5 else {
            throw UniversalRecordingFileMixError.invalidOutput
        }
        return .init(
            frames: totalFrames,
            peaks: waveform.peaks,
            firstSystemFrame: firstSystemFrame
        )
    }
}

private final class SparseSystemAudioReader {
    private let handle: FileHandle
    private var previousEnd: Int64?

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        guard try handle.readExactly(SparseSystemAudioJournal.magic.count)
            == SparseSystemAudioJournal.magic else {
            try? handle.close()
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
    }

    deinit { try? handle.close() }

    func nextChunk() throws -> UniversalRecordingAudioChunk? {
        guard let firstByte = try handle.read(upToCount: 1), !firstByte.isEmpty else { return nil }
        var header = firstByte
        header.append(try handle.readExactly(11))
        guard header.count == 12 else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let startFrame = header.littleEndianInt64(at: 0)
        let count = Int(header.littleEndianUInt32(at: 8))
        let (_, frameEndOverflow) = startFrame.addingReportingOverflow(Int64(count))
        guard startFrame >= 0, count > 0, count <= 1_000_000, !frameEndOverflow else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let endFrame = startFrame + Int64(count)
        if let previousEnd, startFrame < previousEnd {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        let payload = try handle.readExactly(count * MemoryLayout<UInt32>.size)
        guard payload.count == count * MemoryLayout<UInt32>.size else {
            throw UniversalRecordingFileMixError.invalidSystemJournal
        }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let bits = payload.littleEndianUInt32(at: index * 4)
            let sample = Float(bitPattern: bits)
            guard sample.isFinite, abs(sample) <= 1 else {
                throw UniversalRecordingFileMixError.invalidSystemJournal
            }
            samples.append(sample)
        }
        previousEnd = endFrame
        return .init(startFrame: startFrame, samples: samples)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[self.index(startIndex, offsetBy: offset + index)]) << (index * 8)
        }
        return value
    }

    func littleEndianInt64(at offset: Int) -> Int64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[self.index(startIndex, offsetBy: offset + index)]) << (index * 8)
        }
        return Int64(bitPattern: value)
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let part = try read(upToCount: count - result.count), !part.isEmpty else { break }
            result.append(part)
        }
        return result
    }
}
