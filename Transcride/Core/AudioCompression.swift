import AVFoundation
import Foundation

struct AudioCompressionInterval: Equatable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

struct AudioCompressionPlan: Equatable, Sendable {
    static let minimumSilenceDuration = 1.5
    static let boundaryPadding = 0.1
    static let analysisWindowDuration = 0.02
    /// -40 dBFS. This is quiet enough to ignore normal room tone while not
    /// treating softly spoken words as silence.
    static let silenceAmplitudeThreshold: Float = 0.01

    var sourceDuration: Double
    var removedIntervals: [AudioCompressionInterval]

    var removedDuration: Double {
        removedIntervals.reduce(0) { $0 + $1.duration }
    }

    var outputDuration: Double { max(0, sourceDuration - removedDuration) }

    var keptIntervals: [AudioCompressionInterval] {
        guard sourceDuration > 0 else { return [] }
        var result: [AudioCompressionInterval] = []
        var cursor = 0.0
        for removed in removedIntervals {
            if removed.start > cursor {
                result.append(.init(start: cursor, end: removed.start))
            }
            cursor = max(cursor, removed.end)
        }
        if cursor < sourceDuration {
            result.append(.init(start: cursor, end: sourceDuration))
        }
        return result.filter { $0.duration > 0 }
    }

    static func make(
        windowPeaks: [Float],
        windowDuration: Double = analysisWindowDuration,
        sourceDuration: Double,
        threshold: Float = silenceAmplitudeThreshold,
        minimumSilenceDuration: Double = minimumSilenceDuration,
        boundaryPadding: Double = boundaryPadding
    ) -> AudioCompressionPlan {
        guard windowDuration > 0, sourceDuration > 0 else {
            return .init(sourceDuration: max(0, sourceDuration), removedIntervals: [])
        }

        var intervals: [AudioCompressionInterval] = []
        var runStart: Int?

        func finishRun(at endIndex: Int) {
            guard let startIndex = runStart else { return }
            let silenceStart = Double(startIndex) * windowDuration
            let silenceEnd = min(sourceDuration, Double(endIndex) * windowDuration)
            if silenceEnd - silenceStart > minimumSilenceDuration {
                let cutStart = min(silenceEnd, silenceStart + boundaryPadding)
                let cutEnd = max(cutStart, silenceEnd - boundaryPadding)
                if cutEnd > cutStart {
                    intervals.append(.init(start: cutStart, end: cutEnd))
                }
            }
            runStart = nil
        }

        for (index, peak) in windowPeaks.enumerated() {
            if peak <= threshold {
                if runStart == nil { runStart = index }
            } else {
                finishRun(at: index)
            }
        }
        finishRun(at: windowPeaks.count)

        return .init(sourceDuration: sourceDuration, removedIntervals: intervals)
    }
}

enum AudioCompressionError: LocalizedError {
    case noAudioTrack
    case cannotRead
    case noLongSilence
    case notSmaller
    case exporterUnavailable
    case invalidOutput(expected: Double, actual: Double)
    case missingTranscriptTiming
    case staleTranscriptTiming
    case malformedTranscriptTiming
    case transcriptRegenerating

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file does not contain a readable audio track."
        case .cannotRead:
            return "The audio could not be decoded for silence detection."
        case .noLongSilence:
            return "No silence longer than 1.5 seconds was found. The audio was left unchanged."
        case .notSmaller:
            return "Removing the detected silence would not make this file smaller. The audio was left unchanged."
        case .exporterUnavailable:
            return "The compressed audio could not be exported on this system."
        case .invalidOutput(let expected, let actual):
            return String(
                format: "The compressed file failed validation (expected %.2f seconds, got %.2f). The original was left unchanged.",
                expected, actual
            )
        case .missingTranscriptTiming:
            return "Speech Transcript needs a timed Original transcript. Transcribe this audio first. The audio was left unchanged."
        case .staleTranscriptTiming:
            return "The Original transcript does not match the current audio yet. Wait for retranscription to finish. The audio was left unchanged."
        case .malformedTranscriptTiming:
            return "The Original transcript has invalid word timing. Retranscribe this audio before using Speech Transcript. The audio was left unchanged."
        case .transcriptRegenerating:
            return "The Original transcript is currently being regenerated. Wait for it to finish before compressing the audio."
        }
    }
}

enum AudioCompressionPreflight {
    static func validate(
        mode: SilenceDetectionMode,
        speechAvailability: SpeechTranscriptAvailability
    ) throws {
        guard mode == .speech else { return }
        switch speechAvailability {
        case .available:
            return
        case .missing:
            throw AudioCompressionError.missingTranscriptTiming
        case .stale:
            throw AudioCompressionError.staleTranscriptTiming
        case .malformed:
            throw AudioCompressionError.malformedTranscriptTiming
        case .regenerating:
            throw AudioCompressionError.transcriptRegenerating
        }
    }
}

enum AudioSilenceAnalyzer {
    static func analyze(_ url: URL) async throws -> AudioCompressionPlan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioCompressionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioCompressionError.cannotRead
        }

        var sampleRate = 44_100.0
        var samplesPerWindow = Int(sampleRate * AudioCompressionPlan.analysisWindowDuration)
        var samplesInWindow = 0
        var windowPeak: Float = 0
        var peaks: [Float] = []
        var scratch: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
               asbd.mSampleRate > 0 {
                sampleRate = asbd.mSampleRate
                samplesPerWindow = max(1, Int(sampleRate * AudioCompressionPlan.analysisWindowDuration))
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            let count = byteCount / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            scratch.withUnsafeMutableBufferPointer { destination in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: byteCount, destination: destination.baseAddress!
                )
            }
            for sample in scratch.prefix(count) {
                windowPeak = max(windowPeak, abs(sample))
                samplesInWindow += 1
                if samplesInWindow == samplesPerWindow {
                    peaks.append(windowPeak)
                    samplesInWindow = 0
                    windowPeak = 0
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? AudioCompressionError.cannotRead
        }
        if samplesInWindow > 0 { peaks.append(windowPeak) }
        return AudioCompressionPlan.make(
            windowPeaks: peaks,
            windowDuration: Double(samplesPerWindow) / sampleRate,
            sourceDuration: duration
        )
    }
}

/// Exact destructive-mode router. Speech preflight is complete before the
/// renderer or trash/swap layer is reached, so every blocked state leaves the
/// source audio untouched.
enum AudioCompressionPlanner {
    static func makePlan(
        mode: SilenceDetectionMode,
        audioURL: URL,
        entryURL: URL
    ) async throws -> AudioCompressionPlan {
        switch mode {
        case .waveform:
            return try await AudioSilenceAnalyzer.analyze(audioURL)
        case .speech:
            if TranscriptAlignmentState.isStale(inEntry: entryURL) {
                throw AudioCompressionError.staleTranscriptTiming
            }
            guard let transcript = TranscriptOriginal.load(
                from: TranscriptOriginal.url(inEntry: entryURL)
            ) else { throw AudioCompressionError.missingTranscriptTiming }
            let duration = try await AudioImportFormat.probeDuration(of: audioURL)
            return try SpeechSilencePlanner.makePlan(
                transcript: transcript, audioDuration: duration
            )
        }
    }
}

enum AudioCompressionRenderer {
    struct Output: Sendable {
        var url: URL
        var duration: Double
        var plan: AudioCompressionPlan
    }

    static func render(sourceURL: URL, plan: AudioCompressionPlan) async throws -> Output {
        guard !plan.removedIntervals.isEmpty else { throw AudioCompressionError.noLongSilence }
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioCompressionError.noAudioTrack
        }
        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioCompressionError.noAudioTrack }

        var destination = CMTime.zero
        for interval in plan.keptIntervals {
            let start = CMTime(seconds: interval.start, preferredTimescale: 44_100)
            let duration = CMTime(seconds: interval.duration, preferredTimescale: 44_100)
            try outputTrack.insertTimeRange(
                CMTimeRange(start: start, duration: duration), of: sourceTrack, at: destination
            )
            destination = destination + duration
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcride-compress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "audio.m4a")
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else { throw AudioCompressionError.exporterUnavailable }
        do {
            try await exporter.export(to: outputURL, as: .m4a)
            let actual = try await AudioImportFormat.probeDuration(of: outputURL)
            let tolerance = max(0.25, plan.keptIntervals.count.doubleValue * 0.05)
            guard abs(actual - plan.outputDuration) <= tolerance else {
                throw AudioCompressionError.invalidOutput(
                    expected: plan.outputDuration, actual: actual
                )
            }
            return .init(url: outputURL, duration: actual, plan: plan)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct AudioCompressionApplier: Sendable {
    let vaultRoot: URL

    struct Outcome: Sendable {
        var trashedName: String
        var audioFileName: String
        var sourceDuration: Double
        var compressedDuration: Double
        var removedDuration: Double
    }

    func apply(
        renderedFileAt renderedURL: URL,
        expectedSourceFileName: String,
        sourceDuration: Double,
        compressedDuration: Double,
        removedDuration: Double,
        toEntryAt entryPath: RelativePath,
        date: Date = Date()
    ) throws -> Outcome {
        let entryURL = vaultRoot.appendingRelativePath(entryPath)
        let visible = ((try? FileManager.default.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard VaultScanner.audioFile(in: visible) == expectedSourceFileName else {
            throw VaultError.notFound(entryPath.appendingComponent(expectedSourceFileName))
        }
        let trash = TrashStore(vaultRoot: vaultRoot)
        let trashedName = try trash.trashPreCompressionAudio(
            atEntryPath: entryPath, deletedAt: date
        )
        let base = (expectedSourceFileName as NSString).deletingPathExtension
        let finalName = (base.isEmpty ? "audio" : base) + ".m4a"
        do {
            try FileManager.default.moveItem(at: renderedURL, to: entryURL.appending(path: finalName))
        } catch {
            if let item = try? trash.items().first(where: { $0.trashedName == trashedName }) {
                _ = try? trash.restore(item)
            }
            throw error
        }
        try? EntryMetadata.setDuration(compressedDuration, inEntry: entryURL)
        try? TranscriptAlignmentState.markStale(inEntry: entryURL)
        return .init(
            trashedName: trashedName,
            audioFileName: finalName,
            sourceDuration: sourceDuration,
            compressedDuration: compressedDuration,
            removedDuration: removedDuration
        )
    }
}

private extension Int {
    var doubleValue: Double { Double(self) }
}
