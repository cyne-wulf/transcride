import AVFoundation
import Foundation
import Speech

/// Apple SpeechTranscriber (Speech framework, macOS 26+) — zero-download in
/// the model picker; the OS manages its own model assets, which we ensure are
/// installed right before the first transcription (ENG-1).
@available(macOS 26, *)
actor AppleSpeechEngine: TranscriptionEngine {
    nonisolated let info: TranscriptionModelInfo

    init(info: TranscriptionModelInfo) {
        self.info = info
    }

    // MARK: - Model management (no user-visible download)

    func isDownloaded() -> Bool { true }

    func downloadModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        progress(.downloading(1.0))
    }

    func deleteModel() throws {
        // System assets aren't ours to delete.
    }

    func downloadedByteSize() -> Int64? { nil }

    // MARK: - Transcription

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptOriginal.Segment] {
        let requested = options.languageHint.map(Locale.init(identifier:)) ?? Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.engineFailure(
                "Apple Speech does not support the language \(requested.identifier)."
            )
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // The OS downloads its (small) locale assets on first use.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw TranscriptionError.modelLoadFailed(error.localizedDescription)
            }
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }
        let totalSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Collect results concurrently with the analysis run.
        let collector = Task {
            var segments: [TranscriptOriginal.Segment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let words = Self.words(from: result.text)
                guard !words.isEmpty else { continue }
                segments.append(TranscriptOriginal.Segment(
                    start: words.first!.start, end: words.last!.end,
                    speaker: nil, words: words
                ))
                if totalSeconds > 0, let end = words.last?.end {
                    progress(min(0.999, end / totalSeconds))
                }
            }
            return segments
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }

        let segments: [TranscriptOriginal.Segment]
        do {
            segments = try await collector.value
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        try Task.checkCancellation()
        progress(1.0)
        return segments.sorted { $0.start < $1.start }
    }

    /// Words from a result's attributed text: each `audioTimeRange` run is a
    /// timed token; runs holding several whitespace-separated words get their
    /// time range split linearly so the schema stays word-granular for M4.
    private static func words(from text: AttributedString) -> [TranscriptOriginal.Word] {
        var words: [TranscriptOriginal.Word] = []
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let runText = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runText.isEmpty else { continue }
            let start = timeRange.start.seconds
            let end = timeRange.end.seconds

            let parts = runText.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count <= 1 {
                words.append(.init(text: runText, start: start, end: end))
            } else {
                let step = (end - start) / Double(parts.count)
                for (index, part) in parts.enumerated() {
                    words.append(.init(
                        text: part,
                        start: start + Double(index) * step,
                        end: start + Double(index + 1) * step
                    ))
                }
            }
        }
        return words
    }
}
