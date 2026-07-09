import Foundation
import WhisperKit

/// WhisperKit engine (ENG-1): `large-v3-turbo` and `small` are two catalog
/// entries sharing this one runtime class — each instance is bound to one
/// model variant. Supports prompt-based vocabulary biasing (VOC-2) and
/// language auto-detection.
actor WhisperKitEngine: TranscriptionEngine {
    nonisolated let info: TranscriptionModelInfo

    private var pipe: WhisperKit?

    init(info: TranscriptionModelInfo) {
        self.info = info
    }

    /// All WhisperKit models live under one base in the app container;
    /// the hub layout is `<base>/models/argmaxinc/whisperkit-coreml/<variant>`.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WhisperKit")
    }

    private nonisolated var variant: String { info.modelID }

    private nonisolated var modelFolder: URL {
        Self.downloadBase
            .appending(path: "models/argmaxinc/whisperkit-coreml")
            .appending(path: variant)
    }

    /// Written only after a download finished and the file set is complete —
    /// a cancelled or failed download never counts as downloaded (ENG-2).
    private nonisolated var completionMarker: URL {
        modelFolder.appending(path: ".transcride-download-complete")
    }

    private nonisolated var requiredModelFiles: [String] {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
    }

    // MARK: - Model management

    func isDownloaded() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: completionMarker.path) else { return false }
        return requiredModelFiles.allSatisfy {
            fm.fileExists(atPath: modelFolder.appending(path: $0).path)
        }
    }

    func downloadModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        try? FileManager.default.removeItem(at: completionMarker)
        do {
            let folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.downloadBase,
                progressCallback: { snapshot in
                    progress(.downloading(snapshot.fractionCompleted))
                }
            )
            // Completeness check before the marker makes it "downloaded".
            let fm = FileManager.default
            let missing = requiredModelFiles.filter {
                !fm.fileExists(atPath: folder.appending(path: $0).path)
            }
            guard missing.isEmpty else {
                throw TranscriptionError.engineFailure(
                    "Download incomplete; missing \(missing.joined(separator: ", "))"
                )
            }
            try Task.checkCancellation()
            // Load once before writing the marker: the first load pays a
            // minutes-long CoreML specialization and fetches the tokenizer,
            // so that cost lands here — where the UI already says the model
            // is being fetched — not on the first transcription. It also
            // makes "downloaded" mean "runnable".
            progress(.preparing)
            pipe = try await Self.makePipe(variant: variant, modelFolder: modelFolder)
            try Task.checkCancellation()
            try Data().write(to: folder.appending(path: ".transcride-download-complete"))
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
    }

    func deleteModel() throws {
        pipe = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: modelFolder.path) {
            try fm.removeItem(at: modelFolder)
        }
    }

    func downloadedByteSize() -> Int64? {
        guard isDownloaded() else { return nil }
        return FileManager.default.directoryByteSize(of: modelFolder)
    }

    func modelDirectory() -> URL? {
        isDownloaded() ? modelFolder : nil
    }

    // MARK: - Transcription

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptOriginal.Segment] {
        guard isDownloaded() else {
            throw TranscriptionError.modelNotDownloaded(info.displayName)
        }
        let pipe = try await loadedPipe()

        var decodeOptions = DecodingOptions()
        decodeOptions.task = .transcribe
        decodeOptions.wordTimestamps = true
        decodeOptions.chunkingStrategy = .vad
        if let hint = options.languageHint {
            decodeOptions.language = hint
            decodeOptions.detectLanguage = false
        } else {
            decodeOptions.detectLanguage = true
        }

        // Native vocabulary biasing (VOC-2): terms go in as the decoder
        // prompt, nudging Whisper toward those spellings. Only for variants
        // whose decoder tolerates prompt conditioning (see ModelCatalog).
        if info.supportsVocabularyBiasing, !options.vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            let promptText = " " + options.vocabulary.joined(separator: ", ") + "."
            let tokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                decodeOptions.promptTokens = tokens
                decodeOptions.usePrefillPrompt = true
            }
        }

        let overallProgress = pipe.progress
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioPath: audioURL.path,
                decodeOptions: decodeOptions,
                callback: { _ in
                    progress(min(0.999, overallProgress.fractionCompleted))
                    return Task.isCancelled ? false : nil // false = stop early
                }
            )
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        try Task.checkCancellation()
        progress(1.0)

        let segments = Self.segments(from: results)
        guard !segments.isEmpty else {
            throw TranscriptionError.engineFailure(
                "The model produced no transcription for this audio."
            )
        }
        return segments
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        do {
            let pipe = try await Self.makePipe(variant: variant, modelFolder: modelFolder)
            self.pipe = pipe
            return pipe
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }

    private static func makePipe(variant: String, modelFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(model: variant)
        config.modelFolder = modelFolder.path
        config.verbose = false
        config.logLevel = .error
        config.load = true
        config.download = false
        return try await WhisperKit(config)
    }

    /// Maps WhisperKit segments/word timings onto the transcript schema.
    /// Whisper word texts carry leading spaces; segments without word timings
    /// (rare fallback) become one word spanning the segment.
    private static func segments(from results: [TranscriptionResult]) -> [TranscriptOriginal.Segment] {
        var out: [TranscriptOriginal.Segment] = []
        for result in results {
            for segment in result.segments {
                let words: [TranscriptOriginal.Word]
                if let timings = segment.words, !timings.isEmpty {
                    words = timings.compactMap { timing in
                        let text = timing.word.trimmingCharacters(in: .whitespaces)
                        return text.isEmpty ? nil : TranscriptOriginal.Word(
                            text: text, start: Double(timing.start), end: Double(timing.end)
                        )
                    }
                } else {
                    // Segment text (unlike word timings) carries decoder
                    // control tokens — strip them before the fallback word.
                    let text = SegmentBuilder.strippingSpecialTokens(segment.text)
                    words = text.isEmpty ? [] : [TranscriptOriginal.Word(
                        text: text, start: Double(segment.start), end: Double(segment.end)
                    )]
                }
                guard !words.isEmpty else { continue }
                out.append(TranscriptOriginal.Segment(
                    start: Double(segment.start), end: Double(segment.end),
                    speaker: nil, words: words
                ))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
