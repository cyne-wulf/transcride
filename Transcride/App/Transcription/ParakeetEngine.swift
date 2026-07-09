import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT v3 (0.6b) via FluidAudio — the default engine (ENG-1).
/// ~100–200× realtime on Apple Silicon; models live in the app container at
/// `Application Support/FluidAudio/Models/`.
actor ParakeetEngine: TranscriptionEngine {
    nonisolated let info: TranscriptionModelInfo

    private var manager: AsrManager?

    init(info: TranscriptionModelInfo) {
        self.info = info
    }

    private var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    // MARK: - Model management

    func isDownloaded() async -> Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: .v3)
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            _ = try await AsrModels.download(version: .v3) { snapshot in
                progress(snapshot.fractionCompleted)
            }
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        // Completeness gate (ENG-2): a failed/partial download must never
        // count as downloaded.
        guard AsrModels.modelsExist(at: cacheDirectory, version: .v3) else {
            throw TranscriptionError.engineFailure("Model files are incomplete after download.")
        }
    }

    func deleteModel() async throws {
        await manager?.cleanup()
        manager = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDirectory.path) {
            try fm.removeItem(at: cacheDirectory)
        }
    }

    func downloadedByteSize() async -> Int64? {
        guard await isDownloaded() else { return nil }
        return FileManager.default.directoryByteSize(of: cacheDirectory)
    }

    // MARK: - Transcription

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptOriginal.Segment] {
        guard await isDownloaded() else {
            throw TranscriptionError.modelNotDownloaded(info.displayName)
        }
        let manager = try await loadedManager()

        // Forward FluidAudio's chunk progress while the transcription runs.
        let progressTask = Task {
            for try await fraction in await manager.transcriptionProgressStream {
                progress(fraction)
            }
        }
        defer { progressTask.cancel() }

        let language = options.languageHint.flatMap { Language(rawValue: $0) }
        var decoderState = try TdtDecoderState(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let result: ASRResult
        do {
            result = try await manager.transcribe(
                audioURL, decoderState: &decoderState, language: language
            )
        } catch {
            throw TranscriptionError.engineFailure(error.localizedDescription)
        }
        try Task.checkCancellation()

        let words = buildWordTimings(from: result.tokenTimings ?? []).compactMap { timing in
            let text = timing.word.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TranscriptOriginal.Word(
                text: text, start: timing.startTime, end: timing.endTime
            )
        }
        progress(1.0)
        return SegmentBuilder.segments(from: words)
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        do {
            let models = try await AsrModels.load(from: cacheDirectory, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            return manager
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }
}

extension FileManager {
    /// Recursive on-disk size of a directory (approximate; follows the file
    /// allocation sizes the volume reports).
    func directoryByteSize(of url: URL) -> Int64 {
        guard let enumerator = enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
