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
    /// Items currently in the diarization post-pass (TRN-6), so the UI can
    /// say "Detecting speakers…" instead of "Transcribing…".
    private(set) var speakerPhaseItemIDs: Set<String> = []

    /// Called after each successful transcription with the item's original
    /// entry path and the applier's outcome (the path may have changed via
    /// auto-title). Set by `AppModel`.
    var onEntryTranscribed: ((RelativePath, TranscriptionApplier.Outcome) -> Void)?
    /// Gives the mounted editor an acknowledged save/recovery barrier before
    /// transcription rewrites or auto-renames the selected entry.
    var beforeEntryMutation: ((RelativePath) async -> Bool)?

    private let vaultRoot: URL
    private let service: VaultService
    private var worker: Task<Void, Never>?
    /// The in-flight item's work, cancellable independently of the worker
    /// loop (eviction cancels one item; `shutdown` cancels everything).
    private var runningItemTask: (itemID: String, task: Task<Void, Error>)?
    /// Running items whose entry was deleted mid-flight: dropped when their
    /// run ends instead of being re-queued or marked failed.
    private var evictedRunningIDs: Set<String> = []

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
        runningItemTask?.task.cancel()
    }

    // MARK: - Intents

    func enqueue(
        entryRelativePath: RelativePath,
        source: String,
        isRetranscribe: Bool = false,
        modelID: String = ModelCatalog.preferredDefaultModelID(),
        detectSpeakers: Bool = false,
        speakerCount: Int? = nil
    ) {
        items.append(TranscriptionQueueItem(
            entryRelativePath: entryRelativePath,
            modelID: modelID,
            source: source,
            isRetranscribe: isRetranscribe,
            detectSpeakers: detectSpeakers,
            speakerCount: speakerCount,
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

    /// Removes an item. A running item's in-flight work is cancelled and the
    /// item dropped once it winds down — never re-queued (that path is
    /// reserved for `shutdown`) and never applied to the entry.
    func remove(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if items[index].state == .running {
            evictedRunningIDs.insert(itemID)
            if runningItemTask?.itemID == itemID { runningItemTask?.task.cancel() }
        } else {
            items.remove(at: index)
            progressByItemID[itemID] = nil
            persist()
        }
    }

    /// Drops every item for a deleted entry — or anything beneath a deleted
    /// folder. Running work is cancelled, not re-queued: the entry is gone.
    func evictItems(underPath relPath: RelativePath) {
        let affected = items.filter {
            $0.entryRelativePath == relPath
                || $0.entryRelativePath.hasPrefix(relPath + "/")
        }
        for item in affected {
            remove(itemID: item.id)
        }
    }

    /// Follows an entry rename or move so queued duplicates (e.g. a second
    /// item enqueued before an auto-title rename landed) don't go stale.
    func repointItems(from oldPath: RelativePath, to newPath: RelativePath) {
        guard oldPath != newPath else { return }
        var changed = false
        for index in items.indices {
            let path = items[index].entryRelativePath
            if path == oldPath {
                items[index].entryRelativePath = newPath
                changed = true
            } else if path.hasPrefix(oldPath + "/") {
                items[index].entryRelativePath = newPath + path.dropFirst(oldPath.count)
                changed = true
            }
        }
        if changed { persist() }
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

        // The item's work gets its own task so `remove`/`evictItems` can
        // cancel one item without tearing down the worker loop.
        let task = Task { try await self.run(item) }
        runningItemTask = (item.id, task)
        var interrupted = false
        var failure: String?
        do {
            try await task.value
        } catch is CancellationError {
            interrupted = true
        } catch TranscriptionError.cancelled {
            interrupted = true
        } catch let error as VaultError {
            if case .notFound = error {
                // The entry vanished mid-flight (deleted); nothing left to do.
                DebugLog.append("queue dropped [\(item.entryRelativePath)]: entry no longer exists")
            } else {
                failure = error.localizedDescription
            }
        } catch {
            failure = error.localizedDescription
        }
        runningItemTask = nil

        if evictedRunningIDs.remove(item.id) != nil {
            // Cancelled by the user or evicted by a delete: drop the item
            // however its run ended.
            items.removeAll { $0.id == item.id }
            DebugLog.append("queue cancelled [\(item.entryRelativePath)] mid-run")
        } else if interrupted {
            markWaiting(item.id) // shutdown — re-runs next launch/open
        } else if let failure {
            if let itemIndex = items.firstIndex(where: { $0.id == item.id }) {
                items[itemIndex].state = .failed
                items[itemIndex].errorMessage = failure
            }
        } else {
            items.removeAll { $0.id == item.id } // success, or notFound drop
        }
        progressByItemID[item.id] = nil
        speakerPhaseItemIDs.remove(item.id)
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
        let detectSpeakers = item.detectSpeakers && info.supportsDiarization
        let options = TranscriptionOptions(
            languageHint: nil,
            vocabulary: info.supportsVocabularyBiasing ? vocabulary : [],
            detectSpeakers: detectSpeakers,
            speakerCount: detectSpeakers ? item.speakerCount : nil
        )

        let audioURL = vaultRoot
            .appendingRelativePath(item.entryRelativePath)
            .appending(path: audioFileName)
        let itemID = item.id
        var segments = try await engine.transcribe(
            audioURL: audioURL, options: options
        ) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.progressByItemID[itemID] != nil else { return }
                self.progressByItemID[itemID] = fraction
            }
        }
        try Task.checkCancellation()

        // Speaker detection (TRN-6): a separate diarizer pass over the same
        // file, fused into the segments before anything is written.
        if detectSpeakers {
            guard await DiarizationEngine.shared.isDownloaded() else {
                throw TranscriptionError.modelNotDownloaded(
                    "Speaker Detection — download it in Settings → Transcription"
                )
            }
            speakerPhaseItemIDs.insert(itemID)
            defer { speakerPhaseItemIDs.remove(itemID) }
            progressByItemID[itemID] = 0
            let turns = try await DiarizationEngine.shared.diarize(
                audioURL: audioURL, speakerCount: item.speakerCount
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.progressByItemID[itemID] != nil else { return }
                    self.progressByItemID[itemID] = fraction
                }
            }
            try Task.checkCancellation()
            segments = SpeakerAssigner.apply(turns: turns, to: segments)
            DebugLog.append(
                "diarized [\(item.entryRelativePath)]: \(turns.count) turns, "
                    + "\(Set(turns.map(\.speakerID)).count) speakers"
            )
        }

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
        if let beforeEntryMutation,
           !(await beforeEntryMutation(item.entryRelativePath)) {
            throw TranscriptionError.engineFailure(
                "The open editor could not be saved before applying the finished transcription."
            )
        }
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
        if outcome.entryRelativePath != item.entryRelativePath {
            repointItems(from: item.entryRelativePath, to: outcome.entryRelativePath)
        }
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
