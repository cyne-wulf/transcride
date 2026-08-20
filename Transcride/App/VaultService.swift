import Foundation
import AVFoundation

struct EntryTranscriptContent: Sendable {
    var edited: FrontmatterDocument?
    var original: TranscriptOriginal?
    var extensionState: ExtensionTranscriptState?
    var wordMap: TranscriptWordMap?
    var isForked: Bool
}

struct AudioExtensionOutcome: Sendable {
    var audioFileName: String
    var combinedDuration: Double
    var normalized: Bool
    var trashedName: String
}

struct ClipEditSwapOutcome: Sendable {
    var operation: ClipEditOperation
    var entryRelativePath: RelativePath
    var duration: Double
}

/// Background actor owning all vault file I/O so the main thread never touches
/// the disk. Wraps the scanner (with its cache), mutation operations, and trash.
actor VaultService {
    let rootURL: URL
    private var scanner = VaultScanner()
    private let operations: VaultOperations
    private let trash: TrashStore
    private let clipEditHistory: ClipEditHistoryStore
    private let settings: VaultSettingsStore
    private var searchIndex: VaultSearchIndex?

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.operations = VaultOperations(vaultRoot: rootURL)
        self.trash = TrashStore(vaultRoot: rootURL)
        self.clipEditHistory = ClipEditHistoryStore(vaultRoot: rootURL)
        self.settings = VaultSettingsStore(vaultRoot: rootURL)
    }

    // MARK: - Reading

    func snapshot() -> VaultSnapshot {
        scanner.scan(root: rootURL)
    }

    func recoverInterruptedRecordings() async -> InterruptedRecordingRecoverySummary {
        // Entries staged by an import/duplicate that never finished are
        // invisible to the library; clear them out at launch so they cannot
        // accumulate on disk.
        EntryStaging.sweep(inVault: rootURL)
        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: rootURL)
        if !summary.recovered.isEmpty {
            synchronizeSearchIndex(relativePaths: summary.recovered.map(\.entryRelativePath))
        }
        return summary
    }

    func recordingExtensionRecoveries() -> RecordingExtensionRecoveryDiscovery {
        RecordingExtensionRecovery.discover(inVault: rootURL)
    }

    func finishRecoveredExtension(
        _ recovery: RecoverableRecordingExtension
    ) async throws -> AudioExtensionOutcome {
        if recovery.phase == .swapNeedsCleanup {
            return try await convergeRecoveredExtensionSwap(recovery)
        }
        guard let segmentName = recovery.segmentFileName else {
            throw VaultError.notFound("Recoverable extension segment")
        }
        let entryURL = rootURL.appendingRelativePath(recovery.entryRelativePath)
        let segmentURL = entryURL.appending(path: segmentName)
        let segmentDuration = try await AudioImportFormat.probeDuration(of: segmentURL)
        var session = recovery.session
        // The manifest was found *inside* this folder, so the folder is
        // authoritative: a rename or move since the crash left the stored path
        // stale, and trusting it would dead-end every retry on `sourceChanged`.
        session.target.entryRelativePath = recovery.entryRelativePath
        session.phase = .segmentReady
        session.segmentDuration = segmentDuration
        session.failureMessage = nil
        try writeExtensionManifest(session, in: entryURL)
        // A validated combined output is derived from the still-retained
        // segment. Rebuild it so retry is deterministic across exporter versions.
        try? FileManager.default.removeItem(
            at: entryURL.appending(path: RecordingExtensionArtifacts.combinedFileName)
        )
        let outcome = try await extendAudio(target: session.target, segmentURL: segmentURL)
        RecordingExtensionRecovery.removeArtifacts(in: entryURL)
        return outcome
    }

    func saveRecoveredExtensionAsNewEntry(
        _ recovery: RecoverableRecordingExtension
    ) async throws -> RelativePath {
        guard let segmentName = recovery.segmentFileName else {
            throw VaultError.notFound("Recoverable extension segment")
        }
        let sourceEntryURL = rootURL.appendingRelativePath(recovery.entryRelativePath)
        let segmentURL = sourceEntryURL.appending(path: segmentName)
        let duration = try await AudioImportFormat.probeDuration(of: segmentURL)
        let parent = recovery.entryRelativePath.parentRelativePath
        // Build the whole entry out of sight and reveal it with one rename:
        // a termination mid-recovery must not leave a phantom entry behind.
        let date = Date.now
        let staging = try EntryStaging(vaultRoot: rootURL)
        let newPath: RelativePath
        do {
            let extensionName = AudioImportFormat.normalizedExtension(of: segmentName)
            let audioName = extensionName == "m4a" ? "audio.m4a" : "audio.caf"
            let audioURL = staging.url.appending(path: audioName)
            try FileManager.default.copyItem(at: segmentURL, to: audioURL)
            let waveform = try await WaveformGenerator.generate(fromAudioAt: audioURL)
            try EntryCreator.writeRecordingStub(
                entryURL: staging.url, created: date, duration: duration
            )
            try waveform.write(to: WaveformData.url(inEntry: staging.url))
            newPath = try staging.commit(
                inFolder: parent, date: date, slug: "recovered-extension"
            )
        } catch {
            staging.discard()
            throw error
        }
        RecordingExtensionRecovery.removeArtifacts(in: sourceEntryURL)
        synchronizeSearchIndex(relativePaths: [recovery.entryRelativePath, newPath])
        return newPath
    }

    func discardRecoveredExtension(_ recovery: RecoverableRecordingExtension) {
        let entryURL = rootURL.appendingRelativePath(recovery.entryRelativePath)
        RecordingExtensionRecovery.removeArtifacts(in: entryURL)
        synchronizeSearchIndex(relativePaths: [recovery.entryRelativePath])
    }

    private func convergeRecoveredExtensionSwap(
        _ recovery: RecoverableRecordingExtension
    ) async throws -> AudioExtensionOutcome {
        let entryURL = rootURL.appendingRelativePath(recovery.entryRelativePath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard let audioName = VaultScanner.audioFile(in: names) else {
            throw VaultError.notFound(recovery.entryRelativePath.appendingComponent("audio"))
        }
        // The staged wrapper's sidecar recorded the entry path as it was when
        // the swap started. Prefer an exact match, but fall back to the
        // entry's stable identity so a rename since then cannot strand a swap
        // that has already happened on disk.
        let trashItems = try trash.items().filter { $0.kind == .preExtensionAudio }
        guard let staged = trashItems.first(where: {
            $0.originalPath == recovery.entryRelativePath
        }) ?? trashItems
            .filter({ EntryIdentity.sameEntry($0.originalPath, recovery.entryRelativePath) })
            .max(by: { $0.deletedAt < $1.deletedAt })
        else {
            throw RecordingExtensionError.sourceChanged
        }
        let audioURL = entryURL.appending(path: audioName)
        let duration = try await AudioImportFormat.probeDuration(of: audioURL)
        let plan = RecordingExtensionDurationPlan(
            sourceDuration: recovery.session.target.sourceDuration,
            segmentDuration: recovery.session.segmentDuration
        )
        guard plan.accepts(actualDuration: duration) else {
            throw RecordingExtensionError.invalidCombinedDuration(
                expected: plan.expectedCombinedDuration, actual: duration
            )
        }
        let waveform = try await WaveformGenerator.generate(fromAudioAt: audioURL)
        try waveform.write(to: WaveformData.url(inEntry: entryURL))
        try EntryMetadata.setDuration(duration, inEntry: entryURL, editedAt: Date())
        RecordingExtensionRecovery.removeArtifacts(in: entryURL)
        synchronizeSearchIndex(relativePaths: [recovery.entryRelativePath])
        recordClipEdit(
            .extend,
            entryPath: recovery.entryRelativePath,
            trashedName: staged.trashedName
        )
        return AudioExtensionOutcome(
            audioFileName: audioName,
            combinedDuration: duration,
            normalized: audioName != recovery.session.target.sourceAudioFileName,
            trashedName: staged.trashedName
        )
    }

    private func writeExtensionManifest(
        _ session: RecordingExtensionSession, in entryURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            try encoder.encode(session),
            to: entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
        )
    }

    func readTranscript(atEntryPath relPath: RelativePath) -> FrontmatterDocument? {
        guard let url = TranscriptFile.url(inEntry: rootURL.appendingRelativePath(relPath)),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FrontmatterDocument.parse(text)
    }

    func readTranscriptContent(
        atEntryPath relPath: RelativePath,
        duration: TimeInterval?
    ) -> EntryTranscriptContent {
        let entryURL = rootURL.appendingRelativePath(relPath)
        let edited: FrontmatterDocument?
        if let url = TranscriptFile.url(inEntry: entryURL),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            edited = FrontmatterDocument.parse(text)
        } else {
            edited = nil
        }
        let original = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        let extensionState = ExtensionTranscriptState.load(from: entryURL)
        let wordMap = original.map {
            TranscriptWordMap(
                transcript: $0,
                duration: extensionState?.knownTranscriptDuration ?? duration,
                speakerNames: edited.map { SpeakerNames.names(in: $0) } ?? [:]
            )
        }
        return EntryTranscriptContent(
            edited: edited,
            original: original,
            extensionState: extensionState,
            wordMap: wordMap,
            isForked: edited.map {
                TranscriptEditDocument.isForked($0, comparedTo: original)
            } ?? false
        )
    }

    /// Builds a read-only projection from files inside `.trash`. The resolver
    /// may decode audio to make an in-memory waveform, but never writes a
    /// cache into the deleted payload.
    func trashPreview(for item: TrashItem) async -> TrashPreview {
        await TrashPreviewResolver(vaultRoot: rootURL).resolve(item)
    }

    // MARK: - Search cache

    /// Opens and fully reconciles the rebuildable cache. AppModel starts this
    /// in an unstructured task after the vault becomes usable, so a large
    /// first rebuild never holds up window navigation on the main actor.
    func initializeSearchIndex() throws {
        let databaseURL = VaultSearchIndex.defaultDatabaseURL(forVault: rootURL)
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        let index = try VaultSearchIndex(vaultRoot: rootURL, databaseURL: databaseURL)
        // VaultSearchIndex builds a brand-new cache during initialization.
        // An existing cache is reconciled against the vault: every entry
        // carries a fingerprint of the files it was built from, so entries
        // untouched since the last launch are left alone and only genuinely
        // changed ones are re-read. A reconcile that cannot complete falls
        // back to the full rebuild, which is always correct.
        if existed {
            do { try index.reconcile() } catch { try index.rebuild() }
        }
        searchIndex = index
    }

    func search(_ query: String, fuzzy: Bool, limit: Int = 150) throws -> [SearchHit] {
        guard let searchIndex else {
            throw SearchIndexError.sqlite("The vault is still being indexed")
        }
        do {
            return try searchIndex.search(query, fuzzy: fuzzy, limit: limit)
        } catch is CancellationError {
            // A superseded keystroke abandoning its scan is not damage; without
            // this the abort would be read as a corrupt cache and trigger a
            // full rebuild of the entire vault on every fast typist.
            throw CancellationError()
        } catch {
            _ = try searchIndex.recoverIfNeeded()
            return try searchIndex.search(query, fuzzy: fuzzy, limit: limit)
        }
    }

    /// File-event paths remain coalesced by FSEvents. The index reconciler
    /// removes vanished records and re-reads only entries intersecting those
    /// paths, including every child of a renamed folder.
    func synchronizeSearchIndex(changedAbsolutePaths: [String]) {
        guard let searchIndex else { return }
        do {
            try searchIndex.synchronize(changedAbsolutePaths: changedAbsolutePaths)
        } catch {
            do {
                _ = try searchIndex.recoverIfNeeded()
                try searchIndex.synchronize(changedAbsolutePaths: changedAbsolutePaths)
            } catch {
                DebugLog.append("search index sync FAILED: \(error)")
            }
        }
    }

    /// Single-entry refresh for in-app writes (autosave). A known entry path
    /// needs no vault walk — re-read exactly that entry — which matters
    /// because this runs on every save, not once per external event.
    func synchronizeSearchEntry(at relativePath: RelativePath) {
        guard let searchIndex else { return }
        do {
            try searchIndex.upsertEntry(at: relativePath)
        } catch {
            do {
                _ = try searchIndex.recoverIfNeeded()
                try searchIndex.upsertEntry(at: relativePath)
            } catch {
                DebugLog.append("search index entry sync FAILED: \(error)")
            }
        }
    }

    /// Multi-path and whole-vault reconciliation stay on the conservative
    /// walk: a rename or move changes paths the caller cannot enumerate.
    private func synchronizeSearchIndex(relativePaths: [RelativePath]) {
        synchronizeSearchIndex(changedAbsolutePaths: relativePaths.map {
            rootURL.appendingRelativePath($0).path
        })
    }

    /// Re-reads frontmatter at save time, replaces only the body, and writes
    /// atomically. This keeps metadata and unknown YAML fields intact even
    /// when another in-app operation updated them after the editor opened.
    func saveTranscriptBody(
        _ body: String,
        markHandEdited: Bool,
        clearHandEdited: Bool = false,
        atEntryPath relPath: RelativePath
    ) throws -> FrontmatterDocument {
        let entryURL = rootURL.appendingRelativePath(relPath)
        guard let transcriptURL = TranscriptFile.url(inEntry: entryURL) else {
            throw VaultError.notFound("Transcript for \(relPath)")
        }
        var editable = try TranscriptEditDocument.load(from: transcriptURL)
        editable.replaceBody(body, markHandEdited: markHandEdited)
        if markHandEdited { editable.markHandEdited() }
        if clearHandEdited { editable.clearHandEdited() }
        try editable.save(to: transcriptURL)
        synchronizeSearchIndex(relativePaths: [relPath])
        return editable.document
    }

    /// Loads the entry's `waveform.json`, generating (and caching) it from the
    /// audio file when missing or unreadable — so deleting the file in Finder
    /// simply causes a rebuild on next open (PLY-3).
    func waveform(forEntryAt relPath: RelativePath, audioFileName: String) async throws -> WaveformData {
        let entryURL = rootURL.appendingRelativePath(relPath)
        let cacheURL = WaveformData.url(inEntry: entryURL)
        if let cached = WaveformData.load(from: cacheURL) { return cached }
        let waveform = try await WaveformGenerator.generate(
            fromAudioAt: entryURL.appending(path: audioFileName)
        )
        try waveform.write(to: cacheURL)
        return waveform
    }

    func audioSupportsExtension(atEntryPath relPath: RelativePath) async -> Bool {
        guard let audioName = audioFileName(atEntryPath: relPath) else { return false }
        let asset = AVURLAsset(
            url: rootURL.appendingRelativePath(relPath).appending(path: audioName)
        )
        guard (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false else {
            return false
        }
        return AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) != nil
    }

    // MARK: - Entry creation (M2: recording & import)

    /// Creates the (still empty) entry folder a new recording streams into.
    func createEntryFolder(inFolder parent: RelativePath, date: Date) throws -> RelativePath {
        let path = try EntryCreator(vaultRoot: rootURL)
            .createEntryFolder(inFolder: parent, date: date)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    /// Removes an entry folder that never got any content (recording failed
    /// to start). Refuses non-empty folders.
    func removeEmptyEntryFolder(at relPath: RelativePath) throws {
        guard EntryFolderName(parsing: relPath.lastComponent) != nil else { return }
        let url = rootURL.appendingRelativePath(relPath)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.isEmpty else { return }
        try FileManager.default.removeItem(at: url)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    /// Imports one audio file: probes it (per-file error for corrupt/misnamed
    /// files), then copies it into a new entry with a stub transcript.
    func importAudioFile(from sourceURL: URL, toFolder parent: RelativePath) async throws -> RelativePath {
        let duration = try await AudioImportFormat.probeDuration(of: sourceURL)
        let path = try EntryCreator(vaultRoot: rootURL)
            .importFile(from: sourceURL, toFolder: parent, date: .now, duration: duration)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    // MARK: - Folder / entry mutations

    func createFolder(named name: String, inFolder parent: RelativePath) throws -> RelativePath {
        try operations.createFolder(named: name, inFolder: parent)
    }

    func renameFolder(at relPath: RelativePath, to newName: String) throws -> RelativePath {
        let newPath = try operations.renameFolder(at: relPath, to: newName)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    func renameEntry(at relPath: RelativePath, toTitle title: String) throws -> RelativePath {
        let newPath = try operations.renameEntry(at: relPath, toTitle: title)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    func moveItem(at relPath: RelativePath, toFolder destFolder: RelativePath) throws -> RelativePath {
        let newPath = try operations.moveItem(at: relPath, toFolder: destFolder)
        synchronizeSearchIndex(relativePaths: [relPath, newPath])
        return newPath
    }

    func duplicateEntry(at relPath: RelativePath) throws -> RelativePath {
        let newPath = try operations.duplicateEntry(at: relPath)
        synchronizeSearchIndex(relativePaths: [newPath])
        return newPath
    }

    /// Favorite toggle (LIB-3): a frontmatter-only write — the body is left
    /// byte-identical, so it can never fork the entry, and the search index
    /// (title + content only) needs no re-sync.
    func setFavorite(_ favorite: Bool, atEntryPath relPath: RelativePath) throws {
        try EntryFrontmatter.update(
            inEntry: rootURL.appendingRelativePath(relPath), createIfMissing: favorite
        ) { doc in
            doc.favorite = favorite
        }
    }

    /// Per-entry silence source. Re-read and atomically rewrite only the
    /// frontmatter line so concurrent metadata and unknown YAML survive.
    func setSilenceDetectionMode(
        _ mode: SilenceDetectionMode, atEntryPath relPath: RelativePath
    ) throws {
        let entryURL = rootURL.appendingRelativePath(relPath)
        try EntryMetadata.setSilenceDetectionMode(mode, inEntry: entryURL)
    }

    // MARK: - Transcription (M3)

    /// Applies one finished transcription (correction backstop, archive,
    /// `transcript.original.json`, `transcript.md`, auto-title) on this actor
    /// so the writes serialize with every other vault mutation.
    func applyTranscription(
        segments: [TranscriptOriginal.Segment],
        toEntryAt relPath: RelativePath,
        engine: TranscriptOriginal.EngineMetadata,
        engineFrontmatterID: String,
        vocabularyTerms: [String]
    ) throws -> TranscriptionApplier.Outcome {
        let outcome = try TranscriptionApplier(vaultRoot: rootURL).apply(
            segments: segments,
            toEntryAt: relPath,
            engine: engine,
            engineFrontmatterID: engineFrontmatterID,
            vocabularyTerms: vocabularyTerms,
            date: .now
        )
        synchronizeSearchIndex(relativePaths: [relPath, outcome.entryRelativePath])
        return outcome
    }

    // MARK: - Audio lifecycle (AUD-1)

    /// Byte size of the entry's audio file, for the Delete Audio warning.
    func audioFileByteSize(atEntryPath relPath: RelativePath) -> Int64? {
        guard let name = audioFileName(atEntryPath: relPath) else { return nil }
        let url = rootURL.appendingRelativePath(relPath).appending(path: name)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Moves the entry's audio (and waveform cache) to Recently Deleted and
    /// flags the frontmatter; the transcript stays behind as a plain note.
    func deleteAudio(atEntryPath relPath: RelativePath) throws {
        try trash.trashEntryAudio(atEntryPath: relPath)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    /// Trim (AUD-3): exports the kept range, stages the pre-trim audio in
    /// Recently Deleted, swaps the trimmed file in, and updates the
    /// frontmatter duration. The caller enqueues the retranscription.
    func trimAudio(atEntryPath relPath: RelativePath, selection: TrimSelection) async throws -> TrimApplier.Outcome {
        guard let audioName = audioFileName(atEntryPath: relPath) else {
            throw VaultError.notFound(relPath.appendingComponent("audio"))
        }
        let audioURL = rootURL.appendingRelativePath(relPath).appending(path: audioName)
        let exported = try await AudioTrimExport.export(from: audioURL, keeping: selection)
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        // The exporter trims on packet boundaries; probe the real duration
        // rather than trusting the requested range.
        let newDuration = (try? await AudioImportFormat.probeDuration(of: exported.url))
            ?? selection.length
        let outcome = try TrimApplier(vaultRoot: rootURL).apply(
            trimmedFileAt: exported.url,
            fileName: exported.fileName,
            newDuration: newDuration,
            toEntryAt: relPath
        )
        recordClipEdit(.trim, entryPath: relPath, trashedName: outcome.trashedName)
        synchronizeSearchIndex(relativePaths: [relPath])
        return outcome
    }

    /// Removes detected silence runs longer than 1.5 seconds, validates a
    /// rendered M4A, and safely stages the original before installing it.
    /// The caller owns player coordination and full retranscription queueing.
    func compressAudio(
        atEntryPath relPath: RelativePath
    ) async throws -> AudioCompressionApplier.Outcome {
        guard let audioName = audioFileName(atEntryPath: relPath) else {
            throw VaultError.notFound(relPath.appendingComponent("audio"))
        }
        let entryURL = rootURL.appendingRelativePath(relPath)
        let audioURL = entryURL.appending(path: audioName)
        // The persisted frontmatter is authoritative at mutation time. A
        // stale view can never route a destructive edit through another mode.
        let mode = readTranscript(atEntryPath: relPath)?.silenceDetectionMode ?? .waveform
        let plan = try await AudioCompressionPlanner.makePlan(
            mode: mode, audioURL: audioURL, entryURL: entryURL
        )
        guard !plan.removedIntervals.isEmpty else {
            throw AudioCompressionError.noLongSilence
        }
        let rendered = try await AudioCompressionRenderer.render(
            sourceURL: audioURL, plan: plan
        )
        defer { try? FileManager.default.removeItem(at: rendered.url.deletingLastPathComponent()) }
        let sourceSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let renderedSize = try rendered.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize == 0 || renderedSize < sourceSize else {
            throw AudioCompressionError.notSmaller
        }
        let outcome = try AudioCompressionApplier(vaultRoot: rootURL).apply(
            renderedFileAt: rendered.url,
            expectedSourceFileName: audioName,
            sourceDuration: plan.sourceDuration,
            compressedDuration: rendered.duration,
            removedDuration: plan.removedDuration,
            toEntryAt: relPath
        )
        recordClipEdit(.compress, entryPath: relPath, trashedName: outcome.trashedName)
        synchronizeSearchIndex(relativePaths: [relPath])
        return outcome
    }

    /// EXT-4/5: combine into a hidden output, validate duration, safely swap,
    /// regenerate the waveform, and leave transcription queueing to AppModel.
    func extendAudio(
        target: RecordingExtensionTarget, segmentURL: URL
    ) async throws -> AudioExtensionOutcome {
        let entryURL = rootURL.appendingRelativePath(target.entryRelativePath)
        guard audioFileName(atEntryPath: target.entryRelativePath) == target.sourceAudioFileName else {
            throw RecordingExtensionError.sourceChanged
        }
        do {
            try updateExtensionManifest(in: entryURL, to: .composing)
            if AudioExtensionFailureInjector.shared.consume(.beforeComposition) {
                throw AudioExtensionInjectedError.forced(.beforeComposition)
            }
            let sourceURL = entryURL.appending(path: target.sourceAudioFileName)
            let outputURL = entryURL.appending(path: RecordingExtensionArtifacts.combinedFileName)
            let composed = try await AudioExtensionComposer.compose(
                sourceURL: sourceURL, segmentURL: segmentURL, outputURL: outputURL
            )
            try updateExtensionManifest(in: entryURL, to: .combinedReady)
            if AudioExtensionFailureInjector.shared.consume(.beforeSafeSwap) {
                throw AudioExtensionInjectedError.forced(.beforeSafeSwap)
            }
            try updateExtensionManifest(in: entryURL, to: .swapping)
            let base = (target.sourceAudioFileName as NSString).deletingPathExtension
            let finalName = (base.isEmpty ? "audio" : base) + ".m4a"
            let applied = try AudioExtensionApplier(vaultRoot: rootURL).apply(
                combinedFileAt: composed.url,
                fileName: finalName,
                combinedDuration: composed.duration,
                previousTranscriptDuration: target.sourceDuration,
                normalizedToM4A: composed.normalized,
                expectedSourceFileName: target.sourceAudioFileName,
                toEntryAt: target.entryRelativePath
            )
            recordClipEdit(
                .extend,
                entryPath: target.entryRelativePath,
                trashedName: applied.trashedName
            )
            if AudioExtensionFailureInjector.shared.consume(.afterSafeSwap) {
                // Keep the manifest at `.swapping` and the segment in place.
                // Relaunch recovery can prove the visible combined audio and
                // converge cleanup without composing or appending again.
                throw AudioExtensionInjectedError.forced(.afterSafeSwap)
            }
            try? FileManager.default.removeItem(at: segmentURL)
            do {
                let waveform = try await WaveformGenerator.generate(
                    fromAudioAt: entryURL.appending(path: applied.audioFileName)
                )
                try waveform.write(to: WaveformData.url(inEntry: entryURL))
            } catch {
                // The combined audio is already valid and installed. Waveform
                // is a derived cache and will regenerate on the next open.
                DebugLog.append("extension waveform regeneration deferred: \(error)")
            }
            synchronizeSearchIndex(relativePaths: [target.entryRelativePath])
            return AudioExtensionOutcome(
                audioFileName: applied.audioFileName,
                combinedDuration: applied.combinedDuration,
                normalized: composed.normalized,
                trashedName: applied.trashedName
            )
        } catch AudioExtensionInjectedError.forced(.afterSafeSwap) {
            throw AudioExtensionInjectedError.forced(.afterSafeSwap)
        } catch {
            failExtensionManifest(in: entryURL, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Replace selected audio (RPL)

    func saveReplacementSession(_ session: ReplacementTakeSession) throws {
        let entryURL = rootURL.appendingRelativePath(session.entryRelativePath)
        let directory = entryURL.appending(
            path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            encoder.encode(session),
            to: directory.appending(path: AudioReplacementArtifacts.sessionFileName)
        )
    }

    private struct OrphanedReplacementTake {
        var id: UUID
        var fileName: String
        var capturedFrames: Int64
        var sampleRate: Double
        var createdAt: Date
        var status: ReplacementTakeStatus
    }

    /// `finalizeReplacementTake` installs the completed take before AppModel
    /// appends it to the session manifest. A hard termination in that small
    /// window must not strand valid audio that is no longer represented by the
    /// crash journal. Only canonical, session-local take files are candidates;
    /// previews, render candidates, exact/temp files, symlinks, and arbitrary
    /// audio files remain untouched.
    private func adoptingOrphanedReplacementTakes(
        from directory: URL,
        into session: ReplacementTakeSession
    ) -> ReplacementTakeSession {
        guard session.region.frameCount > 0,
              session.region.sampleRate.isFinite,
              session.region.sampleRate > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return session }

        let referencedIDs = Set(session.takes.map(\.id))
        let referencedNames = Set(session.takes.map(\.fileName))
        var claimedIDs = referencedIDs
        var candidates: [OrphanedReplacementTake] = []

        for name in names.sorted() {
            guard !referencedNames.contains(name),
                  let identity = Self.canonicalReplacementTakeIdentity(fileName: name),
                  !claimedIDs.contains(identity.id),
                  let inspection = Self.inspectOrphanedReplacementTake(
                    at: directory.appending(path: name),
                    for: session.region
                  )
            else { continue }
            claimedIDs.insert(identity.id)
            candidates.append(OrphanedReplacementTake(
                id: identity.id,
                fileName: name,
                capturedFrames: inspection.frames,
                sampleRate: inspection.sampleRate,
                createdAt: inspection.createdAt,
                status: inspection.status
            ))
        }

        guard !candidates.isEmpty else { return session }
        let highestExistingNumber = max(0, session.takes.map(\.number).max() ?? 0)
        guard highestExistingNumber <= Int.max - candidates.count else {
            DebugLog.append("replacement orphan recovery deferred: take number overflow")
            return session
        }

        var recovered = session
        for (offset, candidate) in candidates.enumerated() {
            recovered.appendTake(ReplacementTake(
                id: candidate.id,
                number: highestExistingNumber + offset + 1,
                fileName: candidate.fileName,
                capturedFrames: candidate.capturedFrames,
                sampleRate: candidate.sampleRate,
                createdAt: candidate.createdAt,
                status: candidate.status
            ))
        }
        recovered.failureMessage = nil

        do {
            // One atomic ledger replacement adopts the entire deterministic
            // candidate set. On failure the old session remains authoritative
            // and the audio files stay available for the next discovery.
            try saveReplacementSession(recovered)
            return recovered
        } catch {
            DebugLog.append("replacement orphan recovery deferred: \(error)")
            return session
        }
    }

    private nonisolated static func canonicalReplacementTakeIdentity(
        fileName: String
    ) -> (id: UUID, fileExtension: String)? {
        let path = fileName as NSString
        let fileExtension = path.pathExtension
        guard fileExtension == "m4a" || fileExtension == "caf" else { return nil }
        let stem = path.deletingPathExtension
        guard stem.hasPrefix("take-") else { return nil }
        let rawID = String(stem.dropFirst("take-".count))
        guard let id = UUID(uuidString: rawID),
              fileName == AudioReplacementArtifacts.takeFileName(
                id: id, fileExtension: fileExtension
              )
        else { return nil }
        return (id, fileExtension)
    }

    private nonisolated static func inspectOrphanedReplacementTake(
        at url: URL,
        for region: ReplacementRegion
    ) -> (frames: Int64, sampleRate: Double, createdAt: Date, status: ReplacementTakeStatus)? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .creationDateKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }

            let file = try AVAudioFile(forReading: url)
            defer { file.close() }
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let expectedFrames = Int64(file.length)
            guard sampleRate.isFinite,
                  abs(sampleRate - region.sampleRate) < 0.001,
                  format.channelCount > 0,
                  expectedFrames > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(min(expectedFrames, 16_384))
                  )
            else { return nil }

            var decodedFrames: Int64 = 0
            while decodedFrames < expectedFrames {
                let remaining = expectedFrames - decodedFrames
                let requested = AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity)))
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { return nil }
                decodedFrames += Int64(buffer.frameLength)
            }
            guard decodedFrames == expectedFrames else { return nil }

            let status: ReplacementTakeStatus
            switch ReplacementTakeEligibility.classify(
                capturedFrames: decodedFrames,
                capturedSampleRate: sampleRate,
                for: region
            ) {
            case .eligible:
                status = .complete
            case .incomplete:
                status = .incomplete
            case .tooLong, .wrongSampleRate:
                return nil
            }
            return (
                decodedFrames,
                sampleRate,
                values.creationDate ?? values.contentModificationDate ?? .distantPast,
                status
            )
        } catch {
            return nil
        }
    }

    /// Relaunch recovery for duration-locked attempts. A crash journal is
    /// promoted to a playable CAF take without ever baking it automatically.
    func replacementTakeSessions() -> ReplacementSessionDiscovery {
        var sessions: [ReplacementTakeSession] = []
        var committed: [RelativePath] = []
        var microphoneObservations: [RecoveredMicrophoneCaptureObservation] = []
        for entry in scanner.scan(root: rootURL).allEntries {
            let entryURL = rootURL.appendingRelativePath(entry.relativePath)
            let cancellationMarker = entryURL.appending(
                path: AudioReplacementArtifacts.cancellationMarkerFileName
            )
            if ReplacementSessionDisposition.classify(
                hasCancellationMarker: FileManager.default.fileExists(
                    atPath: cancellationMarker.path
                )
            ) == .discard {
                // Cancellation is authoritative even if the process died
                // between recording the intent and deleting temporary takes.
                try? discardReplacementArtifacts(in: entryURL)
                continue
            }
            let directory = entryURL.appending(
                path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory
            )
            let manifest = directory.appending(path: AudioReplacementArtifacts.sessionFileName)
            guard let data = try? Data(contentsOf: manifest),
                  var session = try? JSONDecoder().decode(
                    ReplacementTakeSession.self, from: data
                  )
            else { continue }
            if session.entryRelativePath != entry.relativePath {
                // The manifest lives inside this entry, so the folder is
                // authoritative: the entry was renamed or moved (an in-app
                // rename rewrites the slug too) after the session was written.
                // Skipping it would strand the takes forever; every
                // destructive step downstream still re-validates the source
                // audio and the frame-locked timeline before touching it.
                session.entryRelativePath = entry.relativePath
                // Best effort — an unwritable manifest must not strand takes
                // that the in-memory session can still reach.
                try? saveReplacementSession(session)
            }
            if session.phase == .swapping || session.phase == .retranscribing,
               let selectedID = session.selectedTakeID,
               AudioReplacementStore.loadRecipe(in: entryURL)?.sources
                .contains(where: { $0.id == selectedID }) == true {
                committed.append(session.entryRelativePath)
                try? cancelReplacementSession(entryRelativePath: session.entryRelativePath)
                continue
            }
            session = adoptingOrphanedReplacementTakes(from: directory, into: session)
            let partial = entryURL.appending(path: AudioReplacementArtifacts.partialFileName)
            // Undo a close-time size patch severed by power loss before the
            // journal is read; a no-op for intact files.
            DurableAudioJournalWriter.repairDataChunkSize(at: partial)
            if FileManager.default.fileExists(atPath: partial.path),
               let file = try? AVAudioFile(forReading: partial) {
                if let inspection = try? MicrophoneJournalInspector.inspect(partial) {
                    microphoneObservations.append(.init(
                        sessionID: session.id,
                        inspection: inspection
                    ))
                }
                let id = UUID()
                let name = AudioReplacementArtifacts.takeFileName(
                    id: id, fileExtension: "caf"
                )
                let destination = directory.appending(path: name)
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partial, to: destination)
                    let captured = min(Int64(file.length), session.region.frameCount)
                    let eligibility = ReplacementTakeEligibility.classify(
                        capturedFrames: Int64(file.length),
                        capturedSampleRate: session.region.sampleRate,
                        for: session.region
                    )
                    session.appendTake(ReplacementTake(
                        id: id,
                        number: session.takes.count + 1,
                        fileName: name,
                        capturedFrames: captured,
                        sampleRate: session.region.sampleRate,
                        createdAt: .now,
                        status: eligibility == .eligible || Int64(file.length) >= session.region.frameCount
                            ? .complete : .incomplete
                    ))
                    try? saveReplacementSession(session)
                } catch {
                    DebugLog.append("replacement partial recovery deferred: \(error)")
                }
            }
            session.phase = .ready
            sessions.append(session)
        }
        return ReplacementSessionDiscovery(
            recoverable: sessions.sorted { $0.id.uuidString < $1.id.uuidString },
            committedEntryPaths: committed,
            microphoneObservations: microphoneObservations
        )
    }

    func replacementTakeURL(
        entryRelativePath: RelativePath, fileName: String
    ) -> URL {
        rootURL.appendingRelativePath(entryRelativePath)
            .appending(path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    func replacementTakeWaveform(
        entryRelativePath: RelativePath, fileName: String
    ) async throws -> WaveformData {
        try await WaveformGenerator.generate(
            fromAudioAt: replacementTakeURL(
                entryRelativePath: entryRelativePath, fileName: fileName
            )
        )
    }

    func deleteReplacementTake(
        entryRelativePath: RelativePath, fileName: String
    ) throws {
        try FileManager.default.removeItem(
            at: replacementTakeURL(entryRelativePath: entryRelativePath, fileName: fileName)
        )
    }

    func cancelReplacementSession(entryRelativePath: RelativePath) throws {
        let entryURL = rootURL.appendingRelativePath(entryRelativePath)
        // Persist the user's decision before deleting anything. A crash or
        // filesystem error can leave this marker behind; discovery treats it
        // as a discard request and never resurrects the cancelled take list.
        try AtomicFile.write(
            Data("cancelled".utf8),
            to: entryURL.appending(path: AudioReplacementArtifacts.cancellationMarkerFileName)
        )
        try discardReplacementArtifacts(in: entryURL)
    }

    private func discardReplacementArtifacts(in entryURL: URL) throws {
        let fm = FileManager.default
        let directory = entryURL.appending(
            path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory
        )
        let partial = entryURL.appending(path: AudioReplacementArtifacts.partialFileName)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        let marker = entryURL.appending(
            path: AudioReplacementArtifacts.cancellationMarkerFileName
        )
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
    }

    func replacementContextPreview(
        session: ReplacementTakeSession, take: ReplacementTake
    ) async throws -> URL {
        let entryURL = rootURL.appendingRelativePath(session.entryRelativePath)
        guard audioFileName(atEntryPath: session.entryRelativePath) == session.sourceAudioFileName else {
            throw AudioReplacementError.sourceChanged
        }
        return try await AudioReplacementPreviewRenderer.render(
            canonicalURL: entryURL.appending(path: session.sourceAudioFileName),
            takeURL: replacementTakeURL(
                entryRelativePath: session.entryRelativePath, fileName: take.fileName
            ),
            region: session.region
        )
    }

    /// Reads the canonical asset duration at replacement-session creation time.
    /// Entry frontmatter intentionally rounds duration for readability and is
    /// therefore not precise enough to define a frame-locked edit timeline.
    func replacementTimeline(
        entryRelativePath: RelativePath, audioFileName: String
    ) async throws -> ReplacementTimeline {
        guard self.audioFileName(atEntryPath: entryRelativePath) == audioFileName else {
            throw AudioReplacementError.sourceChanged
        }
        let audioURL = rootURL.appendingRelativePath(entryRelativePath)
            .appending(path: audioFileName)
        let duration = try await AudioImportFormat.probeDuration(of: audioURL)
        return ReplacementTimeline(duration: duration)
    }

    func bakeReplacement(
        session: ReplacementTakeSession,
        take: ReplacementTake,
        injectedFailurePoint: AudioReplacementFailurePoint? = nil
    ) async throws -> AudioReplacementApplier.Outcome {
        guard session.selectedTakeCanBake, take.id == session.selectedTakeID else {
            throw AudioReplacementError.invalidRecipe
        }
        let entryURL = rootURL.appendingRelativePath(session.entryRelativePath)
        guard audioFileName(atEntryPath: session.entryRelativePath) == session.sourceAudioFileName else {
            throw AudioReplacementError.sourceChanged
        }
        let sourceURL = entryURL.appending(path: session.sourceAudioFileName)
        let canonicalDuration = try await AudioImportFormat.probeDuration(of: sourceURL)
        let lockedTimeline = ReplacementTimeline(
            duration: session.timelineDuration, sampleRate: session.region.sampleRate
        )
        guard lockedTimeline.matches(
            duration: canonicalDuration,
            toleranceFrames: ReplacementTimeline.roundedMetadataToleranceFrames(
                sampleRate: session.region.sampleRate
            )
        ) else {
            throw AudioReplacementError.sourceChanged
        }
        let sourceBytes = Int64(
            (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        try AudioReplacementStore.ensureDiskSpace(
            at: entryURL, estimatedBytes: max(32 * 1_024 * 1_024, sourceBytes * 3)
        )
        let takeURL = replacementTakeURL(
            entryRelativePath: session.entryRelativePath, fileName: take.fileName
        )
        var durableSession = session
        durableSession.phase = .rendering
        try saveReplacementSession(durableSession)
        let prepared = try AudioReplacementStore.prepare(
            entryURL: entryURL,
            canonicalAudioURL: sourceURL,
            canonicalDuration: canonicalDuration,
            takeURL: takeURL,
            take: take,
            region: session.region
        )
        let candidate = entryURL.appending(path: AudioReplacementArtifacts.candidateFileName)
        if injectedFailurePoint == .beforeRender {
            throw AudioReplacementInjectedError.forced(.beforeRender)
        }
        let rendered = try await AudioReplacementRenderer.render(
            recipe: prepared.recipe,
            sourcesDirectory: prepared.directoryURL,
            outputURL: candidate
        )
        durableSession.phase = .swapping
        try saveReplacementSession(durableSession)
        if injectedFailurePoint == .beforeSafeSwap {
            throw AudioReplacementInjectedError.forced(.beforeSafeSwap)
        }
        let outcome = try AudioReplacementApplier(vaultRoot: rootURL).apply(
            renderedFileAt: rendered.url,
            nextHistoryDirectory: prepared.directoryURL,
            expectedSourceFileName: session.sourceAudioFileName,
            duration: rendered.duration,
            toEntryAt: session.entryRelativePath
        )
        recordClipEdit(
            .replace,
            entryPath: session.entryRelativePath,
            trashedName: outcome.trashedName
        )
        do {
            let waveform = try await WaveformGenerator.generate(
                fromAudioAt: entryURL.appending(path: outcome.audioFileName)
            )
            try waveform.write(to: WaveformData.url(inEntry: entryURL))
        } catch {
            DebugLog.append("replacement waveform regeneration deferred: \(error)")
        }
        synchronizeSearchIndex(relativePaths: [session.entryRelativePath])
        return outcome
    }

    private func updateExtensionManifest(
        in entryURL: URL, to phase: RecordingExtensionPhase
    ) throws {
        let url = entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return }
        var session = try JSONDecoder().decode(RecordingExtensionSession.self, from: data)
        try session.transition(to: phase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(session), to: url)
    }

    private func failExtensionManifest(in entryURL: URL, message: String) {
        let url = entryURL.appending(path: RecordingExtensionArtifacts.manifestFileName)
        guard let data = try? Data(contentsOf: url),
              var session = try? JSONDecoder().decode(RecordingExtensionSession.self, from: data)
        else { return }
        session.fail(message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(session) {
            try? AtomicFile.write(encoded, to: url)
        }
    }

    /// The entry's audio file name (canonical `audio.*` preferred), nil when
    /// the folder has no audio.
    func audioFileName(atEntryPath relPath: RelativePath) -> String? {
        let url = rootURL.appendingRelativePath(relPath)
        let fileNames = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        return VaultScanner.audioFile(in: fileNames)
    }

    /// Speaker rename (TRN-6): stores machine-id → display-name mappings in
    /// the entry's frontmatter (`speaker_s1: "Alice"`; nil/empty removes) and
    /// regenerates the markdown labels for a never-hand-edited entry. The
    /// JSON keeps the stable machine ids untouched.
    func saveSpeakerNames(
        _ names: [String: String?], atEntryPath relPath: RelativePath
    ) throws {
        let entryURL = rootURL.appendingRelativePath(relPath)
        guard let transcriptURL = TranscriptFile.url(inEntry: entryURL),
              let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw VaultError.notFound("Transcript for \(relPath)")
        }
        var doc = FrontmatterDocument.parse(text)
        let original = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        // Decide regenerability against the *current* names before applying
        // the rename, so a previously regenerated labeled body still matches.
        let regenerable = !TranscriptEditDocument.isForked(doc, comparedTo: original)
        for (id, name) in names {
            SpeakerNames.set(name: name, forID: id, in: &doc)
        }
        if regenerable, let original {
            doc.body = "\n" + TranscriptMarkdown.body(
                from: original, speakerNames: SpeakerNames.names(in: doc)
            ) + "\n"
        }
        try AtomicFile.write(doc.serialized(), to: transcriptURL)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    func vocabularyTerms() -> [String] {
        VocabularyFile.load(fromVault: rootURL)
    }

    func saveVocabularyTerms(_ terms: [String]) throws {
        try VocabularyFile.save(terms, toVault: rootURL)
    }

    /// VOC-4 dry run: scans every transcribed entry for corrections `terms`
    /// would make, writing nothing. Cancellable between entries.
    func previewVocabularyReapply(terms: [String]) async throws -> [VocabularyReapply.EntryPreview] {
        let allTerms = vocabularyTerms()
        var previews: [VocabularyReapply.EntryPreview] = []
        for entry in scanner.scan(root: rootURL).allEntries {
            try Task.checkCancellation()
            let entryURL = rootURL.appendingRelativePath(entry.relativePath)
            guard let transcript = TranscriptOriginal.load(
                from: TranscriptOriginal.url(inEntry: entryURL)
            ) else { continue }
            let corrections = VocabularyReapply.preview(
                terms: terms, protectedBy: allTerms, transcript: transcript
            )
            if !corrections.isEmpty {
                previews.append(.init(
                    entryRelativePath: entry.relativePath, corrections: corrections
                ))
            }
        }
        return previews
    }

    /// VOC-4 apply: corrects the approved entries' JSON, regenerates
    /// still-generated markdown, and resyncs the search index.
    func applyVocabularyReapply(
        terms: [String], toEntriesAt paths: [RelativePath]
    ) throws -> VocabularyReapplyApplier.Summary {
        let summary = try VocabularyReapplyApplier(vaultRoot: rootURL).apply(
            terms: terms, protectedBy: vocabularyTerms(), toEntriesAt: paths
        )
        synchronizeSearchIndex(relativePaths: summary.changedEntryPaths)
        return summary
    }

    // MARK: - Trash

    func trashItem(atRelativePath relPath: RelativePath) throws {
        try trash.trashItem(atRelativePath: relPath)
        synchronizeSearchIndex(relativePaths: [relPath])
    }

    func trashItems() throws -> [TrashItem] {
        try trash.items()
    }

    func clipEditHistory(for entryPath: RelativePath) throws -> ClipEditEntryHistory {
        let names = Set(try trash.items().map(\.trashedName))
        return clipEditHistory.history(for: entryPath, existingTrashNames: names)
    }

    /// Atomically swaps the top undo/redo version into the selected entry,
    /// regenerates its derived audio state, and transfers the command to the
    /// opposite stack. The hand-edited Markdown body is never rewritten here.
    func performClipEditSwap(
        entryPath: RelativePath,
        direction: ClipEditDirection
    ) async throws -> ClipEditSwapOutcome? {
        let before = try trash.items()
        let names = Set(before.map(\.trashedName))
        let history = clipEditHistory.history(
            for: entryPath, existingTrashNames: names
        )
        let command: ClipEditCommand?
        switch direction {
        case .undo: command = history.undo.last
        case .redo: command = history.redo.last
        }
        guard let command,
              let item = before.first(where: {
                  $0.trashedName == command.versionTrashedName
                      && $0.originalPath == entryPath && $0.kind.isTimelineVersion
              }) else {
            try? clipEditHistory.reconcile(existingTrashNames: names)
            return nil
        }

        let restored = try trash.restoreAudioWithOutcome(item)
        guard let displacedName = restored.displacedTrashedName else {
            // There was no canonical audio to preserve as the inverse. The
            // requested restore succeeded, but continuing the keyboard chain
            // would falsely promise redo, so prune the consumed command.
            try? clipEditHistory.reconcile(
                existingTrashNames: Set(try trash.items().map(\.trashedName))
            )
            return nil
        }
        let afterNames = Set(try trash.items().map(\.trashedName))
        _ = try clipEditHistory.completeSwap(
            direction: direction,
            entryPath: entryPath,
            restoredVersionName: command.versionTrashedName,
            displacedVersionName: displacedName,
            existingTrashNames: afterNames.union([command.versionTrashedName])
        )

        let entryURL = rootURL.appendingRelativePath(entryPath)
        guard let audioName = audioFileName(atEntryPath: entryPath) else {
            throw VaultError.notFound(entryPath.appendingComponent("audio"))
        }
        let audioURL = entryURL.appending(path: audioName)
        let duration = try await AudioImportFormat.probeDuration(of: audioURL)
        try? EntryMetadata.setDuration(duration, inEntry: entryURL, editedAt: Date())
        try? TranscriptAlignmentState.markStale(inEntry: entryURL)
        do {
            let waveform = try await WaveformGenerator.generate(fromAudioAt: audioURL)
            try waveform.write(to: WaveformData.url(inEntry: entryURL))
        } catch {
            // The complete canonical version is already installed. Waveform
            // remains a rebuildable cache and EntryDetail will retry on load.
            DebugLog.append("undo/redo waveform regeneration deferred: \(error)")
        }
        synchronizeSearchIndex(relativePaths: [entryPath])
        return ClipEditSwapOutcome(
            operation: command.operation,
            entryRelativePath: entryPath,
            duration: duration
        )
    }

    /// A manual Recently Deleted timeline restore is itself a reversible clip
    /// operation. The displaced canonical wrapper becomes the undo target.
    func restoreTimelineVersion(_ item: TrashItem) throws -> AudioVersionRestoreOutcome {
        let outcome = try trash.restoreAudioWithOutcome(item)
        if let displaced = outcome.displacedTrashedName {
            recordClipEdit(
                .restoreVersion,
                entryPath: item.originalPath,
                trashedName: displaced
            )
        }
        synchronizeSearchIndex(relativePaths: [outcome.entryPath])
        return outcome
    }

    func restore(_ item: TrashItem) throws -> RelativePath {
        let path = try trash.restore(item)
        synchronizeSearchIndex(relativePaths: [path])
        return path
    }

    private func recordClipEdit(
        _ operation: ClipEditOperation,
        entryPath: RelativePath,
        trashedName: String
    ) {
        do {
            let names = Set(try trash.items().map(\.trashedName))
            try clipEditHistory.record(
                operation: operation,
                entryPath: entryPath,
                versionTrashedName: trashedName,
                existingTrashNames: names
            )
        } catch {
            // The version itself is still safe and visible in Recently
            // Deleted even if the optional shortcut ledger cannot be written.
            DebugLog.append("clip edit history write deferred: \(error)")
        }
    }

    func deletePermanently(_ item: TrashItem) throws {
        try trash.deletePermanently(item)
    }

    func emptyTrash() throws -> Int {
        try trash.deleteAllPermanently()
    }

    func purgeTrash() throws -> Int {
        try trash.purge(olderThanDays: settings.trashRetentionDays())
    }

    // MARK: - Storage & per-vault settings (AUD-6, SET-2)

    /// Full-vault size accounting for the Storage pane. Walks the tree on
    /// this actor so the main thread never touches the disk.
    func storageSummary() -> VaultStorageSummary {
        VaultStorage.measure(vaultRoot: rootURL)
    }

    func trashRetentionDays() -> Int {
        settings.trashRetentionDays()
    }

    func setTrashRetentionDays(_ days: Int) throws {
        try settings.setTrashRetentionDays(days)
    }
}
