import FluidAudio
import Foundation

/// Speaker diarization (TRN-6) via FluidAudio's offline VBx pipeline — their
/// best-quality option (AMI SDM ~11% DER at 60–70× realtime). Engine-agnostic:
/// the queue runs it as a post-pass after any ASR engine and fuses the turns
/// into the segments with `SpeakerAssigner`. Model management mirrors the ASR
/// engines so the Settings row and dialogs drive it through `ModelManager`.
actor DiarizationEngine: ModelManaging {
    static let shared = DiarizationEngine()

    nonisolated let info = ModelCatalog.speakerDiarization

    /// Loaded model set, cached for the app's lifetime once used (same policy
    /// as `EngineRegistry`).
    private var models: OfflineDiarizerModels?

    /// `ModelHub` caches each repo under `<…/FluidAudio/Models>/<folderName>`;
    /// the diarizer repo's folder is its slug minus the "-coreml" suffix.
    private static var repoDirectory: URL {
        OfflineDiarizerModels.defaultModelsDirectory()
            .appending(path: "speaker-diarization")
    }

    /// The offline pipeline's required file set. FluidAudio has no
    /// `modelsExist`-style helper for it, so presence is checked directly.
    private static let requiredFiles = [
        "Segmentation.mlmodelc",
        "FBank.mlmodelc",
        "Embedding.mlmodelc",
        "PldaRho.mlmodelc",
        "plda-parameters.json",
    ]

    // MARK: - Model management

    func isDownloaded() async -> Bool {
        let fm = FileManager.default
        return Self.requiredFiles.allSatisfy {
            fm.fileExists(atPath: Self.repoDirectory.appending(path: $0).path)
        }
    }

    func downloadModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        do {
            models = try await OfflineDiarizerModels.load { snapshot in
                switch snapshot.phase {
                case .compiling:
                    progress(.preparing)
                default:
                    progress(.downloading(snapshot.fractionCompleted))
                }
            }
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        // Completeness gate (ENG-2): a failed/partial download must never
        // count as downloaded.
        guard await isDownloaded() else {
            throw TranscriptionError.engineFailure("Model files are incomplete after download.")
        }
    }

    func deleteModel() async throws {
        models = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.repoDirectory.path) {
            try fm.removeItem(at: Self.repoDirectory)
        }
    }

    func downloadedByteSize() async -> Int64? {
        guard await isDownloaded() else { return nil }
        return FileManager.default.directoryByteSize(of: Self.repoDirectory)
    }

    func modelDirectory() async -> URL? {
        await isDownloaded() ? Self.repoDirectory : nil
    }

    // MARK: - Diarization

    /// Runs offline diarization on one audio file (the pipeline memory-maps
    /// and resamples internally) and returns time-ordered speaker turns with
    /// FluidAudio's stable machine ids ("S1", "S2", …). `speakerCount` is the
    /// user's exact-count hint; nil auto-detects.
    func diarize(
        audioURL: URL,
        speakerCount: Int?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        guard await isDownloaded() else {
            throw TranscriptionError.modelNotDownloaded(info.displayName)
        }
        let models = try await loadedModels()

        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = speakerCount
        // The manager is a lightweight class configured per run; the loaded
        // CoreML models behind it are the expensive part and are reused.
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL) { chunksProcessed, totalChunks in
                progress(totalChunks > 0 ? Double(chunksProcessed) / Double(totalChunks) : 0)
            }
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        try Task.checkCancellation()

        return result.segments
            .map {
                SpeakerTurn(
                    speakerID: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds)
                )
            }
            .sorted { $0.start < $1.start }
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        do {
            let loaded = try await OfflineDiarizerModels.load()
            models = loaded
            return loaded
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }
}
