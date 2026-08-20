import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case folder(RelativePath)
    case favorites
    case recentlyDeleted
}

enum SearchIndexState: Equatable {
    case unavailable
    case indexing
    case ready
    case failed(String)
}

struct TranscriptNavigationRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var hit: SearchHit
}

/// Main-actor view model for the whole app. All file I/O is delegated to the
/// background `VaultService` actor; this type only holds published state.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case needsVault
        case ready
    }

    /// UserDefaults keys shared between services and @AppStorage in the UI.
    enum PreferenceKey {
        static let recordingQuality = "recordingQuality"
        static let preferredMicUID = "preferredMicUID"
        static let fuzzyVaultSearch = "fuzzyVaultSearch"
        static let entrySortOrder = "entrySortOrder"
        static let entrySortDirection = "entrySortDirection"
    }

    private(set) var phase: Phase = .launching
    private(set) var vaultURL: URL?
    private(set) var recentVaults = VaultBookmark.resolveRecents()
    private(set) var snapshot: VaultSnapshot?
    private(set) var trashItems: [TrashItem] = []
    /// Recently Deleted retention (SET-2), loaded from the vault's settings
    /// file on open; user-visible copy quotes this, not the built-in default.
    private(set) var trashRetentionDays = VaultSettingsStore.defaultTrashRetentionDays
    /// Last storage measurement (AUD-6). Kept so reopening the Storage pane
    /// shows numbers instantly while a fresh walk revalidates in background.
    private(set) var storageSummary: VaultStorageSummary?
    private(set) var storageSummaryIsLoading = false

    let recorder = RecorderService()
    let player = PlayerService()
    let inputDevices = AudioInputDevices()
    let modelManager = ModelManager()
    let liveTranscriber = LiveTranscriber()
    let globalShortcutService = GlobalShortcutService()

    private(set) var globalShortcutPreferences = GlobalShortcutPreferencesStore.load()
    /// App-local remappable shortcuts (Settings → Keybinds → App Shortcuts).
    private(set) var appShortcutPreferences = AppShortcutPreferencesStore.load()
    /// True while a Settings shortcut-capture control owns keyboard input;
    /// normal command dispatch is suppressed so captured chords never fire.
    var isShortcutCaptureActive = false

    // Quick Move (Move Note…): view-presented picker state.
    var isQuickMovePresented = false {
        didSet {
            if !isQuickMovePresented {
                quickMoveEntryPath = nil
                quickMoveErrorMessage = nil
            }
        }
    }
    private(set) var quickMoveEntryPath: RelativePath?
    var quickMoveErrorMessage: String?
    private(set) var globalRecordingTransientState: GlobalRecordingPresentationState?
    private var lastFinalizedRecordingDuration: Double?
    private(set) var isGlobalIndicatorRetentionActive = false
    private var recordingCommandGate = RecordingCommandGate()
    /// Continuations parked in `stopRecordingForTermination` until the gate
    /// releases. Main-actor only.
    private var recordingCommandWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcriptSaveRefreshTask: Task<Void, Never>?
    static let transcriptSaveRefreshDelay: Double = 1.2
    /// Extension and replacement starts cross permission/filesystem awaits and
    /// are therefore actor-reentrant. Keep exactly one such workflow in flight
    /// so a losing task cannot alter the winner's shared edit session.
    private var recordingWorkflowStartGate = RecordingWorkflowStartGate()
    private var activeRecordingStartToken: UUID?
    private(set) var isRecordingStartInFlight = false
    private var globalRecordingStateTask: Task<Void, Never>?
    private var globalIndicatorRetentionTask: Task<Void, Never>?
    private var lastCompletedRecordingAt: Date?

    private(set) var transcriptionQueue: TranscriptionQueue?
    /// Bumped whenever a transcription lands so the detail view re-reads
    /// `transcript.md` (the FSEvents watcher ignores our own writes).
    private(set) var transcriptRevision = 0
    /// Bumped only for filesystem-watcher events. List refreshes caused by an
    /// in-app autosave must not reload the active editor, because an earlier
    /// debounced save may finish while newer keystrokes are still unsaved.
    private(set) var externalVaultRevision = 0
    /// Bumped when an entry's audio file is replaced in place (trim, restore):
    /// the playback shelf must reload the player and waveform even though the
    /// entry path and audio file name are unchanged.
    private(set) var audioRevision = 0

    var isVaultSearchPresented = false {
        didSet {
            // Filters reset when the overlay closes: a stale hidden filter on
            // the next search would silently explain away missing results.
            if !isVaultSearchPresented, vaultSearchFilters != VaultSearchFilters() {
                vaultSearchFilters = VaultSearchFilters()
            }
        }
    }
    var vaultSearchQuery = ""
    /// SRCH-5 filters; changes re-run the visible search immediately.
    var vaultSearchFilters = VaultSearchFilters() {
        didSet {
            guard vaultSearchFilters != oldValue else { return }
            scheduleVaultSearch(immediate: true)
        }
    }
    var fuzzyVaultSearch = UserDefaults.standard.bool(forKey: PreferenceKey.fuzzyVaultSearch) {
        didSet {
            UserDefaults.standard.set(fuzzyVaultSearch, forKey: PreferenceKey.fuzzyVaultSearch)
            scheduleVaultSearch()
        }
    }
    private(set) var searchIndexState: SearchIndexState = .unavailable
    private(set) var vaultSearchResults: [SearchHit] = []
    private(set) var vaultSearchIsRunning = false
    private(set) var vaultSearchError: String?
    private(set) var transcriptNavigationRequest: TranscriptNavigationRequest?
    private(set) var inNoteFindRequestRevision = 0

    // MARK: - Menu-bar command routing
    //
    // Menu items must invoke the same flows as the in-view buttons, but the
    // sheets and prompts those buttons drive live in view-local @State. The
    // menu therefore publishes a request (enum + bumped revision, the same
    // pattern as in-note find) and the owning view fulfills it.

    enum EntryActionRequest {
        case extendRecording, retranscribe, trim, compress, restoreOriginalAudio, exportMarkdown, deleteAudio, showInfo
    }

    enum WorkbenchActionRequest {
        case editOrSave, copyAsMarkdown, toggleLayer, renameSpeakers
        /// Flush pending autosaves and leave edit mode, then report whether
        /// the note is safely saved (true when it was not being edited).
        /// Used by Move Note… so a move never races an unsaved edit.
        case finishEditing(@MainActor (Bool) -> Void)
    }

    /// What the note workbench can do right now, mirrored up so menu items
    /// enable/disable and retitle truthfully (the state itself is view-local).
    struct WorkbenchUIState: Equatable {
        var hasContent = false
        var canEditNote = false
        var isEditing = false
        var isForked = false
        var hasSpeakers = false
        var viewedLayerIsOriginal = true
    }

    private(set) var entryActionRequest: EntryActionRequest?
    private(set) var entryActionRevision = 0
    private(set) var workbenchActionRequest: WorkbenchActionRequest?
    private(set) var workbenchActionRevision = 0
    private(set) var newFolderRequestRevision = 0
    private(set) var renameEntryRequestRevision = 0
    private(set) var queuePopoverRequestRevision = 0
    private(set) var cancelTrimRequestRevision = 0
    private(set) var trimModeActive = false
    var workbenchUIState = WorkbenchUIState() {
        didSet {
            // Leaving the editor flushes the coalesced post-save rescan, so
            // the list row never sits on a stale preview afterwards.
            if oldValue.isEditing, !workbenchUIState.isEditing {
                Task { [weak self] in await self?.flushTranscriptSaveRefresh() }
            }
        }
    }

    func requestEntryAction(_ request: EntryActionRequest) {
        guard selectedEntry != nil else { return }
        entryActionRequest = request
        entryActionRevision &+= 1
    }

    func requestWorkbenchAction(_ request: WorkbenchActionRequest) {
        guard selectedEntry != nil else { return }
        workbenchActionRequest = request
        workbenchActionRevision &+= 1
    }

    func requestNewFolder() {
        guard phase == .ready else { return }
        newFolderRequestRevision &+= 1
    }

    func requestRenameEntry() {
        guard selectedEntry != nil else { return }
        renameEntryRequestRevision &+= 1
    }

    func requestQueuePopover() {
        guard phase == .ready else { return }
        queuePopoverRequestRevision &+= 1
    }

    func setTrimModeActive(_ active: Bool) {
        trimModeActive = active
    }

    /// Shared trim eligibility for the transport control, menu request, and
    /// app-wide T shortcut. Keeping this in the model prevents a shortcut from
    /// entering a mode that the visible control would reject.
    func trimBlockedReason(for entry: Entry, duration: Double? = nil) -> String? {
        guard entry.hasAudio else {
            return entry.audioUnavailableExplanation ?? "No audio is available to trim."
        }
        if liveRecordingBlocks(entry.relativePath) {
            return "Stop the recording before trimming."
        }
        if replacementModeActive {
            return "Finish or cancel replacing audio before trimming."
        }
        if compressingEntryPaths.contains(entry.relativePath) {
            return "Wait for audio compression to finish."
        }
        if clipMutationEntryPaths.contains(entry.relativePath) {
            return "Wait for the current audio operation to finish."
        }
        if transcriptionBusyEntryPaths.contains(entry.relativePath) {
            return "Wait for the transcription to finish before trimming."
        }
        if let duration, duration <= TrimSelection.minimumKeptSeconds {
            return "This audio is too short to trim."
        }
        return nil
    }

    /// T mirrors the scissors control: enter trim when available, or leave an
    /// active trim without changing the source audio.
    private func toggleTrimFromShortcut() {
        if trimModeActive {
            cancelTrimRequestRevision &+= 1
            return
        }
        guard let entry = selectedEntry else {
            errorMessage = "Select an audio clip before trimming."
            return
        }
        if let reason = trimBlockedReason(for: entry, duration: entry.duration) {
            errorMessage = reason
            return
        }
        requestEntryAction(.trim)
    }

    /// Workflow-level Escape fallback. Native menus, popovers, sheets, alerts,
    /// and auxiliary windows get the responder-chain command first; this runs
    /// only after no foreground transient surface consumes it.
    @discardableResult
    func handleExitCommand() -> Bool {
        if isCancelRecordingConfirmationPresented { return false }
        if recorder.state == .recording || recorder.state == .paused {
            isCancelRecordingConfirmationPresented = true
            return true
        }
        if let replacementEntryPath {
            Task { await cancelReplacement(expectedEntryPath: replacementEntryPath) }
            return true
        }
        if trimModeActive {
            cancelTrimRequestRevision &+= 1
            return true
        }
        if recorder.isZenMode, recorder.state == .idle {
            recorder.isZenMode = false
            return true
        }
        return false
    }

    var sidebarSelection: SidebarSelection? = .folder("") {
        didSet {
            guard sidebarSelection != oldValue else { return }
            if let selectedEntryID {
                let selectionStillVisible = displayedEntries.contains { $0.id == selectedEntryID }
                if !selectionStillVisible {
                    self.selectedEntryID = nil
                }
            }
            if sidebarSelection != .recentlyDeleted, selectedTrashItemID != nil {
                selectedTrashItemID = nil
            }
        }
    }
    /// Entry-list sort (LIB-4), persisted across launches.
    var entrySortOrder = EntrySortOrder(
        rawValue: UserDefaults.standard.string(forKey: PreferenceKey.entrySortOrder) ?? ""
    ) ?? .dateNewest {
        didSet {
            UserDefaults.standard.set(entrySortOrder.rawValue, forKey: PreferenceKey.entrySortOrder)
        }
    }
    var entrySortDirection = EntrySortDirection(
        rawValue: UserDefaults.standard.string(forKey: PreferenceKey.entrySortDirection) ?? ""
    ) ?? (EntrySortOrder(
        rawValue: UserDefaults.standard.string(forKey: PreferenceKey.entrySortOrder) ?? ""
    ) ?? .dateNewest).defaultDirection {
        didSet {
            UserDefaults.standard.set(entrySortDirection.rawValue, forKey: PreferenceKey.entrySortDirection)
        }
    }

    func selectEntrySortOrder(_ order: EntrySortOrder) {
        entrySortOrder = order
        entrySortDirection = order.defaultDirection
    }

    func toggleEntrySortDirection() {
        entrySortDirection = entrySortDirection.toggled
    }
    var selectedEntryID: String? {
        didSet {
            // PLY: switching entries stops playback; returning doesn't resume.
            guard selectedEntryID != oldValue else { return }
            player.unload()
            // Replace is a focused, entry-local transaction. Navigating away
            // is an exit from that transaction; retaining its global lock
            // strands unrelated entry actions until relaunch.
            if let replacementEntryPath, selectedEntryID != replacementEntryPath {
                Task { await cancelReplacement(expectedEntryPath: replacementEntryPath) }
            }
        }
    }
    var selectedTrashItemID: String? {
        didSet {
            // A preview may be playing directly from `.trash`; every selection
            // change must release that file before restore or deletion.
            if selectedTrashItemID != oldValue { player.unload() }
        }
    }
    private(set) var middleColumnIsCollapsed = false

    func setMiddleColumnCollapsed(_ collapsed: Bool) {
        middleColumnIsCollapsed = collapsed
    }
    var errorMessage: String?
    var isCancelRecordingConfirmationPresented = false
    /// Informational notice kept separate from errors so a protected edited
    /// layer does not look like a failed retranscription.
    var transcriptNoticeMessage: String?
    var recordingRecoveryNoticeMessage: String?
    private(set) var extensionRecoveries: [RecoverableRecordingExtension] = []
    /// Includes both actionable and malformed extension recovery artifacts.
    /// A new extension must never overwrite either kind's manifest/journal.
    private(set) var unresolvedExtensionRecoveryEntryPaths: Set<RelativePath> = []
    private(set) var extensionRecoveryProcessingIDs: Set<String> = []
    private(set) var compressingEntryPaths: Set<RelativePath> = []
    private(set) var clipMutationEntryPaths: Set<RelativePath> = []
    private(set) var replacementSession: ReplacementTakeSession?
    private(set) var replacementEntryPath: RelativePath?
    private(set) var replacementPreviewLabel: String?
    private(set) var replacementTakeWaveform: WaveformData?
    private(set) var replacementTakeWaveformID: UUID?
    private var replacementPreviewURL: URL?
    private var replacementPreviewTakeID: UUID?
    private var replacementPreviewGeneration: UUID?
    private var nextReplacementFailurePoint: AudioReplacementFailurePoint?

    var replacementModeActive: Bool { replacementEntryPath != nil }
    private(set) var unsupportedExtensionEntryPaths: Set<RelativePath> = []
    var isExtensionRecoveryPresented = false

    private var service: VaultService?
    private var watcher: FSEventsWatcher?
    private var searchIndexTask: Task<Void, Never>?
    private var vaultSearchTask: Task<Void, Never>?
    /// URL currently holding security-scoped access (stopAccessing on switch).
    private var scopedURL: URL?

    var selectedEntry: Entry? {
        guard let selectedEntryID else { return nil }
        return snapshot?.entry(withID: selectedEntryID)
    }

    var selectedTrashItem: TrashItem? {
        guard let selectedTrashItemID else { return nil }
        return trashItems.first { $0.id == selectedTrashItemID }
    }

    /// The oldest retained pre-trim version is the entry's full original
    /// clip. Newer items may represent intermediate trims.
    func originalAudioTrashItem(for entry: Entry) -> TrashItem? {
        trashItems
            .filter { $0.kind == .preTrimAudio && $0.originalPath == entry.relativePath }
            .min { $0.deletedAt < $1.deletedAt }
    }

    var selectedFolder: FolderNode? {
        guard case .folder(let relPath)? = sidebarSelection else { return nil }
        return snapshot?.folder(at: relPath)
    }

    /// Every favorited entry in the vault (the Favorites smart filter, LIB-3).
    var favoriteEntries: [Entry] {
        snapshot?.allEntries.filter(\.favorite) ?? []
    }

    /// The entries the list column shows for the current sidebar selection,
    /// in the user's sort order. Selection successors (delete) must be
    /// computed from this same order.
    var displayedEntries: [Entry] {
        switch sidebarSelection {
        case .folder:
            return entrySortOrder.sorted(
                selectedFolder?.entries ?? [],
                direction: entrySortDirection
            )
        case .favorites:
            return entrySortOrder.sorted(favoriteEntries, direction: entrySortDirection)
        case .recentlyDeleted, .none:
            return []
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .launching else { return }
        RecordingSourcePreferenceMigration.removeLegacyPreference()
        installKeyMonitor()
        configureGlobalRecordingControls()
        Task { await modelManager.refresh() }
        if let url = VaultBookmark.resolve() {
            await openVault(at: url, isSecurityScoped: true, saveBookmark: false)
        } else {
            phase = .needsVault
        }
    }

    private func configureGlobalRecordingControls() {
        globalShortcutService.onAction = { [weak self] action in
            guard let self else { return }
            Task {
                switch action {
                case .toggleRecording:
                    await self.performRecordingCommand(
                        self.recorder.state == .idle ? .startNew : .stopAndSave
                    )
                case .pauseResumeRecording:
                    await self.performRecordingCommand(.pauseResume)
                }
            }
        }
        globalShortcutService.apply(globalShortcutPreferences)
    }

    func updateGlobalShortcutPreferences(_ preferences: GlobalShortcutPreferences) {
        let retentionChanged = preferences.backgroundIndicatorRetention !=
            globalShortcutPreferences.backgroundIndicatorRetention
        globalShortcutPreferences = preferences
        GlobalShortcutPreferencesStore.save(preferences)
        globalShortcutService.apply(preferences)
        if retentionChanged, recorder.state == .idle, let lastCompletedRecordingAt {
            beginGlobalIndicatorRetention(after: lastCompletedRecordingAt)
        }
    }

    func resetGlobalShortcutPreferences() {
        updateGlobalShortcutPreferences(.defaults)
    }

    func shutdownGlobalRecordingControls() {
        globalRecordingStateTask?.cancel()
        globalIndicatorRetentionTask?.cancel()
        globalShortcutService.shutdown()
    }

    private func logRecoveredMicrophoneFailure(
        _ observation: RecoveredMicrophoneCaptureObservation,
        target: MicrophoneFailureEvent.Target,
        elapsedSeconds: TimeInterval = 0
    ) {
        let classification: (
            MicrophoneFailureEvent.Kind,
            MicrophoneFailureEvent.Reason
        )? = switch observation.inspection.terminalState {
        case .noFrames:
            (.noAudioAfterStart, .noFrames)
        case .perfectlySilent:
            (.perfectlySilentClip, .perfectlySilent)
        case .signal:
            nil
        }
        guard let classification else { return }
        MicrophoneFailureLogger.shared.log(MicrophoneFailureEvent(
            sessionID: observation.sessionID ?? UUID(),
            kind: classification.0,
            target: target,
            stage: .crashRecovery,
            reason: classification.1,
            preferredRoute: .unknown,
            resolvedDeviceFormat: nil,
            engineState: .init(
                phase: .stopped,
                isRunning: false,
                tapInstalled: false
            ),
            frames: observation.inspection.frames,
            elapsedSeconds: elapsedSeconds
        ))
    }

    /// Opens `url` as the vault, replacing any current vault.
    func openVault(at url: URL, isSecurityScoped: Bool, saveBookmark: Bool) async {
        guard !isRecordingStartInFlight else {
            errorMessage = "Wait for the microphone to finish starting before switching vaults."
            return
        }
        // Recording finalization suspends while optional Mac audio is torn down
        // and the canonical file is installed. Keep the current vault until
        // that serialized transition completes.
        guard recorder.state != .finalizing else {
            errorMessage = "Wait for the current recording operation to finish before switching vaults."
            return
        }
        if replacementModeActive {
            // Finish the old vault's temporary transaction against the old
            // VaultService before replacing it below.
            await cancelReplacement()
        } else if recorder.isActive {
            // Route every non-replacement stop through the same canonical
            // install and post-stop handoff before replacing the old service.
            _ = await stopRecordingImpl()
            guard recorder.state == .idle else {
                errorMessage = "Wait for the current recording operation to finish before switching vaults."
                return
            }
        }
        player.unload()
        searchIndexTask?.cancel()
        vaultSearchTask?.cancel()
        watcher?.stop()
        watcher = nil
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }

        if isSecurityScoped, url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        DebugLog.append("openVault path=\(url.path) scoped=\(scopedURL != nil)")
        // Only an explicit open/create/switch updates the MRU. A launch-time
        // restore must not re-add a current vault the user deliberately
        // removed from the recent list with its x button.
        if saveBookmark {
            do {
                try VaultBookmark.save(url)
            } catch {
                errorMessage = "Could not save vault access: \(error.localizedDescription)"
            }
            do {
                try VaultBookmark.recordRecent(url)
                recentVaults = VaultBookmark.resolveRecents()
            } catch {
                errorMessage = "Could not remember recent vault: \(error.localizedDescription)"
            }
        }

        vaultURL = url
        let service = VaultService(rootURL: url)
        self.service = service
        snapshot = nil
        extensionRecoveries = []
        unresolvedExtensionRecoveryEntryPaths = []
        trashItems = []
        sidebarSelection = .folder("")
        selectedEntryID = nil
        selectedTrashItemID = nil
        searchIndexState = .indexing
        vaultSearchResults = []
        vaultSearchError = nil
        transcriptNavigationRequest = nil
        phase = .ready

        transcriptionQueue?.shutdown()
        let queue = TranscriptionQueue(vaultRoot: url, service: service)
        queue.onEntryTranscribed = { [weak self] originalPath, outcome in
            self?.entryTranscribed(originalPath: originalPath, outcome: outcome)
        }
        transcriptionQueue = queue
        TranscriptionSeam.queue = queue

        let recordingRecovery = await service.recoverInterruptedRecordings()
        for outcome in recordingRecovery.recovered {
            logRecoveredMicrophoneFailure(
                .init(
                    sessionID: nil,
                    inspection: .init(
                        frames: outcome.microphoneFrames,
                        hasSignal: outcome.microphoneHasSignal
                    )
                ),
                target: .newEntry,
                elapsedSeconds: outcome.duration
            )
            if outcome.shouldQueueTranscription {
                queue.enqueue(
                    entryRelativePath: outcome.entryRelativePath,
                    source: "recording-recovery"
                )
            }
        }
        for failure in recordingRecovery.failures {
            guard let state = failure.microphoneTerminalState else { continue }
            logRecoveredMicrophoneFailure(
                .init(
                    sessionID: nil,
                    inspection: .init(
                        frames: failure.microphoneFrames,
                        hasSignal: state == .signal
                    )
                ),
                target: .newEntry
            )
        }
        if !recordingRecovery.recovered.isEmpty {
            let count = recordingRecovery.recovered.count
            var message = count == 1
                ? "An interrupted recording was recovered through the last audio written to disk."
                : "\(count) interrupted recordings were recovered through the last audio written to disk."
            if !recordingRecovery.acknowledgedLegacyPaths.isEmpty {
                message += " A separate partial from a pre-fix build could not be decoded; its bytes remain preserved and it will not trigger this notice again."
            }
            let failedMicrophoneCount = recordingRecovery.recovered.filter {
                MicrophoneTerminalCaptureState.classify(
                    frames: $0.microphoneFrames,
                    hasSignal: $0.microphoneHasSignal
                ) != .signal
            }.count
            if failedMicrophoneCount > 0 {
                message += failedMicrophoneCount == 1
                    ? " Its microphone track was empty or perfectly silent; that failure was logged, and the clip was retained for inspection."
                    : " \(failedMicrophoneCount) microphone tracks were empty or perfectly silent; those failures were logged, and the clips were retained for inspection."
            }
            recordingRecoveryNoticeMessage = message
        } else if !recordingRecovery.acknowledgedLegacyPaths.isEmpty {
            recordingRecoveryNoticeMessage = "A partial recording from a pre-fix build is missing its audio packet table. Its bytes remain preserved, and it will not trigger this notice again."
        }
        if !recordingRecovery.failures.isEmpty {
            let details = recordingRecovery.failures.map {
                "\($0.entryRelativePath): \($0.message)"
            }.joined(separator: "\n")
            errorMessage = "Some interrupted recordings still need recovery. Their partial audio was kept unchanged:\n\(details)"
        }
        if !recordingRecovery.recoveredInTrash.isEmpty {
            // Deliberately notice-only: these entries live in `.trash`, so they
            // must not be enqueued for transcription or added to the search
            // index. Restoring one turns it into an ordinary entry, and the
            // next launch's scan picks it up from there.
            let count = recordingRecovery.recoveredInTrash.count
            recordingRecoveryNoticeMessage = count == 1
                ? "A recording that was interrupted while its note sat in Recently Deleted was rebuilt. Restore that note to keep the audio."
                : "\(count) recordings that were interrupted while their notes sat in Recently Deleted were rebuilt. Restore those notes to keep the audio."
        }

        let extensionDiscovery = await service.recordingExtensionRecoveries()
        extensionRecoveries = []
        unresolvedExtensionRecoveryEntryPaths = Set(
            extensionDiscovery.recoverable.map(\.entryRelativePath)
                + extensionDiscovery.malformedEntryPaths
        )
        for recovery in extensionDiscovery.recoverable {
            if let observation = recovery.microphoneObservation {
                logRecoveredMicrophoneFailure(
                    observation,
                    target: .extensionRecording
                )
            }
            if recovery.phase == .swapNeedsCleanup {
                do {
                    _ = try await service.finishRecoveredExtension(recovery)
                    queueExtensionRetranscription(
                        entryRelativePath: recovery.entryRelativePath,
                        source: "extension-recovery"
                    )
                    audioRevision &+= 1
                    unresolvedExtensionRecoveryEntryPaths.remove(
                        recovery.entryRelativePath
                    )
                } catch {
                    extensionRecoveries.append(recovery)
                }
            } else {
                extensionRecoveries.append(recovery)
            }
        }
        if !extensionDiscovery.malformedEntryPaths.isEmpty {
            let paths = extensionDiscovery.malformedEntryPaths.joined(separator: "\n")
            errorMessage = "Some extension recovery metadata could not be read. The audio artifacts remain unchanged:\n\(paths)"
        }
        isExtensionRecoveryPresented = !extensionRecoveries.isEmpty

        let replacementDiscovery = await service.replacementTakeSessions()
        for observation in replacementDiscovery.microphoneObservations {
            logRecoveredMicrophoneFailure(
                observation,
                target: .replacementTake
            )
        }
        for path in replacementDiscovery.committedEntryPaths {
            queueExtensionRetranscription(
                entryRelativePath: path,
                source: TranscriptionSeam.Source.replaced.rawValue
            )
            audioRevision &+= 1
        }

        watcher = FSEventsWatcher(url: url) { [weak self] paths in
            Task {
                await service.synchronizeSearchIndex(changedAbsolutePaths: paths)
                await self?.handleExternalVaultChange(
                    for: service, changedAbsolutePaths: paths
                )
            }
        }
        // Retention purge on launch/open (window configurable per vault,
        // SET-2), then first scan.
        storageSummary = nil
        trashRetentionDays = await service.trashRetentionDays()
        _ = try? await service.purgeTrash()
        await refresh()
        if let recovered = replacementDiscovery.recoverable.first {
            replacementSession = recovered
            replacementEntryPath = recovered.entryRelativePath
            selectedEntryID = recovered.entryRelativePath
            replacementPreviewLabel = recovered.takes.isEmpty
                ? "Recovered replacement session"
                : "Recovered Take \(recovered.takes.last?.number ?? 1)"
            if replacementDiscovery.recoverable.count > 1 {
                recordingRecoveryNoticeMessage = "Recovered \(replacementDiscovery.recoverable.count) replacement sessions. The first is open; no take was baked automatically."
            } else {
                recordingRecoveryNoticeMessage = "Recovered a replacement session. Its captured take is available for review and was not baked automatically."
            }
            if let selectedTake = recovered.selectedTake {
                await prepareReplacementPreview(
                    for: selectedTake, scope: .region, autoplay: false
                )
            }
        }

        // The vault is already usable. Index construction starts only after
        // the opening scan and runs on the VaultService actor, so it cannot
        // hold up initial navigation on the main actor.
        searchIndexTask = Task { [weak self] in
            do {
                try await service.initializeSearchIndex()
                guard !Task.isCancelled else { return }
                self?.searchIndexDidFinish(for: service, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchIndexDidFinish(for: service, error: error)
            }
        }
    }

    private func handleExternalVaultChange(
        for changedService: VaultService, changedAbsolutePaths: [String]
    ) async {
        guard service === changedService else { return }
        // Bumping the revision reloads the open entry's whole transcript — a
        // full JSON decode, timing repair and word-map rebuild. Any write
        // anywhere in the vault used to pay that cost, so only do it when the
        // event actually touched the entry on screen.
        if let vaultURL, let openEntry = selectedEntryID,
           Self.externalChange(
               changedAbsolutePaths, touchesEntryAt: openEntry, inVault: vaultURL
           ) {
            externalVaultRevision &+= 1
        }
        await refresh()
        refreshVaultSearchIfVisible()
    }

    /// Whether a coalesced filesystem event touched the open entry — the entry
    /// folder itself, anything inside it, or an ancestor of it (a folder
    /// rename arrives as an event on the folder).
    ///
    /// An empty path list means "unknown extent", which `VaultSearchIndex`
    /// also treats as everything; reloading unnecessarily is the safe side.
    static func externalChange(
        _ changedAbsolutePaths: [String],
        touchesEntryAt entryPath: RelativePath,
        inVault vaultURL: URL
    ) -> Bool {
        guard !changedAbsolutePaths.isEmpty else { return true }
        let entry = vaultURL.appendingRelativePath(entryPath).standardizedFileURL.path
        return changedAbsolutePaths.contains { raw in
            let changed = URL(fileURLWithPath: raw).standardizedFileURL.path
            return changed == entry
                || changed.hasPrefix(entry + "/")
                || entry.hasPrefix(changed + "/")
        }
    }

    private func searchIndexDidFinish(for indexedService: VaultService, error: Error?) {
        guard service === indexedService else { return }
        if let error {
            searchIndexState = .failed(error.localizedDescription)
            vaultSearchError = error.localizedDescription
        } else {
            searchIndexState = .ready
            scheduleVaultSearch(immediate: true)
        }
    }

    func refresh() async {
        await refresh(apply: nil)
    }

    /// `apply` runs in the same main-actor turn that publishes the new
    /// snapshot. Selection changes that depend on the rescan (a just-stopped
    /// recording, an auto-title rename) must land with it — resuming after
    /// `await refresh()` is a separate job, and SwiftUI can render a frame in
    /// between where the new row exists but nothing is selected.
    private func refresh(apply: (@MainActor () -> Void)?) async {
        guard let service else { return }
        let snap = await service.snapshot()
        let trash = (try? await service.trashItems()) ?? []
        snapshot = snap
        trashItems = trash
        apply?()
        // Drop selections that no longer exist on disk.
        if case .folder(let relPath)? = sidebarSelection, snap.folder(at: relPath) == nil {
            sidebarSelection = .folder("")
        }
        if let selectedEntryID, snap.entry(withID: selectedEntryID) == nil {
            self.selectedEntryID = nil
        }
        if let selectedTrashItemID,
           !trash.contains(where: { $0.id == selectedTrashItemID }) {
            self.selectedTrashItemID = nil
        }
    }

    // MARK: - Vault selection panels

    func chooseExistingVault() {
        let panel = NSOpenPanel()
        panel.title = "Open Vault"
        panel.message = "Choose the folder that is (or will become) your transcride vault."
        panel.prompt = "Open Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openVault(at: url, isSecurityScoped: true, saveBookmark: true) }
    }

    func createNewVault() {
        let panel = NSSavePanel()
        panel.title = "Create New Vault"
        panel.message = "Choose a name and location for your new transcride vault."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Transcride Vault"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create vault: \(error.localizedDescription)"
            return
        }
        Task { await openVault(at: url, isSecurityScoped: true, saveBookmark: true) }
    }

    func openRecentVault(_ recent: VaultBookmark.RecentVault) {
        Task { await openVault(at: recent.url, isSecurityScoped: true, saveBookmark: true) }
    }

    func forgetRecentVault(_ recent: VaultBookmark.RecentVault) {
        VaultBookmark.forgetRecent(recent)
        recentVaults = VaultBookmark.resolveRecents()
    }

    // MARK: - Live-recording guards

    /// True when a vault operation on `target` would carry the live recording's
    /// entry folder with it: the folder itself, or any ancestor of it.
    ///
    /// Exact equality is not enough. Deleting, moving or renaming an *ancestor*
    /// folder takes the live `.recording.caf` journal along — into `.trash` for
    /// a delete, where the launch recovery scan never looks — and Empty Trash
    /// then destroys the only copy of the audio.
    static func operationCapturesLiveRecording(
        target: RelativePath, liveEntryPath: RelativePath?
    ) -> Bool {
        guard let live = liveEntryPath else { return false }
        // The separator matters in both directions: "Journal" must not capture
        // a recording inside the sibling folder "Journal2".
        return target.isEmpty || target == live || live.hasPrefix(target + "/")
    }

    /// Whether the live recording blocks a mutation of `relPath`.
    func liveRecordingBlocks(_ relPath: RelativePath) -> Bool {
        Self.operationCapturesLiveRecording(
            target: relPath, liveEntryPath: recorder.currentEntryPath
        )
    }

    /// Follows a rename or move in the recovery bookkeeping that was captured
    /// at launch. `VaultService` re-anchors recovery records to the folder it
    /// finds them in, but only at *discovery* time: a rename between the
    /// launch scan and the user resolving the sheet would otherwise dead-end
    /// `finishRecoveredExtension`, `saveRecoveredExtensionAsNewEntry` and
    /// `discardRecoveredExtension` on a path that no longer exists.
    private func repointRecoveryArtifacts(from oldPath: RelativePath, to newPath: RelativePath) {
        guard oldPath != newPath else { return }
        func repointed(_ path: RelativePath) -> RelativePath? {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + path.dropFirst(oldPath.count)
            }
            return nil
        }
        for index in extensionRecoveries.indices {
            if let moved = repointed(extensionRecoveries[index].entryRelativePath) {
                extensionRecoveries[index].entryRelativePath = moved
            }
        }
        unresolvedExtensionRecoveryEntryPaths = Set(
            unresolvedExtensionRecoveryEntryPaths.map { repointed($0) ?? $0 }
        )
        if let replacementEntryPath, let moved = repointed(replacementEntryPath) {
            self.replacementEntryPath = moved
        }
        if let path = replacementSession?.entryRelativePath, let moved = repointed(path) {
            replacementSession?.entryRelativePath = moved
        }
    }

    // MARK: - Intents (folders)

    func createFolder(named name: String, inFolder parent: RelativePath) async {
        await perform("createFolder \(name) in [\(parent)]") { service in
            _ = try await service.createFolder(named: name, inFolder: parent)
        }
    }

    func renameFolder(at relPath: RelativePath, to newName: String) async {
        guard !liveRecordingBlocks(relPath) else {
            errorMessage = "Stop the recording before renaming this folder — the recording in progress is inside it."
            return
        }
        await perform("renameFolder [\(relPath)] -> \(newName)") { service in
            let newPath = try await service.renameFolder(at: relPath, to: newName)
            await MainActor.run {
                // Every entry beneath the folder just changed path: the queue
                // and any launch-captured recovery record must follow, or a
                // running transcription lands on a path that no longer exists.
                self.transcriptionQueue?.repointItems(from: relPath, to: newPath)
                self.repointRecoveryArtifacts(from: relPath, to: newPath)
                if let selected = self.selectedEntryID,
                   selected.hasPrefix(relPath + "/") {
                    self.selectedEntryID = newPath + selected.dropFirst(relPath.count)
                }
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(newPath)
                }
            }
        }
    }

    // MARK: - Intents (entries)

    func renameEntry(_ entry: Entry, toTitle title: String) async {
        guard !liveRecordingBlocks(entry.relativePath) else {
            errorMessage = "Stop the recording before renaming this note."
            return
        }
        await perform("renameEntry [\(entry.relativePath)] -> \(title)") { service in
            let newPath = try await service.renameEntry(at: entry.relativePath, toTitle: title)
            await MainActor.run {
                self.transcriptionQueue?.repointItems(from: entry.relativePath, to: newPath)
                self.repointRecoveryArtifacts(from: entry.relativePath, to: newPath)
                if self.selectedEntryID == entry.relativePath {
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func moveItem(atRelativePath relPath: RelativePath, toFolder destFolder: RelativePath) async {
        guard !liveRecordingBlocks(relPath) else {
            errorMessage = "Stop the recording before moving this — the recording in progress is inside it."
            return
        }
        await perform("moveItem [\(relPath)] -> [\(destFolder)]") { service in
            let newPath = try await service.moveItem(at: relPath, toFolder: destFolder)
            await MainActor.run {
                self.transcriptionQueue?.repointItems(from: relPath, to: newPath)
                self.repointRecoveryArtifacts(from: relPath, to: newPath)
                if let selected = self.selectedEntryID,
                   selected == relPath || selected.hasPrefix(relPath + "/") {
                    self.selectedEntryID = newPath + selected.dropFirst(relPath.count)
                }
            }
        }
    }

    func deleteItem(atRelativePath relPath: RelativePath) async {
        guard !liveRecordingBlocks(relPath) else {
            errorMessage = "Stop the recording before deleting this — the recording in progress is inside it."
            return
        }
        // Standard list semantics: deleting the selected entry selects the
        // one that takes its place (the next below, else the new last).
        // Computed from the displayed order before the row disappears.
        var successorID: String?
        let entries = displayedEntries
        if selectedEntryID == relPath,
           let index = entries.firstIndex(where: { $0.id == relPath }) {
            successorID = index + 1 < entries.count
                ? entries[index + 1].id
                : (index > 0 ? entries[index - 1].id : nil)
        }
        await perform("deleteItem [\(relPath)]") { service in
            try await service.trashItem(atRelativePath: relPath)
            await MainActor.run {
                self.transcriptionQueue?.evictItems(underPath: relPath)
                if self.selectedEntryID == relPath { self.selectedEntryID = nil }
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(relPath.parentRelativePath)
                }
            }
        }
        // Only after the refresh confirmed the delete (entry gone, successor
        // still present) — a failed trash keeps the original selection.
        if let successorID, selectedEntryID == nil,
           snapshot?.entry(withID: relPath) == nil,
           snapshot?.entry(withID: successorID) != nil {
            selectedEntryID = successorID
        }
    }

    func toggleFavorite(for entry: Entry) async {
        guard !liveRecordingBlocks(entry.relativePath) else { return }
        let favorite = !entry.favorite
        await perform("setFavorite \(favorite) [\(entry.relativePath)]") { service in
            try await service.setFavorite(favorite, atEntryPath: entry.relativePath)
        }
    }

    func speechTranscriptAvailability(for entry: Entry) -> SpeechTranscriptAvailability {
        if transcriptionQueue?.items.contains(where: {
            $0.entryRelativePath == entry.relativePath
        }) == true {
            return .regenerating
        }
        return entry.speechTranscriptAvailability
    }

    /// Writes the per-entry picker atomically, refreshes the scanner snapshot,
    /// and changes the loaded player's exact gap source without touching the
    /// app-wide Skip Silence preference.
    func setSilenceDetectionMode(_ mode: SilenceDetectionMode, for entry: Entry) async {
        if mode == .speech, speechTranscriptAvailability(for: entry) != .available { return }
        await perform("setSilenceDetection \(mode.rawValue) [\(entry.relativePath)]") { service in
            try await service.setSilenceDetectionMode(mode, atEntryPath: entry.relativePath)
            await MainActor.run {
                self.player.configureSilenceDetection(
                    entryID: entry.relativePath, mode: mode
                )
            }
        }
    }

    /// Duplicate Entry (LIB-3): fresh timestamp folder, all files copied,
    /// title "… copy". The copy becomes the selection so the user lands on
    /// what they just made.
    func duplicateEntry(_ entry: Entry) async {
        guard !liveRecordingBlocks(entry.relativePath) else { return }
        guard let service else { return }
        do {
            let newPath = try await service.duplicateEntry(at: entry.relativePath)
            DebugLog.append("duplicateEntry [\(entry.relativePath)] -> [\(newPath)]")
            await refresh { self.selectedEntryID = newPath }
            refreshVaultSearchIfVisible()
        } catch {
            DebugLog.append("duplicateEntry [\(entry.relativePath)]: FAILED \(error)")
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    // MARK: - Search and transcript navigation

    func presentVaultSearch() {
        guard phase == .ready else { return }
        isVaultSearchPresented = true
        scheduleVaultSearch(immediate: true)
    }

    func updateVaultSearchQuery(_ query: String) {
        guard vaultSearchQuery != query else { return }
        vaultSearchQuery = query
        scheduleVaultSearch()
    }

    func retrySearchIndex() {
        guard let service else { return }
        searchIndexTask?.cancel()
        searchIndexState = .indexing
        vaultSearchError = nil
        searchIndexTask = Task { [weak self] in
            do {
                try await service.initializeSearchIndex()
                guard !Task.isCancelled else { return }
                self?.searchIndexDidFinish(for: service, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchIndexDidFinish(for: service, error: error)
            }
        }
    }

    func retryVaultSearch() {
        scheduleVaultSearch(immediate: true)
    }

    func selectSearchHit(_ hit: SearchHit) {
        player.pause()
        sidebarSelection = .folder(hit.entryPath.parentRelativePath)
        selectedEntryID = hit.entryPath
        // A title match selects the entry itself; its UTF-16 range does not
        // belong to either transcript layer and must not drive text/audio cueing.
        transcriptNavigationRequest = hit.matchKind == .content
            ? TranscriptNavigationRequest(hit: hit)
            : nil
        isVaultSearchPresented = false
    }

    func requestInNoteFind() {
        guard selectedEntry != nil else { return }
        inNoteFindRequestRevision &+= 1
    }

    private func scheduleVaultSearch(immediate: Bool = false) {
        vaultSearchTask?.cancel()
        vaultSearchError = nil
        let query = vaultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            vaultSearchResults = []
            vaultSearchIsRunning = false
            return
        }
        guard searchIndexState == .ready, let service else {
            vaultSearchIsRunning = false
            return
        }

        let fuzzy = fuzzyVaultSearch
        let filters = vaultSearchFilters
        vaultSearchIsRunning = true
        vaultSearchTask = Task { [weak self] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                // Metadata filters run outside the text-only SQLite cache.
                // Fetch every text candidate when filtering, then cap the
                // filtered list; otherwise early note-only hits can hide a
                // later Has Audio match for a common query.
                let candidateLimit = filters.isActive ? Int.max : VaultSearchFilters.displayedResultLimit
                let hits = try await service.search(
                    query, fuzzy: fuzzy, limit: candidateLimit
                )
                guard !Task.isCancelled, self?.service === service,
                      self?.vaultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                      self?.fuzzyVaultSearch == fuzzy,
                      self?.vaultSearchFilters == filters else { return }
                self?.vaultSearchResults = self?.applyingSearchFilters(filters, to: hits) ?? hits
                self?.vaultSearchIsRunning = false
            } catch {
                guard !Task.isCancelled, self?.service === service else { return }
                self?.vaultSearchResults = []
                self?.vaultSearchIsRunning = false
                self?.vaultSearchError = error.localizedDescription
            }
        }
    }

    private func refreshVaultSearchIfVisible() {
        guard isVaultSearchPresented, !vaultSearchQuery.isEmpty else { return }
        scheduleVaultSearch(immediate: true)
    }

    /// SRCH-5: hits are filtered against snapshot metadata after the text
    /// query, keeping the search index a pure text cache. Entries missing
    /// from the snapshot (deleted mid-search) are excluded only while a
    /// filter is active — an unfiltered search shows whatever the index said.
    private func applyingSearchFilters(
        _ filters: VaultSearchFilters, to hits: [SearchHit]
    ) -> [SearchHit] {
        guard let snapshot else { return hits }
        return filters.apply(to: hits, entries: snapshot.allEntries)
    }

    // MARK: - Keyboard (search / find / recording / playback / navigation)

    /// One local key monitor instead of per-view `.keyboardShortcut`s:
    /// SwiftUI shortcuts on plain-space are unreliable across focus states,
    /// and menu key equivalents steal keys from text editing. The monitor
    /// runs before both, so it can defer to text input first.
    private func installKeyMonitor() {
        // NSEvent isn't Sendable; hand only key code + modifiers across.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyDown(keyCode: keyCode, modifierFlags: modifierFlags) ?? false
            }
            return consumed ? nil : event
        }
    }

    private let escapeKeyCode: UInt16 = 53
    private let downArrowKeyCode: UInt16 = 125
    private let upArrowKeyCode: UInt16 = 126

    /// Returns true when the event was consumed. Every remappable command is
    /// resolved against `appShortcutPreferences`; only structural keys
    /// (Escape, plain Up/Down) keep fixed handling here.
    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard phase == .ready else { return false }
        // A shortcut-capture control owns the keyboard: captured chords must
        // never dispatch as commands.
        guard !isShortcutCaptureActive else { return false }
        let rawModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        // AppKit marks arrow/keypad events as numeric-pad/function keys even
        // on the built-in keyboard; those implicit flags are not user-held
        // modifiers and must not block matching.
        let modifiers = ShortcutModifiers(
            cocoaFlags: UInt(rawModifiers.subtracting([.numericPad, .function]).rawValue)
        )
        // Field editors (TextField, search) and TextEditor are all NSTextView.
        let focusedTextView = NSApp.keyWindow?.firstResponder as? NSTextView
        // A selectable read-only transcript should not suppress transport
        // shortcuts. Only an actual editor or field editor owns typing keys.
        let editingTextView = focusedTextView?.isEditable == true ? focusedTextView : nil

        if keyCode == escapeKeyCode, modifiers.isEmpty {
            // Let the responder chain dismiss anything visibly in front of the
            // workbench. The global fallback is only for altered app modes,
            // which must cancel even when blank window chrome owns focus.
            guard editingTextView == nil, !foregroundPresentationOwnsEscape else {
                return false
            }
            return handleExitCommand()
        }

        if let action = AppShortcutEventMatcher.action(
            forKeyCode: keyCode,
            modifiers: modifiers,
            isTextEditing: editingTextView != nil,
            preferences: appShortcutPreferences,
            globalChords: configuredGlobalChords
        ) {
            return performAppCommand(action)
        }

        if keyCode == upArrowKeyCode || keyCode == downArrowKeyCode,
           editingTextView == nil, modifiers.isEmpty, middleColumnIsCollapsed {
            // Plain Up/Down normally falls through to the List, but its
            // responder disappears when the responsive layout collapses the
            // middle split item. These keys are reserved, never remappable.
            return moveMiddleSelection(by: keyCode == downArrowKeyCode ? 1 : -1)
        }
        return false
    }

    // MARK: - App command dispatch (menus + remappable shortcuts)

    /// Global chords always outrank local bindings; a local binding equal to a
    /// configured global chord is disabled and flagged in Settings.
    var configuredGlobalChords: [ShortcutChord] {
        globalShortcutPreferences.bindings.values.compactMap { $0 }
    }

    func updateAppShortcutPreferences(_ preferences: AppShortcutPreferences) {
        appShortcutPreferences = preferences
        AppShortcutPreferencesStore.save(preferences)
    }

    func resetAppShortcutPreferences() {
        updateAppShortcutPreferences(.defaults)
    }

    /// One availability calculation for menu items and shortcut dispatch.
    func isAppCommandEnabled(_ action: AppShortcutAction) -> Bool {
        let ready = phase == .ready
        let entry = selectedEntry
        switch action {
        case .newRecording:
            return ready && !isRecordingStartInFlight
                && !recorder.isActive && recorder.state != .finalizing
        case .startStopRecording:
            return ready && !isRecordingStartInFlight
                && recorder.state != .finalizing
        case .pauseOrPlaybackToggle:
            switch recorder.state {
            case .recording: return true
            case .paused: return recorder.canResume
            case .finalizing: return false
            case .idle: return player.url != nil
            }
        case .importAudio, .newFolder, .searchVault, .goToVaultRoot,
             .goToFavorites, .goToRecentlyDeleted, .showTranscriptionQueue,
             .sortByDate, .sortByDuration, .sortByTitle, .sortByRecentlyEdited,
             .toggleSkipSilence, .previousFolder, .nextFolder:
            return ready
        case .toggleFavorite, .renameEntry, .duplicateEntry, .showInfo, .revealInFinder:
            return entry != nil
        case .moveNote:
            return quickMoveBlockReason() == nil
        case .moveToRecentlyDeleted:
            guard let entry else { return false }
            return !liveRecordingBlocks(entry.relativePath)
                && !replacementModeActive
                && !clipMutationEntryPaths.contains(entry.relativePath)
        case .extendRecording:
            if isRecordingStartInFlight { return false }
            if recorder.extensionSession != nil { return true }
            return entry.map { extensionBlockReason(for: $0) == nil } ?? false
        case .editOrSaveNote:
            return workbenchUIState.canEditNote || workbenchUIState.isEditing
        case .copyAsMarkdown:
            return workbenchUIState.hasContent
        case .toggleLayer:
            return workbenchUIState.isForked && !workbenchUIState.isEditing
        case .retranscribe:
            return entry?.hasAudio == true
        case .trimAudio:
            if trimModeActive { return true }
            return entry.map { trimBlockedReason(for: $0, duration: $0.duration) == nil } ?? false
        case .replaceAudio:
            return !isRecordingStartInFlight
                && (entry.map { replacementBlockedReason(for: $0) == nil } ?? false)
        case .compressAudio:
            guard let entry else { return false }
            return entry.hasAudio && !compressingEntryPaths.contains(entry.relativePath)
        case .restoreOriginalAudio:
            return entry.map { originalAudioTrashItem(for: $0) != nil } ?? false
        case .renameSpeakers:
            return workbenchUIState.hasSpeakers && !workbenchUIState.isEditing
        case .deleteAudio:
            guard let entry else { return false }
            return entry.hasAudio
                && !liveRecordingBlocks(entry.relativePath)
                && !compressingEntryPaths.contains(entry.relativePath)
        case .exportMarkdown:
            return entry?.hasTranscript == true
        case .shareAudio:
            return entry?.hasAudio == true
        case .openInObsidian:
            return vaultHasObsidianConfig && entry?.hasTranscript == true
        case .clipUndo, .clipRedo:
            return entry != nil
        case .skipBack, .skipForward, .speedDown, .speedUp, .speedReset,
             .playbackJump0, .playbackJump1, .playbackJump2, .playbackJump3,
             .playbackJump4, .playbackJump5, .playbackJump6, .playbackJump7,
             .playbackJump8, .playbackJump9:
            return player.url != nil
        case .enterZenMode:
            return ready && !recorder.isZenMode
        case .findInNote:
            return ready && entry != nil && !isVaultSearchPresented
        case .showAbout, .showKeyboardShortcuts:
            return true
        }
    }

    /// One dispatch path for menu clicks and matched keyboard shortcuts.
    /// Returns whether the command consumed the invocation; unavailable
    /// commands either give explicit feedback (consumed) or pass the key
    /// through (not consumed), matching the long-standing monitor semantics.
    @discardableResult
    func performAppCommand(_ action: AppShortcutAction) -> Bool {
        // A capture control owns the keyboard: nothing may dispatch, not even
        // via a menu key equivalent the capture view failed to intercept.
        guard !isShortcutCaptureActive else { return false }
        switch action {
        case .newRecording:
            guard isAppCommandEnabled(action) else { return false }
            Task { await startRecording() }
            return true

        case .startStopRecording:
            switch recorder.state {
            case .recording, .paused:
                Task { await stopRecording() }
            case .finalizing:
                break // consume repeats while the recording is being installed
            case .idle:
                Task { await startRecording() }
            }
            return true

        case .pauseOrPlaybackToggle:
            // While recording this is the pause/resume control; playback only
            // gets the chord when the recorder is idle.
            switch recorder.state {
            case .recording:
                if case .replacementTake? = recorder.sessionTarget { return true }
                Task { await toggleRecordingPause() }
                return true
            case .paused:
                guard recorder.canResume else { return false }
                Task { await toggleRecordingPause() }
                return true
            case .finalizing:
                return false
            case .idle:
                guard player.url != nil else { return false }
                player.togglePlayPause()
                return true
            }

        case .importAudio:
            guard isAppCommandEnabled(action) else { return false }
            importViaPanel()
            return true

        case .newFolder:
            guard isAppCommandEnabled(action) else { return false }
            requestNewFolder()
            return true

        case .toggleFavorite:
            guard let entry = selectedEntry else { return false }
            Task { await toggleFavorite(for: entry) }
            return true

        case .renameEntry:
            guard selectedEntry != nil else { return false }
            requestRenameEntry()
            return true

        case .duplicateEntry:
            guard let entry = selectedEntry else { return false }
            Task { await duplicateEntry(entry) }
            return true

        case .moveNote:
            return presentQuickMove()

        case .moveToRecentlyDeleted:
            guard isAppCommandEnabled(action), let entry = selectedEntry else { return false }
            Task { await deleteItem(atRelativePath: entry.relativePath) }
            return true

        case .extendRecording:
            // Contextual: finishes the active extension, otherwise starts one
            // for the selected entry (with feedback when blocked).
            if recorder.extensionSession != nil {
                switch recorder.state {
                case .recording, .paused:
                    Task { await stopRecording() }
                case .finalizing:
                    break // already joining/safely swapping; consume repeats
                case .idle:
                    break // retained recovery state is not a live extension
                }
                return true
            }
            guard let entry = selectedEntry else { return false }
            if let reason = extensionBlockReason(for: entry) {
                errorMessage = reason.explanation
            } else {
                Task { await startExtension(for: entry) }
            }
            return true

        case .editOrSaveNote:
            guard isAppCommandEnabled(action) else { return false }
            requestWorkbenchAction(.editOrSave)
            return true

        case .copyAsMarkdown:
            guard isAppCommandEnabled(action) else { return false }
            requestWorkbenchAction(.copyAsMarkdown)
            return true

        case .toggleLayer:
            guard isAppCommandEnabled(action) else { return false }
            requestWorkbenchAction(.toggleLayer)
            return true

        case .retranscribe:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.retranscribe)
            return true

        case .trimAudio:
            toggleTrimFromShortcut()
            return true

        case .replaceAudio:
            guard let entry = selectedEntry else {
                errorMessage = "Select an audio clip before replacing audio."
                return true
            }
            if let reason = replacementBlockedReason(for: entry) {
                errorMessage = reason
            } else {
                beginReplacement(for: entry)
            }
            return true

        case .compressAudio:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.compress)
            return true

        case .restoreOriginalAudio:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.restoreOriginalAudio)
            return true

        case .renameSpeakers:
            guard isAppCommandEnabled(action) else { return false }
            requestWorkbenchAction(.renameSpeakers)
            return true

        case .deleteAudio:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.deleteAudio)
            return true

        case .showInfo:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.showInfo)
            return true

        case .revealInFinder:
            guard let entry = selectedEntry else { return false }
            revealInFinder(relativePath: entry.relativePath)
            return true

        case .exportMarkdown:
            guard isAppCommandEnabled(action) else { return false }
            requestEntryAction(.exportMarkdown)
            return true

        case .shareAudio:
            guard isAppCommandEnabled(action), let entry = selectedEntry else { return false }
            shareAudioFromMenu(for: entry)
            return true

        case .openInObsidian:
            guard isAppCommandEnabled(action), let entry = selectedEntry else { return false }
            openInObsidian(entry: entry)
            return true

        case .clipUndo, .clipRedo:
            guard let entry = selectedEntry else {
                // Match standard macOS undo behavior: with no applicable
                // document/clip, the command is consumed as a silent no-op.
                return true
            }
            if let reason = clipEditBlockReason(for: entry) {
                errorMessage = reason
                return true
            }
            Task {
                await performClipEdit(action == .clipRedo ? .redo : .undo, for: entry)
            }
            return true

        case .skipBack:
            guard player.url != nil else { return false }
            player.skipBackward()
            return true

        case .skipForward:
            guard player.url != nil else { return false }
            player.skipForward()
            return true

        case .playbackJump0, .playbackJump1, .playbackJump2, .playbackJump3,
             .playbackJump4, .playbackJump5, .playbackJump6, .playbackJump7,
             .playbackJump8, .playbackJump9:
            guard player.url != nil, let fraction = Self.playbackFraction(for: action) else {
                return false
            }
            player.seek(toFraction: fraction)
            return true

        case .speedDown:
            guard player.url != nil else { return false }
            player.stepSpeed(-1)
            return true

        case .speedUp:
            guard player.url != nil else { return false }
            player.stepSpeed(1)
            return true

        case .speedReset:
            guard player.url != nil else { return false }
            player.speed = 1.0
            return true

        case .toggleSkipSilence:
            player.skipSilence.toggle()
            return true

        case .enterZenMode:
            if case .replacementTake? = recorder.sessionTarget { return true }
            recorder.isZenMode = true
            return true

        case .findInNote:
            guard !isVaultSearchPresented else { return false }
            requestInNoteFind()
            return selectedEntry != nil

        case .searchVault:
            presentVaultSearch()
            return true

        case .previousFolder:
            return moveSidebarSelection(by: -1)

        case .nextFolder:
            return moveSidebarSelection(by: 1)

        case .sortByDate:
            guard isAppCommandEnabled(action) else { return false }
            selectEntrySortOrder(.dateNewest)
            return true

        case .sortByDuration:
            guard isAppCommandEnabled(action) else { return false }
            selectEntrySortOrder(.duration)
            return true

        case .sortByTitle:
            guard isAppCommandEnabled(action) else { return false }
            selectEntrySortOrder(.title)
            return true

        case .sortByRecentlyEdited:
            guard isAppCommandEnabled(action) else { return false }
            selectEntrySortOrder(.recentlyEdited)
            return true

        case .goToVaultRoot:
            guard isAppCommandEnabled(action) else { return false }
            sidebarSelection = .folder("")
            return true

        case .goToFavorites:
            guard isAppCommandEnabled(action) else { return false }
            sidebarSelection = .favorites
            return true

        case .goToRecentlyDeleted:
            guard isAppCommandEnabled(action) else { return false }
            sidebarSelection = .recentlyDeleted
            return true

        case .showTranscriptionQueue:
            guard isAppCommandEnabled(action) else { return false }
            requestQueuePopover()
            return true

        case .showAbout:
            AppWindowPresenter.openAuxiliaryWindow(id: AboutCommands.windowID)
            return true

        case .showKeyboardShortcuts:
            AppWindowPresenter.openAuxiliaryWindow(id: KeyboardShortcutsCommands.windowID)
            return true
        }
    }

    /// Like common media players, 1...8 seek in 10% increments while 9 means
    /// the end of the track.
    private static func playbackFraction(for action: AppShortcutAction) -> Double? {
        switch action {
        case .playbackJump0: 0.0
        case .playbackJump1: 0.1
        case .playbackJump2: 0.2
        case .playbackJump3: 0.3
        case .playbackJump4: 0.4
        case .playbackJump5: 0.5
        case .playbackJump6: 0.6
        case .playbackJump7: 0.7
        case .playbackJump8: 0.8
        case .playbackJump9: 1.0
        default: nil
        }
    }

    // MARK: - Quick Move (Move Note…)

    /// Why Move Note… is unavailable right now, or nil when it may present.
    func quickMoveBlockReason() -> String? {
        guard phase == .ready else { return "Open a vault before moving notes." }
        guard sidebarSelection != .recentlyDeleted else {
            return "Recently Deleted items are restored, not moved."
        }
        guard let entry = selectedEntry else { return "Select a note to move." }
        if liveRecordingBlocks(entry.relativePath) {
            return "Stop the recording before moving this note."
        }
        if replacementModeActive {
            return "Finish or cancel replacing audio before moving the note."
        }
        if clipMutationEntryPaths.contains(entry.relativePath) {
            return "Wait for the current audio operation to finish."
        }
        if compressingEntryPaths.contains(entry.relativePath) {
            return "Wait for audio compression to finish."
        }
        return nil
    }

    /// Opens the Move Note picker. If the note is being edited, pending
    /// autosaves are flushed and editing finishes first; the picker does not
    /// open when that save fails.
    @discardableResult
    func presentQuickMove() -> Bool {
        guard let entry = selectedEntry else { return false }
        if let reason = quickMoveBlockReason() {
            errorMessage = reason
            return true
        }
        let entryPath = entry.relativePath
        if workbenchUIState.isEditing {
            requestWorkbenchAction(.finishEditing { [weak self] saved in
                guard let self, saved else { return }
                guard self.selectedEntry?.relativePath == entryPath else { return }
                self.quickMoveEntryPath = entryPath
                self.isQuickMovePresented = true
            })
        } else {
            quickMoveEntryPath = entryPath
            isQuickMovePresented = true
        }
        return true
    }

    /// Every folder the selected note can move to, current parent excluded.
    var quickMoveDestinations: [QuickMoveDestination] {
        guard let entryPath = quickMoveEntryPath, let root = snapshot?.root else { return [] }
        return QuickMoveModel.destinations(
            folderPaths: root.allFolders.map(\.relativePath),
            excludingParentOf: entryPath
        )
    }

    /// Moves the note, then atomically publishes the refreshed snapshot with
    /// the repointed queue and followed selection. On failure the picker stays
    /// open with `quickMoveErrorMessage` set.
    func performQuickMove(to destination: QuickMoveDestination) async {
        guard let entryPath = quickMoveEntryPath, let service, let vaultURL else { return }
        guard !liveRecordingBlocks(entryPath) else {
            quickMoveErrorMessage = "Stop the recording before moving this note."
            return
        }
        let outcome: QuickMoveOutcome
        if !destination.isVaultRoot,
           !FileManager.default.fileExists(
               atPath: vaultURL.appendingRelativePath(destination.path).path
           ) {
            outcome = .destinationMissing
        } else {
            do {
                let newPath = try await service.moveItem(
                    at: entryPath, toFolder: destination.path
                )
                await refresh {
                    self.transcriptionQueue?.repointItems(from: entryPath, to: newPath)
                    self.repointRecoveryArtifacts(from: entryPath, to: newPath)
                    if self.selectedEntryID == entryPath {
                        self.selectedEntryID = newPath
                    }
                }
                refreshVaultSearchIfVisible()
                outcome = .moved(newPath)
            } catch {
                outcome = Self.quickMoveOutcome(for: error, entryPath: entryPath)
            }
        }
        if outcome.isSuccess {
            quickMoveErrorMessage = nil
            isQuickMovePresented = false
        } else {
            quickMoveErrorMessage = outcome.errorDescription
        }
    }

    private static func quickMoveOutcome(
        for error: Error, entryPath: RelativePath
    ) -> QuickMoveOutcome {
        if case VaultError.alreadyExists = error {
            return .collision(entryPath.lastComponent)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return .destinationMissing
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteFileExistsError {
            return .collision(entryPath.lastComponent)
        }
        return .failed(error.localizedDescription)
    }

    /// Sheets, alerts, SwiftUI popovers, and auxiliary windows own their first
    /// Escape. `NSPanel` covers AppKit/SwiftUI transient panels; the named
    /// windows are ordinary NSWindows and therefore need explicit recognition.
    private var foregroundPresentationOwnsEscape: Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.sheetParent != nil || window.attachedSheet != nil { return true }
        if window is NSPanel { return true }
        let identifier = window.identifier?.rawValue
        return identifier == "keyboard-shortcuts"
            || identifier == "about"
            || window.title == "Keyboard Shortcuts"
            || window.title == "About Transcride"
    }

    private func moveSidebarSelection(by offset: Int) -> Bool {
        guard let root = snapshot?.root else { return false }
        // OutlineGroup owns expansion state internally, so descendants of a
        // collapsed folder are not visible navigation targets. Restrict the
        // global shortcut to the sidebar's always-visible rows.
        let visibleFolders = [root] + root.subfolders
        let destinations = visibleFolders.map { SidebarSelection.folder($0.relativePath) }
            + [.favorites, .recentlyDeleted]
        guard !destinations.isEmpty else { return false }
        let currentIndex = sidebarSelection.flatMap { destinations.firstIndex(of: $0) } ?? 0
        let nextIndex = min(destinations.count - 1, max(0, currentIndex + offset))
        sidebarSelection = destinations[nextIndex]
        return true
    }

    private func moveMiddleSelection(by offset: Int) -> Bool {
        switch sidebarSelection {
        case .recentlyDeleted:
            let ids = trashItems.map(\.id)
            guard let nextID = ListSelectionNavigator.adjacentID(
                in: ids,
                selectedID: selectedTrashItemID,
                offset: offset
            ) else { return false }
            selectedTrashItemID = nextID
            return true

        case .folder, .favorites:
            let ids = displayedEntries.map(\.id)
            guard let nextID = ListSelectionNavigator.adjacentID(
                in: ids,
                selectedID: selectedEntryID,
                offset: offset
            ) else { return false }
            selectedEntryID = nextID
            return true

        case .none:
            return false
        }
    }

    // MARK: - Intents (recording)

    /// Folder new recordings/imports land in: the selected folder, or the
    /// vault root when none / Recently Deleted is selected.
    private var newEntryTargetFolder: RelativePath {
        if case .folder(let relPath)? = sidebarSelection { return relPath }
        return ""
    }

    func startRecording() async {
        await performRecordingCommand(.startNew)
    }

    func toggleRecordingPause() async {
        await performRecordingCommand(.pauseResume)
    }

    func stopRecording() async {
        await performRecordingCommand(.stopAndSave)
    }

    /// Awaits any in-flight recording command, then guarantees the live
    /// recording is finalized.
    ///
    /// `performRecordingCommand` is suppressed outright while another command
    /// holds the gate, so termination cannot simply call `stopRecording()`: a
    /// stop already in flight would make the termination task return instantly
    /// and the process would exit mid-encode. Journal recovery makes that
    /// survivable, but "Stop, Save, and Quit" promises the file is saved
    /// *before* the app goes away.
    func stopRecordingForTermination() async {
        // Both gates matter: `startNewRecording` holds the command gate, but a
        // replacement take or an extension claims only the start token, and
        // quitting through either window still has to wait for the microphone
        // to settle before there is anything to stop.
        while recordingCommandGate.commandInFlight != nil || isRecordingStartInFlight {
            await withCheckedContinuation { continuation in
                recordingCommandWaiters.append(continuation)
            }
        }
        guard recorder.state == .recording || recorder.state == .paused else { return }
        await performRecordingCommand(.stopAndSave)
    }

    /// Wakes everything waiting on the recording-command gate. Called from the
    /// same `defer` that releases the gate, on the main actor, so a waiter
    /// added just before the release can never be missed.
    private func signalRecordingCommandFinished() {
        let waiters = recordingCommandWaiters
        recordingCommandWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// The floating indicator is a compact state-dependent toggle. It reuses
    /// the same serialized commands as the global shortcuts and recorder UI.
    func toggleRecordingFromIndicator() async {
        switch recorder.state {
        case .idle:
            await performRecordingCommand(.startNew)
        case .recording, .paused:
            await performRecordingCommand(.stopAndSave)
        case .finalizing:
            break
        }
    }

    func performRecordingCommand(_ command: RecordingCommand) async {
        let state = recordingCommandAvailabilityState(for: command)
        switch recordingCommandGate.begin(command, state: state) {
        case .suppressedRepeat:
            return
        case .unavailable(let reason):
            showGlobalRecordingTransient(.unavailable(
                reason, until: .now.addingTimeInterval(2)
            ))
            if command == .startNew { NSApp.activate(ignoringOtherApps: true) }
            return
        case .perform:
            break
        }
        defer {
            recordingCommandGate.finish(command)
            signalRecordingCommandFinished()
        }

        switch command {
        case .startNew:
            await startNewRecordingImpl()
            if recorder.state == .recording {
                clearGlobalIndicatorRetention()
            }
        case .pauseResume:
            if case .replacementTake? = recorder.sessionTarget {
                showGlobalRecordingTransient(.unavailable(
                    "Replacement takes cannot be paused.",
                    until: .now.addingTimeInterval(2)
                ))
            } else if recorder.state == .paused {
                recorder.resume()
            } else {
                recorder.pause()
            }
            if let message = recorder.alertMessage {
                showGlobalRecordingTransient(.needsAttention(message))
            }
        case .stopAndSave:
            let finalDuration = recorder.elapsed
            globalRecordingTransientState = .saving(elapsed: finalDuration)
            let succeeded = await stopRecordingImpl()
            if !succeeded || recorder.alertMessage != nil || recorder.state != .idle {
                globalRecordingTransientState = .saveFailed(
                    recorder.alertMessage ?? "The recording remains recoverable in Transcride."
                )
            } else {
                let completedAt = Date()
                lastCompletedRecordingAt = completedAt
                beginGlobalIndicatorRetention(after: completedAt)
                showGlobalRecordingTransient(.saved(
                    duration: lastFinalizedRecordingDuration ?? finalDuration,
                    until: .now.addingTimeInterval(2.5)
                ))
            }
        }
    }

    private func recordingCommandAvailabilityState(
        for command: RecordingCommand
    ) -> RecordingCommandAvailabilityState {
        if isRecordingStartInFlight { return .startingMicrophone }
        switch recorder.state {
        case .recording: return .recording
        case .paused:
            if recorder.canResume { return .paused }
            return .pausedResumeUnavailable(
                recorder.alertMessage ?? "Stop & Save before starting another recording."
            )
        case .finalizing:
            return recorder.isStartingMicrophone ? .startingMicrophone : .finalizing
        case .idle:
            guard phase == .ready, let vaultURL else {
                return .idleUnavailable("Open a writable vault in Transcride first.")
            }
            guard FileManager.default.isWritableFile(atPath: vaultURL.path) else {
                return .idleUnavailable("The current vault is not writable.")
            }
            return .idleReady
        }
    }

    private func showGlobalRecordingTransient(
        _ state: GlobalRecordingPresentationState
    ) {
        globalRecordingStateTask?.cancel()
        globalRecordingTransientState = state
        globalRecordingStateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.globalRecordingTransientState = nil
        }
    }

    private func beginGlobalIndicatorRetention(after completedAt: Date) {
        globalIndicatorRetentionTask?.cancel()
        guard let interval = globalShortcutPreferences.backgroundIndicatorRetention.interval else {
            isGlobalIndicatorRetentionActive = true
            return
        }
        let remaining = max(0, completedAt.addingTimeInterval(interval).timeIntervalSinceNow)
        guard remaining > 0 else {
            isGlobalIndicatorRetentionActive = false
            return
        }
        isGlobalIndicatorRetentionActive = true
        globalIndicatorRetentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.isGlobalIndicatorRetentionActive = false
        }
    }

    private func clearGlobalIndicatorRetention() {
        globalIndicatorRetentionTask?.cancel()
        globalIndicatorRetentionTask = nil
        isGlobalIndicatorRetentionActive = false
    }

    private func beginRecordingStart() -> UUID? {
        guard recordingWorkflowStartGate.begin() else { return nil }
        let token = UUID()
        activeRecordingStartToken = token
        isRecordingStartInFlight = true
        return token
    }

    private func finishRecordingStart(_ token: UUID) {
        guard activeRecordingStartToken == token else { return }
        activeRecordingStartToken = nil
        isRecordingStartInFlight = false
        recordingWorkflowStartGate.finish()
        signalRecordingCommandFinished()
    }

    private func recordingStartContextIsCurrent(
        _ token: UUID,
        service: VaultService,
        vaultURL: URL
    ) -> Bool {
        activeRecordingStartToken == token
            && self.service === service
            && self.vaultURL?.standardizedFileURL == vaultURL.standardizedFileURL
    }

    var globalRecordingPresentationState: GlobalRecordingPresentationState {
        recordingPresentationState(requiresRegisteredShortcut: true)
    }

    /// The menu bar remains a working direct-control surface when global
    /// hotkeys are disabled. Its readiness state therefore shares all recorder,
    /// vault, permission, device, and disk checks with the floating indicator,
    /// but does not require the Start shortcut itself to be registered.
    var menuBarRecordingPresentationState: GlobalRecordingPresentationState {
        recordingPresentationState(requiresRegisteredShortcut: false)
    }

    private func recordingPresentationState(
        requiresRegisteredShortcut: Bool
    ) -> GlobalRecordingPresentationState {
        if isRecordingStartInFlight { return .startingMicrophone }
        if let globalRecordingTransientState { return globalRecordingTransientState }
        let toggle = (globalShortcutPreferences.bindings[.toggleRecording] ?? nil)?.glyphDescription ?? ""
        let pause = (globalShortcutPreferences.bindings[.pauseResumeRecording] ?? nil)?.glyphDescription ?? ""
        switch recorder.state {
        case .recording:
            if let warning = recorder.captureHealthMessage {
                return .recordingNeedsAttention(
                    elapsed: recorder.elapsed,
                    message: warning,
                    stopShortcut: toggle
                )
            }
            return .recording(elapsed: recorder.elapsed, pauseShortcut: pause, stopShortcut: toggle)
        case .paused:
            return .paused(
                elapsed: recorder.elapsed,
                pauseShortcut: recorder.canResume ? pause : "Unavailable",
                stopShortcut: toggle
            )
        case .finalizing:
            return recorder.isStartingMicrophone
                ? .startingMicrophone
                : .saving(elapsed: recorder.elapsed)
        case .idle:
            if phase != .ready { return .needsAttention("Open or create a vault to record.") }
            if let message = recorder.alertMessage { return .needsAttention(message) }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                return .needsAttention("Enable Microphone access in System Settings.")
            case .notDetermined:
                return .needsAttention("Microphone access will be requested when you start.")
            default:
                break
            }
            if inputDevices.devices.isEmpty {
                return .needsAttention("No usable microphone input is available.")
            }
            let selectedMicUID = UserDefaults.standard.string(
                forKey: PreferenceKey.preferredMicUID
            ) ?? ""
            if !selectedMicUID.isEmpty,
               inputDevices.device(forUID: selectedMicUID) == nil {
                return .needsAttention("The selected microphone is unavailable. Choose another microphone or System Default.")
            }
            if let vaultURL,
               let capacity = try? vaultURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
               ).volumeAvailableCapacityForImportantUsage,
               capacity < 32 * 1_024 * 1_024 {
                return .needsAttention("The vault volume is too low on free disk space to record safely.")
            }
            if requiresRegisteredShortcut,
               globalShortcutService.statuses[.toggleRecording]?.isRegistered != true {
                return .needsAttention("The Start / Stop shortcut is unavailable. Open Keybinds settings.")
            }
            return .ready(startShortcut: toggle)
        }
    }

    private func startNewRecordingImpl() async {
        guard let service, let vaultURL, !recorder.isActive else { return }
        guard let startToken = beginRecordingStart() else { return }
        defer { finishRecordingStart(startToken) }
        let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""
        guard await RecorderService.ensureMicPermission(
            target: .newEntry,
            preferredMicUID: micUID
        ) else {
            errorMessage = """
            Transcride needs microphone access to record. \
            Enable it in System Settings → Privacy & Security → Microphone, then try again.
            """
            showGlobalRecordingTransient(.needsAttention(
                errorMessage ?? "Microphone access is required."
            ))
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard recordingStartContextIsCurrent(
            startToken,
            service: service,
            vaultURL: vaultURL
        ) else {
            errorMessage = "Recording did not start because the active vault changed."
            return
        }
        let quality = RecordingQuality(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
        ) ?? .compressed
        let folder = newEntryTargetFolder
        var createdPath: RelativePath?
        do {
            let relPath = try await service.createEntryFolder(inFolder: folder, date: .now)
            createdPath = relPath
            guard recordingStartContextIsCurrent(
                startToken,
                service: service,
                vaultURL: vaultURL
            ) else {
                throw RecorderError.recordingContextChanged
            }
            try await recorder.start(
                entryURL: vaultURL.appendingRelativePath(relPath),
                relativePath: relPath,
                quality: quality,
                preferredMicUID: micUID
            )
            globalRecordingStateTask?.cancel()
            globalRecordingTransientState = nil
            updateLiveTranscription()
            // The microphone is live: hold the start token any longer and the
            // full vault rescan below would reject a Stop or Pause with "the
            // microphone is still starting". The `defer` above stays as the
            // error-path backstop and is idempotent (it re-checks the token).
            finishRecordingStart(startToken)
            await refresh()
        } catch {
            DebugLog.append("startRecording FAILED \(error)")
            if let createdPath {
                try? await service.removeEmptyEntryFolder(at: createdPath)
            }
            errorMessage = "Recording could not start: \(error.localizedDescription)"
            showGlobalRecordingTransient(.needsAttention(
                errorMessage ?? "Recording could not start."
            ))
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func extensionBlockReason(for entry: Entry) -> RecordingExtensionBlockReason? {
        guard entry.hasAudio else { return entry.audioDeleted ? .audioDeleted : .noAudio }
        if unresolvedExtensionRecoveryEntryPaths.contains(entry.relativePath) {
            return .recoveryPending
        }
        if recorder.isActive { return .recorderBusy }
        if trimModeActive { return .entryBusy("trimming") }
        if replacementModeActive { return .entryBusy("replacing audio") }
        if compressingEntryPaths.contains(entry.relativePath) {
            return .entryBusy("compressing")
        }
        if clipMutationEntryPaths.contains(entry.relativePath) {
            return .entryBusy("updating audio")
        }
        if transcriptionBusyEntryPaths.contains(entry.relativePath) { return .transcriptionBusy }
        if unsupportedExtensionEntryPaths.contains(entry.relativePath) { return .unsupportedAudio }
        return nil
    }

    func replacementBlockedReason(for entry: Entry) -> String? {
        guard entry.hasAudio else { return entry.audioUnavailableExplanation ?? "No audio is available." }
        if recorder.isActive { return "Stop the active recording before replacing audio." }
        if trimModeActive { return "Finish or cancel trimming before replacing audio." }
        if compressingEntryPaths.contains(entry.relativePath) {
            return "Wait for audio compression to finish."
        }
        if clipMutationEntryPaths.contains(entry.relativePath) {
            return "Wait for the current audio operation to finish."
        }
        if transcriptionBusyEntryPaths.contains(entry.relativePath) {
            return "Wait for transcription to finish before replacing audio."
        }
        if replacementModeActive {
            return replacementEntryPath == entry.relativePath
                ? "A replacement session is already active."
                : "Finish the current replacement session first."
        }
        return nil
    }

    func beginReplacement(for entry: Entry) {
        guard replacementBlockedReason(for: entry) == nil else { return }
        player.clearPlaybackRange()
        player.pause()
        replacementTakeWaveform = nil
        replacementTakeWaveformID = nil
        replacementPreviewTakeID = nil
        replacementEntryPath = entry.relativePath
        replacementPreviewLabel = "Current Audio"
    }

    func armNextReplacementFailure(_ point: AudioReplacementFailurePoint) {
        nextReplacementFailurePoint = point
        let stage = point == .beforeRender ? "render" : "safe-swap"
        errorMessage = "Testing: the next replacement bake is armed to fail before the \(stage) stage. Dismiss this message, then bake a complete take."
    }

    func startReplacementTake(
        for entry: Entry, selection: AudioRangeSelection
    ) async {
        guard let service, let vaultURL, let audioName = entry.audioFileName,
              replacementEntryPath == entry.relativePath,
              !recorder.isActive else { return }
        guard let startToken = beginRecordingStart() else { return }
        defer { finishRecordingStart(startToken) }
        // Audition playback must never bleed into microphone capture.
        player.pause()
        let session: ReplacementTakeSession
        if let existing = replacementSession {
            session = existing
        } else {
            let timeline: ReplacementTimeline
            do {
                timeline = try await service.replacementTimeline(
                    entryRelativePath: entry.relativePath, audioFileName: audioName
                )
                guard recordingStartContextIsCurrent(
                    startToken,
                    service: service,
                    vaultURL: vaultURL
                ) else {
                    throw RecorderError.recordingContextChanged
                }
            } catch {
                errorMessage = "The audio timeline could not be read for replacement: \(error.localizedDescription)"
                return
            }
            let preciseSelection = selection.clamped(toDuration: timeline.duration)
            guard preciseSelection.isValidReplacement(ofDuration: timeline.duration) else { return }
            let region = ReplacementRegion(
                selection: preciseSelection,
                timelineDuration: timeline.duration,
                sampleRate: timeline.sampleRate
            )
            session = ReplacementTakeSession(
                entryRelativePath: entry.relativePath,
                sourceAudioFileName: audioName,
                timelineDuration: timeline.duration,
                region: region
            )
            replacementSession = session
        }
        let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""
        guard await RecorderService.ensureMicPermission(
            target: .replacementTake,
            preferredMicUID: micUID
        ) else {
            errorMessage = "Transcride needs microphone access to record a replacement take. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        guard recordingStartContextIsCurrent(
            startToken,
            service: service,
            vaultURL: vaultURL
        ) else {
            errorMessage = "The replacement take did not start because the active vault changed."
            return
        }
        do {
            var capturing = session
            capturing.phase = .capturing
            replacementSession = capturing
            try await service.saveReplacementSession(capturing)
            guard recordingStartContextIsCurrent(
                startToken,
                service: service,
                vaultURL: vaultURL
            ) else {
                throw RecorderError.recordingContextChanged
            }
            let quality = RecordingQuality(
                rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
            ) ?? .compressed
            let target = ReplacementRecordingTarget(
                entryRelativePath: entry.relativePath,
                sessionID: capturing.id,
                region: capturing.region,
                takeNumber: capturing.takes.count + 1
            )
            recorder.onReplacementBoundaryReached = { [weak self] in
                Task { @MainActor [weak self] in await self?.stopReplacementTake() }
            }
            try await recorder.start(
                entryURL: vaultURL.appendingRelativePath(entry.relativePath),
                relativePath: entry.relativePath,
                quality: quality,
                preferredMicUID: micUID,
                target: .replacementTake(target)
            )
            replacementPreviewLabel = "Recording Take \(target.takeNumber)"
        } catch {
            recorder.onReplacementBoundaryReached = nil
            if let recorderError = error as? RecorderError,
               recorderError.isStartOwnershipConflict {
                var ready = session
                ready.phase = .ready
                ready.failureMessage = nil
                replacementSession = ready
                try? await service.saveReplacementSession(ready)
                errorMessage = recorderError == .recordingContextChanged
                    ? "The replacement take did not start because the active vault changed."
                    : "A recording started before the replacement take could claim the microphone. Try the take again after it finishes."
                return
            }
            replacementSession?.phase = .failed
            replacementSession?.failureMessage = error.localizedDescription
            errorMessage = "The replacement take could not start: \(error.localizedDescription)"
        }
    }

    func stopReplacementTake() async {
        // `sessionTarget` stays non-nil all the way through finalization, so it
        // cannot serialize the three entrants (region-boundary callback, UI
        // Stop, global Stop command). The recorder state can: `stop()` moves to
        // `.finalizing` synchronously before its first await, so a second
        // main-actor entrant returns here instead of getting nil back from
        // `stop()` and reporting a failure during a successful save. Mirrors
        // the guard in `RecorderService.cancelReplacementCapture`.
        guard case .replacementTake? = recorder.sessionTarget,
              recorder.state == .recording || recorder.state == .paused,
              let service, var session = replacementSession else { return }
        let sessionID = session.id
        let entryRelativePath = session.entryRelativePath
        recorder.onReplacementBoundaryReached = nil
        guard let outcome = await recorder.stop(),
              let take = outcome.replacementTake else {
            if replacementSession?.id != sessionID {
                try? await service.cancelReplacementSession(
                    entryRelativePath: entryRelativePath
                )
                return
            }
            errorMessage = recorder.alertMessage ?? "The replacement take could not be finalized."
            return
        }
        // Main-actor methods are re-entrant across recorder finalization. If
        // Cancel ran meanwhile, do not allow the completed encode to recreate
        // the discarded ledger; clean it once more after finalization.
        guard replacementSession?.id == sessionID,
              replacementEntryPath == entryRelativePath else {
            try? await service.cancelReplacementSession(entryRelativePath: entryRelativePath)
            return
        }
        session.appendTake(take)
        replacementSession = session
        replacementPreviewLabel = take.status == .complete
            ? "Take \(take.number)" : "Incomplete Take \(take.number)"
        do {
            try await service.saveReplacementSession(session)
        } catch {
            errorMessage = "The take was captured but its session could not be saved: \(error.localizedDescription)"
        }
        if take.status == .complete {
            await prepareReplacementPreview(for: take, scope: .region, autoplay: false)
        }
    }

    func selectReplacementTake(_ take: ReplacementTake) async {
        if replacementSession?.selectedTakeID == take.id {
            await prepareReplacementPreview(for: take, scope: .region, autoplay: false)
            return
        }
        replacementSession?.selectedTakeID = take.id
        replacementTakeWaveform = nil
        replacementTakeWaveformID = nil
        if let session = replacementSession, let service {
            try? await service.saveReplacementSession(session)
        }
        if take.status == .complete {
            await prepareReplacementPreview(for: take, scope: .region, autoplay: false)
        }
    }

    func playReplacementTake(_ take: ReplacementTake) async {
        guard let service, let session = replacementSession else { return }
        if take.status == .complete {
            if session.selectedTakeID != take.id {
                await selectReplacementTake(take)
            }
            await prepareReplacementPreview(for: take, scope: .region, autoplay: true)
            return
        }
        let url = await service.replacementTakeURL(
            entryRelativePath: session.entryRelativePath, fileName: take.fileName
        )
        player.clearPlaybackRange()
        player.load(url: url, knownDuration: take.duration)
        player.play()
        replacementPreviewLabel = "Incomplete Take \(take.number)"
    }

    func replacementTakeURL(_ take: ReplacementTake) -> URL? {
        guard let vaultURL, let session = replacementSession else { return nil }
        return vaultURL.appendingRelativePath(session.entryRelativePath)
            .appending(
                path: AudioReplacementArtifacts.sessionDirectoryName,
                directoryHint: .isDirectory
            )
            .appending(path: take.fileName)
    }

    func previewReplacementInContext(_ take: ReplacementTake) async {
        guard let session = replacementSession, take.status == .complete else { return }
        if session.selectedTakeID != take.id {
            await selectReplacementTake(take)
        }
        await prepareReplacementPreview(for: take, scope: .fullContext, autoplay: true)
    }

    private enum ReplacementPreviewScope {
        case region
        case fullContext
    }

    private func prepareReplacementPreview(
        for take: ReplacementTake,
        scope: ReplacementPreviewScope,
        autoplay: Bool
    ) async {
        guard let service, let session = replacementSession,
              session.takes.contains(where: { $0.id == take.id }),
              take.status == .complete else { return }

        if replacementPreviewTakeID == take.id, replacementPreviewURL != nil,
           replacementTakeWaveformID == take.id {
            configureReplacementPlayback(
                session: session, take: take, scope: scope, autoplay: autoplay
            )
            return
        }

        let generation = UUID()
        replacementPreviewGeneration = generation
        player.unload()
        replacementPreviewLabel = "Preparing Take \(take.number)…"
        do {
            let takeWaveform = try await service.replacementTakeWaveform(
                entryRelativePath: session.entryRelativePath, fileName: take.fileName
            )
            guard replacementPreviewGeneration == generation,
                  replacementSession?.id == session.id,
                  replacementSession?.selectedTakeID == take.id else { return }
            replacementTakeWaveform = takeWaveform
            replacementTakeWaveformID = take.id

            let url = try await service.replacementContextPreview(session: session, take: take)
            guard replacementPreviewGeneration == generation,
                  replacementSession?.id == session.id,
                  replacementSession?.selectedTakeID == take.id else {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                return
            }
            if let old = replacementPreviewURL {
                try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
            }
            replacementPreviewURL = url
            replacementPreviewTakeID = take.id
            player.load(url: url, knownDuration: session.timelineDuration)
            configureReplacementPlayback(
                session: session, take: take, scope: scope, autoplay: autoplay
            )
        } catch {
            guard replacementPreviewGeneration == generation else { return }
            errorMessage = "The replacement preview could not be prepared: \(error.localizedDescription)"
        }
    }

    private func configureReplacementPlayback(
        session: ReplacementTakeSession,
        take: ReplacementTake,
        scope: ReplacementPreviewScope,
        autoplay: Bool
    ) {
        player.pause()
        switch scope {
        case .region:
            player.setPlaybackRange(start: session.region.start, end: session.region.end)
            player.seek(to: session.region.start)
            replacementPreviewLabel = "Take \(take.number) — replacement region"
        case .fullContext:
            player.clearPlaybackRange()
            player.seek(to: 0)
            replacementPreviewLabel = "Preview in Context — Take \(take.number)"
        }
        if autoplay { player.play() }
    }

    func deleteReplacementTake(_ take: ReplacementTake) async {
        guard let service, var session = replacementSession,
              recorder.sessionTarget == nil else { return }
        do {
            if replacementPreviewTakeID == take.id {
                replacementPreviewGeneration = nil
                player.unload()
                if let old = replacementPreviewURL {
                    try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
                }
                replacementPreviewURL = nil
                replacementPreviewTakeID = nil
            }
            try await service.deleteReplacementTake(
                entryRelativePath: session.entryRelativePath, fileName: take.fileName
            )
            session.takes.removeAll { $0.id == take.id }
            if session.selectedTakeID == take.id {
                session.selectedTakeID = session.takes.last(where: { $0.status == .complete })?.id
            }
            replacementSession = session
            try await service.saveReplacementSession(session)
            if let selected = session.selectedTake {
                await prepareReplacementPreview(
                    for: selected, scope: .region, autoplay: false
                )
            } else {
                replacementTakeWaveform = nil
                replacementTakeWaveformID = nil
            }
        } catch {
            errorMessage = "The take could not be deleted: \(error.localizedDescription)"
        }
    }

    func bakeSelectedReplacement() async {
        guard let service, let session = replacementSession,
              let take = session.selectedTake, session.selectedTakeCanBake else { return }
        player.unload()
        do {
            let injectedFailurePoint = nextReplacementFailurePoint
            nextReplacementFailurePoint = nil
            transcriptionQueue?.evictItems(underPath: session.entryRelativePath)
            _ = try await service.bakeReplacement(
                session: session,
                take: take,
                injectedFailurePoint: injectedFailurePoint
            )
            audioRevision &+= 1
            queueExtensionRetranscription(
                entryRelativePath: session.entryRelativePath,
                source: TranscriptionSeam.Source.replaced.rawValue
            )
            try? await service.cancelReplacementSession(
                entryRelativePath: session.entryRelativePath
            )
            replacementSession = nil
            replacementEntryPath = nil
            replacementPreviewLabel = nil
            replacementTakeWaveform = nil
            replacementTakeWaveformID = nil
            replacementPreviewGeneration = nil
            replacementPreviewTakeID = nil
            await refresh { self.selectedEntryID = session.entryRelativePath }
        } catch {
            errorMessage = "The replacement was not installed. Your current audio and complete takes are safe: \(error.localizedDescription)"
        }
    }

    func cancelReplacement() async {
        guard let replacementEntryPath else { return }
        await cancelReplacement(expectedEntryPath: replacementEntryPath)
    }

    private func cancelReplacement(expectedEntryPath: RelativePath) async {
        guard replacementEntryPath == expectedEntryPath else { return }
        if case .replacementTake(let target)? = recorder.sessionTarget,
           target.entryRelativePath == expectedEntryPath {
            await recorder.cancelReplacementCapture()
        }
        // Clear the app-wide mutation lock before awaiting disk cleanup. This
        // makes every exit path converge immediately and also invalidates any
        // in-flight take finalization before it can append to the UI ledger.
        replacementSession = nil
        replacementEntryPath = nil
        replacementPreviewLabel = nil
        replacementTakeWaveform = nil
        replacementTakeWaveformID = nil
        replacementPreviewGeneration = nil
        replacementPreviewTakeID = nil
        let previewURL = replacementPreviewURL
        replacementPreviewURL = nil
        player.unload()
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
        }
        var cleanupError: Error?
        if let service {
            do {
                try await service.cancelReplacementSession(
                    entryRelativePath: expectedEntryPath
                )
            } catch {
                cleanupError = error
            }
        }
        // A take/context preview uses the same player as canonical playback.
        // Explicitly restore the selected entry's real audio; merely pausing
        // leaves Cancel sounding as if the replacement had persisted.
        if selectedEntryID == expectedEntryPath,
           let entry = snapshot?.entry(withID: expectedEntryPath),
           let url = audioURL(for: entry) {
            player.load(url: url, knownDuration: entry.duration)
        }
        if let cleanupError {
            errorMessage = "The replacement was cancelled, but its temporary files could not be removed yet. They will be discarded on relaunch: \(cleanupError.localizedDescription)"
        }
    }

    func validateExtensionAvailability(for entry: Entry) async {
        guard entry.hasAudio, let service else { return }
        if await service.audioSupportsExtension(atEntryPath: entry.relativePath) {
            unsupportedExtensionEntryPaths.remove(entry.relativePath)
        } else {
            unsupportedExtensionEntryPaths.insert(entry.relativePath)
        }
    }

    func startExtension(for entry: Entry) async {
        guard let service, let vaultURL, let audioName = entry.audioFileName,
              let startToken = beginRecordingStart() else { return }
        defer { finishRecordingStart(startToken) }
        let supportsExtension = await service.audioSupportsExtension(
            atEntryPath: entry.relativePath
        )
        guard recordingStartContextIsCurrent(
            startToken,
            service: service,
            vaultURL: vaultURL
        ) else {
            errorMessage = "The recording extension did not start because the active vault changed."
            return
        }
        if supportsExtension {
            unsupportedExtensionEntryPaths.remove(entry.relativePath)
        } else {
            unsupportedExtensionEntryPaths.insert(entry.relativePath)
        }
        let recoveryDiscovery = await service.recordingExtensionRecoveries()
        guard recordingStartContextIsCurrent(
            startToken,
            service: service,
            vaultURL: vaultURL
        ) else {
            errorMessage = "The recording extension did not start because the active vault changed."
            return
        }
        if recoveryDiscovery.hasUnresolvedRecovery(for: entry.relativePath) {
            unresolvedExtensionRecoveryEntryPaths.insert(entry.relativePath)
            for recovery in recoveryDiscovery.recoverable
            where recovery.entryRelativePath == entry.relativePath
                && !extensionRecoveries.contains(where: { $0.id == recovery.id }) {
                extensionRecoveries.append(recovery)
            }
            isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
            errorMessage = recoveryDiscovery.malformedEntryPaths.contains(entry.relativePath)
                ? "The previous extension's recovery metadata is malformed. Its audio artifacts were kept; resolve or preserve them before recording another segment."
                : RecordingExtensionBlockReason.recoveryPending.explanation
            return
        }
        // Recovery may have been resolved externally since the vault opened.
        // The fresh disk scan is authoritative; do not let a stale cache block
        // this entry forever after all guarded artifacts are gone.
        unresolvedExtensionRecoveryEntryPaths.remove(entry.relativePath)
        extensionRecoveries.removeAll {
            $0.entryRelativePath == entry.relativePath
        }
        isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
        guard
              extensionBlockReason(for: entry) == nil else { return }
        let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""
        guard await RecorderService.ensureMicPermission(
            target: .extensionRecording,
            preferredMicUID: micUID
        ) else {
            errorMessage = "Transcride needs microphone access to extend a recording. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        guard recordingStartContextIsCurrent(
            startToken,
            service: service,
            vaultURL: vaultURL
        ) else {
            errorMessage = "The recording extension did not start because the active vault changed."
            return
        }
        player.pause()
        player.unload()
        let quality = RecordingQuality(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
        ) ?? .compressed
        let target = RecordingExtensionTarget(
            entryRelativePath: entry.relativePath,
            sourceAudioFileName: audioName,
            sourceDuration: entry.duration ?? 0
        )
        do {
            try await recorder.start(
                entryURL: vaultURL.appendingRelativePath(entry.relativePath),
                relativePath: entry.relativePath,
                quality: quality,
                preferredMicUID: micUID,
                target: .extensionOf(target)
            )
            updateLiveTranscription()
        } catch {
            errorMessage = "The recording could not be extended: \(error.localizedDescription)"
        }
    }

    private func stopRecordingImpl() async -> Bool {
        lastFinalizedRecordingDuration = nil
        if case .replacementTake? = recorder.sessionTarget {
            await stopReplacementTake()
            return recorder.state == .idle && recorder.alertMessage == nil
        }
        let coordination = await RecordingStopCoordinator.run(
            clearLiveDisplay: { self.stopLiveTranscription() },
            finalizeAndInstall: { await self.recorder.stop() },
            isReadyForHandoff: { $0.finalizationSucceeded },
            handoffFinalized: { await self.completeFinalizedRecording($0) }
        )
        switch coordination {
        case .handedOff(let succeeded):
            return succeeded
        case .notReady(let outcome):
            // The hidden microphone journal remains recoverable. In particular,
            // no search sync or transcription seam is invoked for this path.
            lastFinalizedRecordingDuration = outcome.duration
            return false
        case .noOutcome:
            return false
        }
    }

    private func completeFinalizedRecording(
        _ outcome: RecorderService.FinalizationOutcome
    ) async -> Bool {
        lastFinalizedRecordingDuration = outcome.duration
        let relPath = outcome.entryRelativePath
        if case .extensionOf(let target) = outcome.target {
            guard let service else { return false }
            guard let segmentURL = outcome.extensionSegmentURL else {
                recorder.completeExtensionWorkflow()
                recordingRecoveryNoticeMessage = "The extension was too short to append, so it was discarded. The existing recording was not changed."
                return false
            }
            do {
                transcriptionQueue?.evictItems(underPath: relPath)
                _ = try await service.extendAudio(
                    target: target, segmentURL: segmentURL
                )
                audioRevision &+= 1
                queueExtensionRetranscription(
                    entryRelativePath: relPath, source: TranscriptionSeam.Source.extended.rawValue
                )
                recorder.completeExtensionWorkflow()
                await refresh { self.selectedEntryID = relPath }
                return true
            } catch {
                recorder.completeExtensionWorkflow(error: error)
                errorMessage = "The extension segment is safe, but it could not be appended: \(error.localizedDescription)"
                let discovery = await service.recordingExtensionRecoveries()
                extensionRecoveries = discovery.recoverable
                unresolvedExtensionRecoveryEntryPaths = Set(
                    discovery.recoverable.map(\.entryRelativePath)
                        + discovery.malformedEntryPaths
                )
                isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
                return false
            }
        }
        switch outcome.captureResult {
        case .noFrames:
            do {
                try await service?.removeEmptyEntryFolder(at: relPath)
                await refresh()
            } catch {
                errorMessage = "No audio was captured, and the empty entry folder could not be removed: \(error.localizedDescription)"
            }
            return false
        case .noSignal:
            await service?.synchronizeSearchEntry(at: relPath)
            await refresh { self.selectedEntryID = relPath }
            return false
        case .captured:
            guard outcome.canonicalAudioInstalled else { return false }
        }
        if case .microphoneOnly(.mixFailed) = outcome.systemAudioStatus {
            recordingRecoveryNoticeMessage = "The recording was saved from the microphone. Mac audio could not be mixed safely, so the pristine microphone recording was kept."
        }
        await service?.synchronizeSearchEntry(at: relPath)
        // Enqueue before the rescan so the entry's first selected frame
        // already carries its "waiting to transcribe" status row.
        TranscriptionSeam.audioEntryReady(entryRelativePath: relPath, source: .recorded)
        await refresh { self.selectedEntryID = relPath }
        return true
    }

    var cancelRecordingConfirmationMessage: String {
        switch recorder.sessionTarget {
        case .extensionOf:
            "Are you sure you want to cancel recording? The captured extension will be discarded and the existing recording will remain unchanged."
        case .replacementTake:
            "Are you sure you want to cancel recording? This replacement take will be discarded. Any earlier takes will remain available."
        default:
            "Are you sure you want to cancel recording? The recording will be permanently discarded."
        }
    }

    func discardActiveRecording() async {
        isCancelRecordingConfirmationPresented = false
        stopLiveTranscription()
        guard let cancelled = await recorder.cancelActiveCapture() else { return }
        recorder.isZenMode = false

        switch cancelled.target {
        case .newEntry:
            do {
                try await service?.removeEmptyEntryFolder(at: cancelled.entryRelativePath)
                await refresh()
            } catch {
                errorMessage = "The recording was discarded, but its empty folder could not be removed: \(error.localizedDescription)"
            }
        case .extensionOf:
            await refresh { self.selectedEntryID = cancelled.entryRelativePath }
            restoreCanonicalPlayback(for: cancelled.entryRelativePath)
        case .replacementTake:
            if var session = replacementSession,
               session.entryRelativePath == cancelled.entryRelativePath {
                session.phase = .ready
                session.failureMessage = nil
                replacementSession = session
                replacementPreviewLabel = session.selectedTake.map { "Take \($0.number)" }
                    ?? "Current Audio"
                do {
                    try await service?.saveReplacementSession(session)
                } catch {
                    errorMessage = "The take was discarded, but the replacement session could not be updated: \(error.localizedDescription)"
                }
            }
        }
    }

    private func restoreCanonicalPlayback(for entryRelativePath: RelativePath) {
        guard selectedEntryID == entryRelativePath,
              let entry = snapshot?.entry(withID: entryRelativePath),
              let url = audioURL(for: entry) else { return }
        player.load(url: url, knownDuration: entry.duration)
    }

    func finishRecoveredExtension(_ recovery: RecoverableRecordingExtension) async {
        guard let service, !extensionRecoveryProcessingIDs.contains(recovery.id) else { return }
        extensionRecoveryProcessingIDs.insert(recovery.id)
        clipMutationEntryPaths.insert(recovery.entryRelativePath)
        defer {
            extensionRecoveryProcessingIDs.remove(recovery.id)
            clipMutationEntryPaths.remove(recovery.entryRelativePath)
        }
        do {
            _ = try await service.finishRecoveredExtension(recovery)
            queueExtensionRetranscription(
                entryRelativePath: recovery.entryRelativePath,
                source: "extension-recovery"
            )
            extensionRecoveries.removeAll { $0.id == recovery.id }
            unresolvedExtensionRecoveryEntryPaths.remove(recovery.entryRelativePath)
            isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
            audioRevision &+= 1
            await refresh { self.selectedEntryID = recovery.entryRelativePath }
        } catch {
            errorMessage = "The extension could not be finished. Its segment remains recoverable: \(error.localizedDescription)"
        }
    }

    func saveRecoveredExtensionAsNewEntry(
        _ recovery: RecoverableRecordingExtension
    ) async {
        guard let service, !extensionRecoveryProcessingIDs.contains(recovery.id) else { return }
        extensionRecoveryProcessingIDs.insert(recovery.id)
        defer { extensionRecoveryProcessingIDs.remove(recovery.id) }
        do {
            let newPath = try await service.saveRecoveredExtensionAsNewEntry(recovery)
            transcriptionQueue?.enqueue(
                entryRelativePath: newPath,
                source: "extension-segment-recovery"
            )
            extensionRecoveries.removeAll { $0.id == recovery.id }
            unresolvedExtensionRecoveryEntryPaths.remove(recovery.entryRelativePath)
            isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
            await refresh { self.selectedEntryID = newPath }
        } catch {
            errorMessage = "The extension segment could not be saved as a new entry: \(error.localizedDescription)"
        }
    }

    func discardRecoveredExtension(_ recovery: RecoverableRecordingExtension) async {
        guard let service, !extensionRecoveryProcessingIDs.contains(recovery.id) else { return }
        extensionRecoveryProcessingIDs.insert(recovery.id)
        await service.discardRecoveredExtension(recovery)
        extensionRecoveryProcessingIDs.remove(recovery.id)
        extensionRecoveries.removeAll { $0.id == recovery.id }
        unresolvedExtensionRecoveryEntryPaths.remove(recovery.entryRelativePath)
        isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
        await refresh()
    }

    private func queueExtensionRetranscription(
        entryRelativePath: RelativePath, source: String
    ) {
        guard let transcriptionQueue else { return }
        let alreadyQueued = transcriptionQueue.items.contains {
            $0.entryRelativePath == entryRelativePath
                && $0.isRetranscribe
                && ($0.source == TranscriptionSeam.Source.extended.rawValue
                    || $0.source == TranscriptionSeam.Source.replaced.rawValue
                    || $0.source == "extension-recovery")
        }
        guard !alreadyQueued else { return }
        transcriptionQueue.enqueue(
            entryRelativePath: entryRelativePath,
            source: source,
            isRetranscribe: true
        )
    }

    // MARK: - Live transcription (M3 addendum)

    /// Attaches live transcription to the running recording when wanted —
    /// always in Zen mode, by preference in the main window. Safe to call
    /// again mid-recording (entering Zen, flipping the toggle on).
    func updateLiveTranscription() {
        guard recorder.isActive, !liveTranscriber.isSessionActive else { return }
        let wanted = recorder.isZenMode
            || UserDefaults.standard.bool(forKey: LiveTranscriber.enabledKey)
        guard wanted else { return }
        guard modelManager.state(forModelInfoID: ModelCatalog.parakeetV3.id).isDownloaded else {
            liveTranscriber.markModelMissing()
            return
        }
        recorder.liveTee.set(liveTranscriber.begin())
    }

    /// Prepares the heavier streaming model before recording begins. Zen
    /// calls this on entry so its first short memo can display words live.
    func prepareLiveTranscription() {
        let wanted = recorder.isZenMode
            || UserDefaults.standard.bool(forKey: LiveTranscriber.enabledKey)
        guard wanted else { return }
        guard modelManager.state(forModelInfoID: ModelCatalog.parakeetV3.id).isDownloaded else {
            liveTranscriber.markModelMissing()
            return
        }
        liveTranscriber.prepare()
    }

    private func stopLiveTranscription() {
        recorder.liveTee.set(nil)
        liveTranscriber.end()
    }

    func prepareActiveRecordingForDeferredRecovery() async {
        stopLiveTranscription()
        await recorder.preserveActiveCaptureForRecovery()
    }

    /// A transcription landed: refresh, follow an auto-title rename, and let
    /// the detail view know its transcript changed on disk.
    private func entryTranscribed(originalPath: RelativePath, outcome: TranscriptionApplier.Outcome) {
        if outcome.markdownLeftAlone {
            transcriptNoticeMessage = "The Original transcript was refreshed. Your Edited transcript was left untouched."
        }
        refreshVaultSearchIfVisible()
        Task {
            // One turn for the rescan, the reload trigger and any auto-title
            // selection remap: the detail view sees a single taskKey change
            // (remapping before the rescan lands would leave selectedEntry
            // resolving to nil — a "No Entry Selected" flash — and bumping
            // the revision separately would reload the transcript twice).
            await refresh {
                self.transcriptRevision += 1
                if outcome.entryRelativePath != originalPath {
                    // An auto-title rename moves the folder too, so any
                    // launch-captured recovery record has to follow it.
                    self.repointRecoveryArtifacts(
                        from: originalPath, to: outcome.entryRelativePath
                    )
                    if self.selectedEntryID == originalPath {
                        self.selectedEntryID = outcome.entryRelativePath
                    }
                }
            }
        }
    }

    // MARK: - Intents (import)

    func importViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.message = "Each file becomes a new entry; the originals are not touched."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AudioImportFormat.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await importFiles(panel.urls) }
    }

    /// Imports each file into its own entry. Per-file failures don't block the
    /// rest of the batch; they're reported together at the end.
    func importFiles(_ urls: [URL]) async {
        guard let service else { return }
        let folder = newEntryTargetFolder
        var failures: [String] = []
        var lastImported: RelativePath?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let relPath = try await service.importAudioFile(from: url, toFolder: folder)
                lastImported = relPath
                TranscriptionSeam.audioEntryReady(entryRelativePath: relPath, source: .imported)
                DebugLog.append("import ok [\(relPath)] from \(url.lastPathComponent)")
            } catch {
                DebugLog.append("import FAILED \(url.lastPathComponent): \(error)")
                failures.append(error.localizedDescription)
            }
        }
        await refresh()
        refreshVaultSearchIfVisible()
        if let lastImported { selectedEntryID = lastImported }
        if !failures.isEmpty {
            let imported = urls.count - failures.count
            errorMessage = (imported > 0 ? "\(imported) of \(urls.count) files were imported. " : "")
                + "These failed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Playback helpers

    func audioURL(for entry: Entry) -> URL? {
        guard let vaultURL, let audioFileName = entry.audioFileName else { return nil }
        return vaultURL.appendingRelativePath(entry.relativePath).appending(path: audioFileName)
    }

    func waveform(for entry: Entry) async throws -> WaveformData? {
        guard let service, let audioFileName = entry.audioFileName else { return nil }
        return try await service.waveform(
            forEntryAt: entry.relativePath, audioFileName: audioFileName
        )
    }

    func trashPreview(for item: TrashItem) async -> TrashPreview? {
        await service?.trashPreview(for: item)
    }

    // MARK: - Intents (audio lifecycle, AUD-1)

    func audioFileByteSize(for entry: Entry) async -> Int64? {
        await service?.audioFileByteSize(atEntryPath: entry.relativePath)
    }

    /// Delete audio, keep transcript: the audio and waveform cache move to
    /// Recently Deleted (30-day recovery) and the entry becomes a plain note.
    func deleteAudio(for entry: Entry) async {
        // The player holds an open handle and would happily keep playing the
        // trashed file; a queued/running transcription reads it. Both must
        // let go before the move.
        if player.url == audioURL(for: entry) { player.unload() }
        transcriptionQueue?.evictItems(underPath: entry.relativePath)
        await perform("deleteAudio [\(entry.relativePath)]") { service in
            try await service.deleteAudio(atEntryPath: entry.relativePath)
        }
    }

    /// Trim to selection (AUD-3): the pre-trim audio is staged in Recently
    /// Deleted, the trimmed file becomes the entry's audio, and a
    /// retranscription is enqueued — word timings from the old audio are
    /// meaningless against the new file.
    func trimAudio(for entry: Entry, selection: TrimSelection) async {
        guard !clipMutationEntryPaths.contains(entry.relativePath) else { return }
        clipMutationEntryPaths.insert(entry.relativePath)
        defer { clipMutationEntryPaths.remove(entry.relativePath) }
        if player.url == audioURL(for: entry) { player.unload() }
        transcriptionQueue?.evictItems(underPath: entry.relativePath)
        await perform("trimAudio [\(entry.relativePath)]") { service in
            _ = try await service.trimAudio(atEntryPath: entry.relativePath, selection: selection)
            await MainActor.run {
                self.audioRevision &+= 1
                self.transcriptionQueue?.enqueue(
                    entryRelativePath: entry.relativePath,
                    source: "trim",
                    isRetranscribe: true
                )
            }
        }
    }

    /// Permanently removes long silent spans from the current timeline while
    /// retaining the complete pre-compression file in Recently Deleted.
    func compressAudio(for entry: Entry) async {
        guard !compressingEntryPaths.contains(entry.relativePath) else { return }
        do {
            try AudioCompressionPreflight.validate(
                mode: entry.silenceDetectionMode,
                speechAvailability: speechTranscriptAvailability(for: entry)
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        compressingEntryPaths.insert(entry.relativePath)
        defer { compressingEntryPaths.remove(entry.relativePath) }
        if player.url == audioURL(for: entry) { player.unload() }
        transcriptionQueue?.evictItems(underPath: entry.relativePath)
        await perform("compressAudio [\(entry.relativePath)]") { service in
            _ = try await service.compressAudio(atEntryPath: entry.relativePath)
            await MainActor.run {
                self.audioRevision &+= 1
                self.transcriptionQueue?.enqueue(
                    entryRelativePath: entry.relativePath,
                    source: "compress",
                    isRetranscribe: true
                )
            }
        }
    }

    /// Why version-backed clip undo/redo cannot safely run right now. This is
    /// intentionally entry-aware: changing one clip must not race its recorder,
    /// file swap, or transcript writer.
    func clipEditBlockReason(for entry: Entry) -> String? {
        guard entry.hasAudio else { return "This clip has no audio to undo or redo." }
        if recorder.isActive || recorder.state == .finalizing || recorder.sessionTarget != nil {
            return "Finish or cancel the active recording before undoing or redoing clip audio."
        }
        if trimModeActive {
            return "Finish or cancel trimming before undoing or redoing clip audio."
        }
        if replacementModeActive {
            return "Finish or cancel Replace Audio before undoing or redoing clip audio."
        }
        if compressingEntryPaths.contains(entry.relativePath)
            || clipMutationEntryPaths.contains(entry.relativePath) {
            return "Wait for the current audio operation to finish before undoing or redoing it."
        }
        if transcriptionBusyEntryPaths.contains(entry.relativePath) {
            return "Wait for this clip's transcription to finish before undoing or redoing its audio."
        }
        return nil
    }

    func performClipEdit(_ direction: ClipEditDirection, for entry: Entry) async {
        guard let service else { return }
        if let reason = clipEditBlockReason(for: entry) {
            errorMessage = reason
            return
        }
        let path = entry.relativePath
        clipMutationEntryPaths.insert(path)
        defer { clipMutationEntryPaths.remove(path) }
        if player.url == audioURL(for: entry) { player.unload() }
        do {
            guard let outcome = try await service.performClipEditSwap(
                entryPath: path, direction: direction
            ) else {
                // An empty undo/redo stack is normal command state, not an
                // error that should interrupt the user with an alert.
                return
            }
            audioRevision &+= 1
            transcriptionQueue?.enqueue(
                entryRelativePath: path,
                source: outcome.operation.transcriptionSource,
                isRetranscribe: true
            )
            await refresh { self.selectedEntryID = path }
            refreshVaultSearchIfVisible()
        } catch {
            errorMessage = "The clip could not be \(direction == .undo ? "undone" : "redone"): \(error.localizedDescription)"
            await refresh { self.selectedEntryID = path }
        }
    }

    // MARK: - Intents (speaker rename, TRN-6)

    /// Applies speaker renames (machine id → display name; nil/empty removes)
    /// and reloads the open transcript so the new labels render everywhere.
    func renameSpeakers(_ names: [String: String?], for entry: Entry) async {
        await perform("renameSpeakers [\(entry.relativePath)]") { service in
            try await service.saveSpeakerNames(names, atEntryPath: entry.relativePath)
            await MainActor.run { self.transcriptRevision += 1 }
        }
    }

    // MARK: - Intents (trash)

    func restoreTrashItem(_ item: TrashItem) async {
        if selectedTrashItemID == item.id { player.unload() }
        // Early compression/trim restoration builds labeled the displaced
        // version as ordinary entryAudio. Recognize those existing items so
        // they receive the same swap + retranscription behavior as the new
        // explicit audioVersion kind.
        let isLegacyAudioVersion = item.kind == .entryAudio
            && snapshot?.entry(withID: item.originalPath)?.hasAudio == true
            && snapshot?.entry(withID: item.originalPath)?.audioDeleted == false
        let restoresTimelineVersion = item.kind == .audioVersion
            || item.kind == .preTrimAudio || item.kind == .preExtensionAudio
            || item.kind == .preCompressionAudio || item.kind == .preReplacementAudio
            || isLegacyAudioVersion
        // An audio restore rearranges files the player or a running
        // transcription may hold open; both must let go first.
        if item.kind.isAudio, let vaultURL,
           player.url?.deletingLastPathComponent().path
               == vaultURL.appendingRelativePath(item.originalPath).path {
            player.unload()
        }
        if restoresTimelineVersion {
            transcriptionQueue?.evictItems(underPath: item.originalPath)
            clipMutationEntryPaths.insert(item.originalPath)
        }
        defer {
            if restoresTimelineVersion {
                clipMutationEntryPaths.remove(item.originalPath)
            }
        }
        await perform("restore [\(item.trashedName)]") { service in
            if restoresTimelineVersion {
                _ = try await service.restoreTimelineVersion(item)
            } else {
                _ = try await service.restore(item)
            }
            await MainActor.run {
                self.audioRevision &+= 1
                if restoresTimelineVersion {
                    // The transcript still matches the displaced trimmed
                    // audio; bring the text back in line with the disk.
                    self.recordingRecoveryNoticeMessage = item.kind == .preExtensionAudio
                        ? "Restored the selected audio version. The version that was active remains recoverable in Recently Deleted."
                        : (item.kind == .preReplacementAudio
                           ? "Restored the selected pre-replacement audio and its matching edit-history baseline. The displaced version remains recoverable in Recently Deleted."
                           : "Restored the selected audio. The version that was active remains recoverable in Recently Deleted.")
                    self.transcriptionQueue?.enqueue(
                        entryRelativePath: item.originalPath,
                        source: item.kind == .preTrimAudio
                            ? "trim-restore"
                            : (item.kind == .preExtensionAudio
                               ? "extension-restore"
                               : (item.kind == .preCompressionAudio
                                  ? "compression-restore"
                                  : (item.kind == .preReplacementAudio
                                     ? "replacement-restore" : "audio-version-restore"))),
                        isRetranscribe: true
                    )
                }
            }
        }
    }

    func deleteTrashItemPermanently(_ item: TrashItem) async {
        if selectedTrashItemID == item.id { player.unload() }
        await perform("deletePermanently [\(item.trashedName)]") { service in
            try await service.deletePermanently(item)
        }
    }

    /// Empties Recently Deleted in one pass (Voice Memos' "Delete All").
    /// The caller confirms first — this is the one unrecoverable bulk action.
    func emptyTrash() async {
        player.unload()
        await perform("emptyTrash") { service in
            _ = try await service.emptyTrash()
        }
    }

    // MARK: - Share (EXP-3, menu-bar entry point)

    /// The toolbar's More menu uses ShareLink, which needs a view anchor; a
    /// menu-bar item has none, so it goes through NSSharingServicePicker
    /// anchored to the key window's content view instead.
    func shareAudioFromMenu(for entry: Entry) {
        guard let audioURL = audioURL(for: entry),
              let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [audioURL])
        let anchor = NSRect(
            x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1
        )
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Intents (storage & vault settings, AUD-6/SET-2)

    /// Re-measures the vault for the Storage pane. The previous summary stays
    /// visible while the walk runs on the vault actor.
    func refreshStorageSummary() async {
        guard let service, !storageSummaryIsLoading else { return }
        storageSummaryIsLoading = true
        storageSummary = await service.storageSummary()
        storageSummaryIsLoading = false
    }

    /// Persists the Recently Deleted retention window to the vault's settings
    /// file. Items beyond the new window are purged on the next vault open,
    /// as the Settings copy states — never retroactively mid-session.
    func setTrashRetentionDays(_ days: Int) async {
        guard days != trashRetentionDays else { return }
        trashRetentionDays = days
        await perform("setTrashRetentionDays [\(days)]") { service in
            try await service.setTrashRetentionDays(days)
        }
    }

    // MARK: - Misc

    func revealInFinder(relativePath: RelativePath) {
        guard let vaultURL else { return }
        let url = vaultURL.appendingRelativePath(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealTrashItemInFinder(_ item: TrashItem) {
        guard let vaultURL else { return }
        let url = vaultURL
            .appending(path: TrashStore.directoryName)
            .appending(path: item.trashedName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Obsidian interop (EXP-2 adjacent)

    /// True when the open vault is also an Obsidian vault (has `.obsidian/`),
    /// which is what makes "Open in Obsidian" resolvable.
    var vaultHasObsidianConfig: Bool {
        guard let vaultURL else { return false }
        return ObsidianLink.isObsidianVault(vaultURL)
    }

    /// Opens this entry's transcript file in Obsidian via its URI scheme.
    func openInObsidian(entry: Entry) {
        guard let vaultURL,
              let fileURL = TranscriptFile.url(
                  inEntry: vaultURL.appendingRelativePath(entry.relativePath)
              ),
              let link = ObsidianLink.openURL(forPath: fileURL.path) else { return }
        NSWorkspace.shared.open(link)
    }

    func readTranscript(for entry: Entry) async -> FrontmatterDocument? {
        await service?.readTranscript(atEntryPath: entry.relativePath)
    }

    func readTranscriptContent(for entry: Entry) async -> EntryTranscriptContent? {
        await service?.readTranscriptContent(
            atEntryPath: entry.relativePath,
            duration: entry.duration
        )
    }

    /// Saves the editable markdown body without triggering a full vault scan
    /// on every keystroke. The editor debounces calls; the write itself is
    /// atomic and the service preserves frontmatter.
    func saveTranscriptBody(
        _ body: String,
        markHandEdited: Bool,
        clearHandEdited: Bool = false,
        for entry: Entry
    ) async -> FrontmatterDocument? {
        guard let service else { return nil }
        do {
            let saved = try await service.saveTranscriptBody(
                body,
                markHandEdited: markHandEdited,
                clearHandEdited: clearHandEdited,
                atEntryPath: entry.relativePath
            )
            scheduleTranscriptSaveRefresh()
            return saved
        } catch {
            errorMessage = "Could not save the transcript: \(error.localizedDescription)"
            return nil
        }
    }

    /// The editor autosaves every 600 ms. `refresh()` walks the whole vault
    /// tree and re-parses every trash sidecar, so paying it per save made
    /// continuous typing rescan the vault twice a second. The list preview
    /// still updates from the save — just coalesced to one rescan per burst.
    private func scheduleTranscriptSaveRefresh() {
        transcriptSaveRefreshTask?.cancel()
        transcriptSaveRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.transcriptSaveRefreshDelay))
            guard !Task.isCancelled else { return }
            // Clear before running so the refresh never cancels itself.
            self?.transcriptSaveRefreshTask = nil
            await self?.performTranscriptSaveRefresh()
        }
    }

    /// Runs the coalesced rescan now. Called when editing finishes, so leaving
    /// the editor never leaves a stale list row behind.
    func flushTranscriptSaveRefresh() async {
        transcriptSaveRefreshTask?.cancel()
        transcriptSaveRefreshTask = nil
        await performTranscriptSaveRefresh()
    }

    private func performTranscriptSaveRefresh() async {
        await refresh()
        refreshVaultSearchIfVisible()
    }

    // MARK: - Vocabulary (VOC-1)

    func vocabularyTerms() async -> [String] {
        await service?.vocabularyTerms() ?? []
    }

    /// Persists the vocabulary immediately (called per edit — the file is a
    /// handful of lines, so no debounce; skips the full `perform` refresh).
    func saveVocabularyTerms(_ terms: [String]) async {
        guard let service else { return }
        do {
            try await service.saveVocabularyTerms(terms)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Vocabulary re-apply (VOC-4)

    struct VocabularyReapplyScan: Sendable {
        var previews: [VocabularyReapply.EntryPreview]
        /// Entries excluded because they are queued or transcribing right now.
        var skippedBusyCount: Int
    }

    /// Dry run across the vault, minus entries the queue is about to rewrite
    /// anyway (their fresh transcription gets the new vocabulary at landing).
    func previewVocabularyReapply(terms: [String]) async -> VocabularyReapplyScan? {
        guard let service else { return nil }
        do {
            let previews = try await service.previewVocabularyReapply(terms: terms)
            let busy = transcriptionBusyEntryPaths
            let idle = previews.filter { !busy.contains($0.entryRelativePath) }
            return VocabularyReapplyScan(
                previews: idle, skippedBusyCount: previews.count - idle.count
            )
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func applyVocabularyReapply(
        terms: [String], toEntriesAt paths: [RelativePath]
    ) async -> VocabularyReapplyApplier.Summary? {
        guard let service else { return nil }
        // Re-check against the queue at apply time; the scan may be stale.
        let busy = transcriptionBusyEntryPaths
        let idlePaths = paths.filter { !busy.contains($0) }
        do {
            let summary = try await service.applyVocabularyReapply(
                terms: terms, toEntriesAt: idlePaths
            )
            if !summary.changedEntryPaths.isEmpty {
                transcriptRevision += 1 // reload any open workbench
                await refresh()
                refreshVaultSearchIfVisible()
            }
            return summary
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private var transcriptionBusyEntryPaths: Set<RelativePath> {
        Set(transcriptionQueue?.items.map(\.entryRelativePath) ?? [])
    }

    private func perform(_ label: String, _ work: (VaultService) async throws -> Void) async {
        guard let service else {
            DebugLog.append("\(label): NO SERVICE")
            return
        }
        do {
            try await work(service)
            DebugLog.append("\(label): ok")
        } catch {
            DebugLog.append("\(label): FAILED \(error)")
            errorMessage = error.localizedDescription
        }
        await refresh()
        refreshVaultSearchIfVisible()
    }
}
