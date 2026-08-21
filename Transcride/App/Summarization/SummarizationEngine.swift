import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum SummaryGenerationError: LocalizedError {
    case modelNotDownloaded(String)
    case emptyOutput
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let model):
            return "The model \(model) is not downloaded."
        case .emptyOutput:
            return "The model produced no usable summary."
        case .generationFailed(let reason):
            return "Summary generation failed: \(reason)"
        }
    }
}

/// Local summarization on MLX: one instance per catalog model, owning that
/// model's Hub cache directory and (while generating) its loaded weights.
/// Conforms to `ModelManaging` so the Settings download/delete/Show-in-Finder
/// surface works unchanged.
actor SummarizationEngine: ModelManaging {
    static let gemma1B = SummarizationEngine(info: SummaryModelCatalog.gemma1B)
    static let gemma4B = SummarizationEngine(info: SummaryModelCatalog.gemma4B)

    static func engine(forModelInfoID id: String) -> SummarizationEngine? {
        switch id {
        case SummaryModelCatalog.gemma1B.id: gemma1B
        case SummaryModelCatalog.gemma4B.id: gemma4B
        default: nil
        }
    }

    nonisolated let info: TranscriptionModelInfo

    private var container: ModelContainer?
    private var gpuLimitConfigured = false

    init(info: TranscriptionModelInfo) {
        self.info = info
    }

    /// All summary models live in one Hub-layout cache under the app
    /// container, so Python-style `models--org--repo` directories are the
    /// deletable unit.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SummaryModels")
    }

    private nonisolated var hubCache: HubCache {
        HubCache(cacheDirectory: Self.downloadBase)
    }

    private nonisolated var repoID: Repo.ID? {
        Repo.ID(rawValue: info.modelID)
    }

    private nonisolated var modelFolder: URL {
        guard let repoID else { return Self.downloadBase }
        return hubCache.repoDirectory(repo: repoID, kind: .model)
    }

    /// Written only after the weights downloaded completely and loaded once —
    /// a cancelled or failed download never counts as downloaded.
    private nonisolated var completionMarker: URL {
        modelFolder.appending(path: ".transcride-download-complete")
    }

    private nonisolated var configuration: ModelConfiguration {
        ModelConfiguration(id: info.modelID, extraEOSTokens: ["<end_of_turn>"])
    }

    // MARK: - Model management

    func isDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: completionMarker.path)
    }

    func downloadModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        try? FileManager.default.removeItem(at: completionMarker)
        do {
            // Load once before writing the marker: the first load pays the
            // weight materialization, so that cost lands here — where the UI
            // already says the model is being fetched — and "downloaded"
            // means "runnable".
            // The verified container is deliberately not kept: weights stay
            // resident only around a generation, never after a download alone.
            _ = try await loadContainer { fraction in
                progress(.downloading(fraction))
            }
            try Task.checkCancellation()
            progress(.preparing)
            try Data().write(to: completionMarker)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch let error as SummaryGenerationError {
            throw error
        } catch {
            throw SummaryGenerationError.generationFailed(error.localizedDescription)
        }
    }

    func deleteModel() throws {
        container = nil
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

    // MARK: - Summarization

    struct GenerationProgress: Sendable {
        let part: Int
        let total: Int
        /// Overall 0…1 estimate across all passes: completed passes plus the
        /// running pass's streamed-token fraction (against the maxTokens
        /// budget, capped below 1 — output length isn't knowable up front).
        let fraction: Double
    }

    /// Map/reduce summarization: single template-fill pass when the source
    /// fits the context budget; otherwise per-chunk map passes, a combine
    /// pass, and a final template pass. The weights are released when the
    /// call ends — success, failure, or cancellation — so RSS falls back.
    func summarize(
        text: String,
        onProgress: @escaping @Sendable (GenerationProgress) -> Void
    ) async throws -> String {
        guard isDownloaded() else {
            throw SummaryGenerationError.modelNotDownloaded(info.displayName)
        }
        guard let spec = SummaryModelCatalog.spec(forModelInfoID: info.id) else {
            throw SummaryGenerationError.generationFailed("No model spec for \(info.id)")
        }
        defer { container = nil }

        let container = try await loadedContainer()
        let parameters = GenerateParameters(
            maxTokens: spec.maxTokens,
            temperature: spec.temperature,
            topP: spec.topP,
            topK: spec.topK
        )
        let template = SummaryTemplate.basic
        let chunks = SummaryChunker.chunks(of: text, contextTokens: spec.contextTokens)
        let totalParts = chunks.count == 1 ? 1 : chunks.count + 2

        func runPass(_ prompt: String, part: Int) async throws -> String {
            func overallFraction(withinPass: Double) -> Double {
                (Double(part - 1) + min(max(withinPass, 0), 0.95)) / Double(totalParts)
            }
            onProgress(GenerationProgress(
                part: part, total: totalParts, fraction: overallFraction(withinPass: 0)
            ))
            let session = ChatSession(
                container,
                instructions: SummaryPrompt.systemPrompt,
                generateParameters: parameters
            )
            var output = ""
            var pieces = 0
            for try await piece in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                output += piece
                pieces += 1
                // Roughly one piece per token; throttle UI updates.
                if pieces % 8 == 0 {
                    onProgress(GenerationProgress(
                        part: part,
                        total: totalParts,
                        fraction: overallFraction(
                            withinPass: Double(pieces) / Double(spec.maxTokens)
                        )
                    ))
                }
            }
            return output
        }

        do {
            let source: String
            if chunks.count == 1 {
                source = text
            } else {
                var partials: [String] = []
                for (index, chunk) in chunks.enumerated() {
                    let partial = try await runPass(
                        SummaryPrompt.mapPrompt(chunk: chunk, index: index, total: chunks.count),
                        part: index + 1
                    )
                    partials.append(partial)
                }
                source = try await runPass(
                    SummaryPrompt.combinePrompt(partials: partials), part: chunks.count + 1
                )
            }

            let finalPrompt = SummaryPrompt.finalPrompt(source: source, template: template)
            var cleaned = SummaryPrompt.cleanedOutput(
                try await runPass(finalPrompt, part: totalParts)
            )
            // One structural retry: a small model occasionally drops the
            // template; a second final pass is cheap next to accepting
            // arbitrary prose.
            if cleaned.map({ SummaryPrompt.validate($0, against: template) }) != true {
                cleaned = SummaryPrompt.cleanedOutput(
                    try await runPass(finalPrompt, part: totalParts)
                )
            }
            guard let cleaned else { throw SummaryGenerationError.emptyOutput }
            return cleaned
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummaryGenerationError {
            throw error
        } catch {
            throw SummaryGenerationError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Loading

    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        do {
            let loaded = try await loadContainer { _ in }
            container = loaded
            return loaded
        } catch {
            throw SummaryGenerationError.generationFailed(error.localizedDescription)
        }
    }

    private func loadContainer(
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        if !gpuLimitConfigured {
            // Bound the MLX GPU buffer cache so repeated generations don't
            // accumulate cached buffers toward the 8 GB app ceiling.
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
            gpuLimitConfigured = true
        }
        let client = HubClient(cache: hubCache)
        return try await loadModelContainer(
            from: #hubDownloader(client),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { progress in
                progressHandler(progress.fractionCompleted)
            }
        )
    }
}
