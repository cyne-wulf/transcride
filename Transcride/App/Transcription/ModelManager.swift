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
        case downloaded(byteSize: Int64?)
        case failed(String)

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    /// UserDefaults flag: the first-run Parakeet offer is shown once.
    static let didOfferDefaultDownloadKey = "didOfferDefaultModelDownload"

    private(set) var states: [String: ModelState] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    func state(forModelInfoID id: String) -> ModelState {
        states[id] ?? .checking
    }

    /// Re-checks every catalog model's on-disk state.
    func refresh() async {
        for info in ModelCatalog.available {
            await refreshModel(info.id)
        }
    }

    func refreshModel(_ id: String) async {
        guard downloadTasks[id] == nil else { return } // don't fight a download
        guard let engine = await EngineRegistry.shared.engine(forModelInfoID: id) else {
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
            guard let engine = await EngineRegistry.shared.engine(forModelInfoID: id) else {
                await MainActor.run { self?.states[id] = .failed("Unknown model") }
                return
            }
            do {
                try await engine.downloadModel { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.state(forModelInfoID: id).isDownloading else { return }
                        self.states[id] = .downloading(fraction)
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
        guard let engine = await EngineRegistry.shared.engine(forModelInfoID: id) else { return }
        do {
            try await engine.deleteModel()
        } catch {
            states[id] = .failed(error.localizedDescription)
            return
        }
        await refreshModel(id)
    }
}
