import Foundation
import Observation

/// The per-vault transcription queue (TRN-2/TRN-3): entries are processed one
/// at a time by a serial worker; pending/failed items persist across relaunch
/// via `TranscriptionQueueStore`, and per-item progress feeds the queue UI.
@MainActor
@Observable
final class TranscriptionQueue {
    private(set) var items: [TranscriptionQueueItem] = []
    private(set) var progressByItemID: [String: Double] = [:]

    /// Called after each successful transcription with the item's original
    /// entry path and the applier's outcome (the path may have changed via
    /// auto-title). Set by `AppModel`.
    var onEntryTranscribed: ((RelativePath, TranscriptionApplier.Outcome) -> Void)?

    private let vaultRoot: URL
    private let service: VaultService
    private var worker: Task<Void, Never>?

    init(vaultRoot: URL, service: VaultService) {
        self.vaultRoot = vaultRoot
        self.service = service
        items = TranscriptionQueueStore.load(fromVault: vaultRoot)
        ensureWorker()
    }

    /// Stops the worker (mid-item work is cancelled; the item returns to
    /// `waiting` and re-runs next launch/open).
    func shutdown() {
        worker?.cancel()
        worker = nil
    }

    // MARK: - Intents

    func enqueue(
        entryRelativePath: RelativePath,
        source: String,
        isRetranscribe: Bool = false,
        modelID: String = ModelCatalog.preferredDefaultModelID()
    ) {
        items.append(TranscriptionQueueItem(
            entryRelativePath: entryRelativePath,
            modelID: modelID,
            source: source,
            isRetranscribe: isRetranscribe,
            createdAt: .now
        ))
        persist()
        ensureWorker()
    }

    func retry(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .failed else { return }
        items[index].state = .waiting
        items[index].errorMessage = nil
        persist()
        ensureWorker()
    }

    /// Removes a waiting or failed item; a running item can't be removed.
    func remove(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state != .running else { return }
        items.remove(at: index)
        progressByItemID[itemID] = nil
        persist()
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        guard items.contains(where: { $0.state == .waiting }) else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let index = self.items.firstIndex(where: { $0.state == .waiting }) else {
                    break
                }
                await self.process(itemAt: index)
            }
            self?.worker = nil
        }
    }

    private func process(itemAt index: Int) async {
        items[index].state = .running
        items[index].errorMessage = nil
        let item = items[index]
        persist()
        progressByItemID[item.id] = 0

        do {
            try await run(item)
            items.removeAll { $0.id == item.id }
        } catch is CancellationError {
            markWaiting(item.id)
        } catch TranscriptionError.cancelled {
            markWaiting(item.id)
        } catch {
            if let itemIndex = items.firstIndex(where: { $0.id == item.id }) {
                items[itemIndex].state = .failed
                items[itemIndex].errorMessage = error.localizedDescription
            }
        }
        progressByItemID[item.id] = nil
        persist()
    }

    private func run(_ item: TranscriptionQueueItem) async throws {
        guard let audioFileName = await service.audioFileName(atEntryPath: item.entryRelativePath) else {
            throw TranscriptionError.audioUnreadable("No audio file in this entry.")
        }
        guard let info = ModelCatalog.info(forID: item.modelID),
              let engine = await EngineRegistry.shared.engine(forModelInfoID: item.modelID) else {
            throw TranscriptionError.engineFailure("Unknown model \"\(item.modelID)\".")
        }
        guard await engine.isDownloaded() else {
            throw TranscriptionError.modelNotDownloaded(
                "\(info.displayName) — download it in Settings → Transcription"
            )
        }

        let vocabulary = await service.vocabularyTerms()
        let options = TranscriptionOptions(
            languageHint: nil,
            vocabulary: info.supportsVocabularyBiasing ? vocabulary : []
        )

        let audioURL = vaultRoot
            .appendingRelativePath(item.entryRelativePath)
            .appending(path: audioFileName)
        let itemID = item.id
        let segments = try await engine.transcribe(
            audioURL: audioURL, options: options
        ) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.progressByItemID[itemID] != nil else { return }
                self.progressByItemID[itemID] = fraction
            }
        }
        try Task.checkCancellation()

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let metadata = TranscriptOriginal.EngineMetadata(
            engine: info.engineID,
            model: info.modelID,
            options: options.metadataDictionary,
            created: ISO8601DateFormatter().string(from: .now),
            appVersion: "\(version) (\(build))"
        )
        let outcome = try await service.applyTranscription(
            segments: segments,
            toEntryAt: item.entryRelativePath,
            engine: metadata,
            engineFrontmatterID: info.id,
            vocabularyTerms: vocabulary
        )
        DebugLog.append(
            "transcribed [\(item.entryRelativePath)] with \(info.id) (\(item.source)): "
                + "\(segments.count) segments, \(outcome.correctionCount) corrections"
                + (outcome.appliedTitle.map { ", titled \"\($0)\"" } ?? "")
                + (outcome.markdownLeftAlone ? ", md left alone (hand-edited)" : "")
        )
        onEntryTranscribed?(item.entryRelativePath, outcome)
    }

    private func markWaiting(_ itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].state = .waiting
    }

    private func persist() {
        do {
            try TranscriptionQueueStore.save(items, toVault: vaultRoot)
        } catch {
            DebugLog.append("queue persist FAILED \(error)")
        }
    }
}
