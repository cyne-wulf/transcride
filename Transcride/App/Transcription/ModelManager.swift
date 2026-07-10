import Foundation
import Observation

/// Model download state for the settings UI and retranscribe dialog (ENG-2):
/// download on demand with progress, cancel, delete-to-reclaim-space. A model
/// is only ever marked downloaded after its engine verified the file set.
@MainActor
@Observable
final class ModelManager {
    enum ModelState: Equatable {
        case checking
        case notDownloaded
        case downloading(Double)
        /// Bytes are on disk; the engine is doing first-load work (CoreML
        /// compilation, tokenizer fetch) that can run minutes with no
        /// measurable fraction.
        case preparing
        case downloaded(byteSize: Int64?)
        case failed(String)

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var isDownloading: Bool {
            switch self {
            case .downloading, .preparing: return true
            default: return false
            }
        }
    }

    /// UserDefaults flag: the first-run Parakeet offer is shown once.
    static let didOfferDefaultDownloadKey = "didOfferDefaultModelDownload"

    private(set) var states: [String: ModelState] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    func state(forModelInfoID id: String) -> ModelState {
        states[id] ?? .checking
    }

    /// Resolves a model id to whatever manages its files: an ASR engine from
    /// the registry, or the diarizer (TRN-6), which shares the same
    /// download/delete surface without being a transcription engine.
    private func managing(forID id: String) async -> (any ModelManaging)? {
        if id == ModelCatalog.speakerDiarization.id { return DiarizationEngine.shared }
        return await EngineRegistry.shared.engine(forModelInfoID: id)
    }

    /// Re-checks every managed model's on-disk state.
    func refresh() async {
        for info in ModelCatalog.available + [ModelCatalog.speakerDiarization] {
            await refreshModel(info.id)
        }
    }

    func refreshModel(_ id: String) async {
        guard downloadTasks[id] == nil else { return } // don't fight a download
        guard let engine = await managing(forID: id) else {
            states[id] = .failed("Unknown model")
            return
        }
        if await engine.isDownloaded() {
            states[id] = .downloaded(byteSize: await engine.downloadedByteSize())
        } else if case .some(.failed) = states[id] {
            // keep the failure visible until the user retries
        } else {
            states[id] = .notDownloaded
        }
    }

    func download(_ id: String) {
        guard downloadTasks[id] == nil else { return }
        states[id] = .downloading(0)
        let task = Task { [weak self] in
            guard let engine = await self?.managing(forID: id) else {
                await MainActor.run { self?.states[id] = .failed("Unknown model") }
                return
            }
            do {
                try await engine.downloadModel { [weak self] step in
                    Task { @MainActor [weak self] in
                        guard let self, self.state(forModelInfoID: id).isDownloading else { return }
                        switch step {
                        case .downloading(let fraction): self.states[id] = .downloading(fraction)
                        case .preparing: self.states[id] = .preparing
                        }
                    }
                }
                self?.states[id] = .checking
            } catch is CancellationError {
                self?.states[id] = .notDownloaded
            } catch TranscriptionError.cancelled {
                self?.states[id] = .notDownloaded
            } catch {
                self?.states[id] = .failed(error.localizedDescription)
            }
            self?.downloadTasks[id] = nil
            await self?.refreshModel(id)
        }
        downloadTasks[id] = task
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    func delete(_ id: String) async {
        guard let engine = await managing(forID: id) else { return }
        do {
            try await engine.deleteModel()
        } catch {
            states[id] = .failed(error.localizedDescription)
            return
        }
        await refreshModel(id)
    }

    /// On-disk folder of a downloaded model, for "Show in Finder".
    func modelDirectory(forModelInfoID id: String) async -> URL? {
        await managing(forID: id)?.modelDirectory()
    }
}
