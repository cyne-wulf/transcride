import Foundation
import AVFoundation

struct EntryTranscriptContent: Sendable {
    var edited: FrontmatterDocument?
    var original: TranscriptOriginal?
    var extensionState: ExtensionTranscriptState?
}

struct AudioExtensionOutcome: Sendable {
    var audioFileName: String
    var combinedDuration: Double
    var normalized: Bool
    var trashedName: String
}

/// Background actor owning all vault file I/O so the main thread never touches
/// the disk. Wraps the scanner (with its cache), mutation operations, and trash.
actor VaultService {
    let rootURL: URL
    private var scanner = VaultScanner()
    private let operations: VaultOperations
    private let trash: TrashStore
    private let settings: VaultSettingsStore
    private var searchIndex: VaultSearchIndex?

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.operations = VaultOperations(vaultRoot: rootURL)
        self.trash = TrashStore(vaultRoot: rootURL)
        self.settings = VaultSettingsStore(vaultRoot: rootURL)
    }

    // MARK: - Reading

    func snapshot() -> VaultSnapshot {
        scanner.scan(root: rootURL)
    }

    func recoverInterruptedRecordings() async -> InterruptedRecordingRecoverySummary {
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
        let newPath = try EntryCreator(vaultRoot: rootURL).createEntryFolder(
            inFolder: parent, date: .now, slug: "recovered-extension"
        )
        let newEntryURL = rootURL.appendingRelativePath(newPath)
        do {
            let extensionName = AudioImportFormat.normalizedExtension(of: segmentName)
            let audioName = extensionName == "m4a" ? "audio.m4a" : "audio.caf"
            let stagedURL = newEntryURL.appending(path: ".recovered-segment-\(audioName)")
            try FileManager.default.copyItem(at: segmentURL, to: stagedURL)
            let waveform = try await WaveformGenerator.generate(fromAudioAt: stagedURL)
            try EntryCreator.writeRecordingStub(
                entryURL: newEntryURL, created: .now, duration: duration
            )
            try FileManager.default.moveItem(
                at: stagedURL, to: newEntryURL.appending(path: audioName)
            )
            try waveform.write(to: WaveformData.url(inEntry: newEntryURL))
        } catch {
            try? FileManager.default.removeItem(at: newEntryURL)
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
        let trashItems = try trash.items()
        guard let staged = trashItems.first(where: {
            $0.kind == .preExtensionAudio
                && $0.originalPath == recovery.entryRelativePath
        }) else {
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
        try EntryMetadata.setDuration(duration, inEntry: entryURL)
        RecordingExtensionRecovery.removeArtifacts(in: entryURL)
        synchronizeSearchIndex(relativePaths: [recovery.entryRelativePath])
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

    func readTranscriptContent(atEntryPath relPath: RelativePath) -> EntryTranscriptContent {
        let entryURL = rootURL.appendingRelativePath(relPath)
        let edited: FrontmatterDocument?
        if let url = TranscriptFile.url(inEntry: entryURL),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            edited = FrontmatterDocument.parse(text)
        } else {
            edited = nil
        }
        return EntryTranscriptContent(
            edited: edited,
            original: TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL)),
            extensionState: ExtensionTranscriptState.load(from: entryURL)
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
        // An existing cache is rebuilt on every open so missed events from a
        // prior process can never leave stale search results.
        if existed { try index.rebuild() }
        searchIndex = index
    }

    func search(_ query: String, fuzzy: Bool, limit: Int = 150) throws -> [SearchHit] {
        guard let searchIndex else {
            throw SearchIndexError.sqlite("The vault is still being indexed")
        }
        do {
            return try searchIndex.search(query, fuzzy: fuzzy, limit: limit)
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

    func synchronizeSearchEntry(at relativePath: RelativePath) {
        synchronizeSearchIndex(relativePaths: [relativePath])
    }

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
        let entryURL = rootURL.appendingRelativePath(relPath)
        let transcriptURL = TranscriptFile.url(inEntry: entryURL)
            ?? entryURL.appending(path: TranscriptFile.defaultName)
        var doc: FrontmatterDocument
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            doc = FrontmatterDocument.parse(text)
        } else {
            doc = FrontmatterDocument(fields: [], body: "")
            doc.created = EntryFolderName(parsing: relPath.lastComponent)?.date
        }
        doc.favorite = favorite
        try AtomicFile.write(doc.serialized(), to: transcriptURL)
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

    func restore(_ item: TrashItem) throws -> RelativePath {
        let path = try trash.restore(item)
        synchronizeSearchIndex(relativePaths: [path])
        return path
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
