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
        static let includeEntriesFromSubfolders = "includeEntriesFromSubfolders"
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
    let editorLifecycleCoordinator = EditorLifecycleCoordinator()

    private(set) var appShortcutPreferences = AppShortcutPreferencesStore.load()
    private(set) var globalShortcutPreferences = GlobalShortcutPreferencesStore.load()
    private(set) var editorPreferences = EditorPreferencesStore.load()
    private(set) var shortcutCaptureOwnsInput = false
    private(set) var editorInputOwnsInput = false
    private(set) var globalRecordingTransientState: GlobalRecordingPresentationState?
    private(set) var isGlobalIndicatorRetentionActive = false
    private(set) var isGlobalIndicatorManuallyPresented = false
    private var recordingCommandGate = RecordingCommandGate()
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
    /// Bumped only when FSEvents reports the mounted entry (or one of its
    /// descendants). EntryDetail keys off this instead of the vault-wide list
    /// revision so unrelated Obsidian/Finder writes cannot reset editor state.
    private(set) var selectedEntryExternalRevision = 0
    private(set) var lastExternalChangedPaths: Set<RelativePath> = []
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
    /// Library browsing preference. Any install without a saved choice —
    /// including existing installs upgrading to this build — aggregates
    /// descendants, because selecting a parent folder should expose the
    /// content organized below it; users who prefer strict one-folder views
    /// can turn this off in Settings.
    var includeEntriesFromSubfolders =
        UserDefaults.standard.object(forKey: PreferenceKey.includeEntriesFromSubfolders) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                includeEntriesFromSubfolders,
                forKey: PreferenceKey.includeEntriesFromSubfolders
            )
            // Turning the aggregation on only grows the visible set, so the
            // selection can only be orphaned when it turns off.
            if !includeEntriesFromSubfolders {
                Task { await clearEntrySelectionIfHidden() }
            }
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
        case editOrSave, copyAsMarkdown, toggleLayer, toggleSpeakerDetection,
             renameSpeakers, finishEditingForQuickMove
        case editorCommand(EditorCommandAction)
    }

    enum EditorCommandAction: String, Sendable {
        case find, replace, bold, italic, link, undo, redo
    }

    enum AppWindowRequest {
        case about, keyboardShortcuts
    }

    /// What the note workbench can do right now, mirrored up so menu items
    /// enable/disable and retitle truthfully (the state itself is view-local).
    struct WorkbenchUIState: Equatable {
        var hasContent = false
        var canEditNote = false
        var canSaveNote = false
        var isEditing = false
        var isForked = false
        var canToggleLayer = false
        var hasSpeakers = false
        var hasDetectedSpeakers = false
        var speakerDetectionEnabled = false
        var canToggleSpeakerDetection = false
        var viewedLayerIsOriginal = true
        var editorReady = false
        var editorInputOwnsInput = false
        var editorCanReplace = false
    }

    private(set) var entryActionRequest: EntryActionRequest?
    private(set) var entryActionRevision = 0
    private(set) var workbenchActionRequest: WorkbenchActionRequest?
    private(set) var workbenchActionRevision = 0
    private(set) var newFolderRequestRevision = 0
    private(set) var renameEntryRequestRevision = 0
    private(set) var queuePopoverRequestRevision = 0
    private(set) var appWindowRequest: AppWindowRequest?
    private(set) var appWindowRequestRevision = 0
    private(set) var quickMovePreparationEntryPath: RelativePath?
    private(set) var quickMovePreparationRevision = 0
    private(set) var quickMoveEntryPath: RelativePath?
    private(set) var isQuickMoveInFlight = false
    var isQuickMovePresented = false {
        didSet {
            if !isQuickMovePresented, !isQuickMoveInFlight {
                quickMoveEntryPath = nil
            }
        }
    }
    private(set) var cancelTrimRequestRevision = 0
    private(set) var trimModeActive = false
    var workbenchUIState = WorkbenchUIState()

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

    func setShortcutCaptureOwnsInput(_ ownsInput: Bool) {
        guard shortcutCaptureOwnsInput != ownsInput else { return }
        shortcutCaptureOwnsInput = ownsInput
        applyGlobalShortcutPreferencesForCurrentCaptureState()
    }

    func setEditorInputOwnsInput(_ ownsInput: Bool) {
        editorInputOwnsInput = ownsInput
    }

    func updateEditorPreferences(_ preferences: EditorPreferences) {
        var normalized = preferences
        normalized.normalize()
        guard normalized != editorPreferences else { return }
        editorPreferences = normalized
        EditorPreferencesStore.save(normalized)
    }

    func resetEditorPreferences() {
        updateEditorPreferences(EditorPreferences())
    }

    func completeQuickMovePreparation(for entryPath: RelativePath, saved: Bool) {
        guard quickMovePreparationEntryPath == entryPath else { return }
        quickMovePreparationEntryPath = nil
        guard saved,
              selectedEntryID == entryPath,
              quickMoveBlockedReason(for: entryPath) == nil else { return }
        quickMoveEntryPath = entryPath
        isQuickMovePresented = true
    }

    var quickMoveEntry: Entry? {
        guard let quickMoveEntryPath else { return nil }
        return snapshot?.entry(withID: quickMoveEntryPath)
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
        if recorder.currentEntryPath == entry.relativePath {
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
            Task { await clearEntrySelectionIfHidden() }
            if sidebarSelection != .recentlyDeleted, selectedTrashItemID != nil {
                selectedTrashItemID = nil
            }
        }
    }

    /// Clears the entry selection when the displayed list no longer contains
    /// it (the sidebar selection or a list-shaping preference changed).
    private func clearEntrySelectionIfHidden() async {
        guard let selectedEntryID,
              !displayedEntries.contains(where: { $0.id == selectedEntryID }) else { return }
        let intent = beginSelectionIntent()
        guard await editorLifecycleCoordinator.prepare(for: .entryChange(nil)),
              selectionIntentIsCurrent(intent),
              self.selectedEntryID == selectedEntryID,
              !displayedEntries.contains(where: { $0.id == selectedEntryID }) else { return }
        self.selectedEntryID = nil
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

    private var selectionIntentGeneration: UInt64 = 0

    private func beginSelectionIntent() -> UInt64 {
        selectionIntentGeneration &+= 1
        return selectionIntentGeneration
    }

    private func selectionIntentIsCurrent(_ generation: UInt64) -> Bool {
        generation == selectionIntentGeneration
    }

    @discardableResult
    private func refreshSelectingEntry(_ destination: RelativePath?) async -> Bool {
        let intent = beginSelectionIntent()
        guard await prepareSelectionIntent(intent, destination: destination) else { return false }
        await refresh {
            guard self.selectionIntentIsCurrent(intent) else { return }
            self.selectedEntryID = destination
        }
        return selectionIntentIsCurrent(intent) && selectedEntryID == destination
    }

    @discardableResult
    private func prepareSelectionIntent(
        _ generation: UInt64,
        destination: RelativePath?
    ) async -> Bool {
        guard await editorLifecycleCoordinator.prepare(
            for: .entryChange(destination)
        ) else { return false }
        return selectionIntentIsCurrent(generation)
    }

    /// User-driven selection changes wait for the mounted web editor's
    /// acknowledged snapshot. Internal path remapping may still assign the
    /// property directly because it does not change the logical document.
    func requestEntrySelection(_ entryID: String?) {
        guard entryID != selectedEntryID else { return }
        let intent = beginSelectionIntent()
        Task {
            guard await prepareSelectionIntent(intent, destination: entryID) else { return }
            selectedEntryID = entryID
        }
    }

    func requestSidebarSelection(_ selection: SidebarSelection?) {
        guard selection != sidebarSelection else { return }
        let intent = beginSelectionIntent()
        Task {
            guard await prepareSelectionIntent(intent, destination: nil) else { return }
            sidebarSelection = selection
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
#if DEBUG
    var serviceForTesting: VaultService? { service }
#endif
    private var watcher: FSEventsWatcher?
    private var searchIndexTask: Task<Void, Never>?
    private var vaultSearchTask: Task<Void, Never>?
    /// Whole-vault replacement is a destructive context switch. Keep every
    /// request on one tail so an older B open can never finish after a newer
    /// C request and republish B's service, watcher, or selection.
    private var vaultOpenTail: Task<Void, Never>?
    private var vaultOpenIntentGeneration: UInt64 = 0
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
            let entries = includeEntriesFromSubfolders
                ? selectedFolder?.allEntries ?? []
                : selectedFolder?.entries ?? []
            return entrySortOrder.sorted(
                entries,
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
            guard let self, !self.shortcutCaptureOwnsInput else { return }
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
        applyGlobalShortcutPreferencesForCurrentCaptureState()
    }

    /// Carbon hotkeys consume their key event before a focused capture view
    /// can record it. Temporarily unregister them while either app-local or
    /// global capture owns input, without mutating the persisted preference
    /// profile. Releasing capture immediately restores that same profile.
    private func applyGlobalShortcutPreferencesForCurrentCaptureState() {
        var appliedPreferences = globalShortcutPreferences
        if shortcutCaptureOwnsInput { appliedPreferences.isEnabled = false }
        globalShortcutService.apply(appliedPreferences)
    }

    var assignedGlobalShortcutBindings: [ShortcutChord: String] {
        var result: [ShortcutChord: String] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let chord = globalShortcutPreferences.bindings[action] ?? nil else { continue }
            // A persisted global/global collision is still global-owned. Keep
            // the first stable action title and disable every matching local
            // assignment rather than guessing which command the user meant.
            if result[chord] == nil { result[chord] = action.title }
        }
        return result
    }

    func updateAppShortcutPreferences(_ preferences: AppShortcutPreferences) {
        appShortcutPreferences = preferences
        AppShortcutPreferencesStore.save(preferences)
    }

    func resetAppShortcutPreferences() {
        updateAppShortcutPreferences(.defaults)
    }

    func updateGlobalShortcutPreferences(_ preferences: GlobalShortcutPreferences) {
        let retentionChanged = preferences.backgroundIndicatorRetention !=
            globalShortcutPreferences.backgroundIndicatorRetention
        globalShortcutPreferences = preferences
        GlobalShortcutPreferencesStore.save(preferences)
        applyGlobalShortcutPreferencesForCurrentCaptureState()
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
        isGlobalIndicatorManuallyPresented = false
        globalShortcutService.shutdown()
    }

    /// Opens `url` as the vault, replacing any current vault.
    func openVault(at url: URL, isSecurityScoped: Bool, saveBookmark: Bool) async {
        vaultOpenIntentGeneration &+= 1
        let intent = vaultOpenIntentGeneration
        let predecessor = vaultOpenTail
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self, self.vaultOpenIntentGeneration == intent else { return }
            await self.performOpenVault(
                at: url,
                isSecurityScoped: isSecurityScoped,
                saveBookmark: saveBookmark
            )
        }
        vaultOpenTail = Task { await operation.value }
        await operation.value
    }

    private func performOpenVault(
        at url: URL,
        isSecurityScoped: Bool,
        saveBookmark: Bool
    ) async {
        guard await editorLifecycleCoordinator.prepare(for: .vaultChange) else {
            errorMessage = "The current note could not be saved, so the vault was not changed."
            return
        }
        if replacementModeActive {
            // Finish the old vault's temporary transaction against the old
            // VaultService before replacing it below.
            await cancelReplacement()
        } else if recorder.isActive {
            stopLiveTranscription()
            _ = await recorder.stop() // finalize into the old vault first
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
        queue.beforeEntryMutation = { [weak self] entryPath in
            guard let self, self.selectedEntryID == entryPath else { return true }
            return await self.editorLifecycleCoordinator.prepare(for: .externalReload)
        }
        queue.onEntryTranscribed = { [weak self] originalPath, outcome in
            self?.entryTranscribed(originalPath: originalPath, outcome: outcome)
        }
        transcriptionQueue = queue
        TranscriptionSeam.queue = queue

        let recordingRecovery = await service.recoverInterruptedRecordings()
        for outcome in recordingRecovery.recovered {
            queue.enqueue(
                entryRelativePath: outcome.entryRelativePath,
                source: "recording-recovery"
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

        let extensionDiscovery = await service.recordingExtensionRecoveries()
        extensionRecoveries = []
        for recovery in extensionDiscovery.recoverable {
            if recovery.phase == .swapNeedsCleanup {
                do {
                    _ = try await service.finishRecoveredExtension(recovery)
                    queueExtensionRetranscription(
                        entryRelativePath: recovery.entryRelativePath,
                        source: "extension-recovery"
                    )
                    audioRevision &+= 1
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
                await self?.handleExternalVaultChange(for: service, absolutePaths: paths)
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
        for changedService: VaultService,
        absolutePaths: [String]
    ) async {
        guard service === changedService else { return }
        let changedPaths = relativeChangedPaths(from: absolutePaths)
        lastExternalChangedPaths = changedPaths
        externalVaultRevision &+= 1
        if let selectedEntryID,
           changedPaths.contains(where: { pathsOverlap($0, selectedEntryID) }) {
            selectedEntryExternalRevision &+= 1
        }
        await refresh()
        refreshVaultSearchIfVisible()
    }

    private func relativeChangedPaths(from absolutePaths: [String]) -> Set<RelativePath> {
        guard let root = vaultURL?.standardizedFileURL.path else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return Set(absolutePaths.compactMap { raw in
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if path == root { return "" }
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        })
    }

#if DEBUG
    func handleExternalVaultChangeForTesting(
        service changedService: VaultService,
        absolutePaths: [String]
    ) async {
        await handleExternalVaultChange(
            for: changedService,
            absolutePaths: absolutePaths
        )
    }
#endif

    private func pathsOverlap(_ lhs: RelativePath, _ rhs: RelativePath) -> Bool {
        lhs.isEmpty || rhs.isEmpty || lhs == rhs
            || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func remappedDescendant(
        _ candidate: RelativePath,
        from oldRoot: RelativePath,
        to newRoot: RelativePath
    ) -> RelativePath? {
        if candidate == oldRoot { return newRoot }
        guard candidate.hasPrefix(oldRoot + "/") else { return nil }
        return newRoot + candidate.dropFirst(oldRoot.count)
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
        if let selectedEntryID,
           snap.entry(withID: selectedEntryID) == nil {
            let intent = beginSelectionIntent()
            guard await prepareSelectionIntent(intent, destination: nil),
                  self.selectedEntryID == selectedEntryID else { return }
        }
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

    // MARK: - Intents (folders)

    func createFolder(named name: String, inFolder parent: RelativePath) async {
        await perform("createFolder \(name) in [\(parent)]") { service in
            _ = try await service.createFolder(named: name, inFolder: parent)
        }
    }

    func renameFolder(at relPath: RelativePath, to newName: String) async {
        guard let service else { return }
        let selectedBefore = selectedEntryID
        if let selectedBefore, pathsOverlap(relPath, selectedBefore) {
            guard await editorLifecycleCoordinator.prepare(for: .externalReload) else { return }
        }
        do {
            let newPath = try await service.renameFolder(at: relPath, to: newName)
            let selectedAfter = selectedBefore.flatMap {
                remappedDescendant($0, from: relPath, to: newPath)
            }
            if let selectedBefore, let selectedAfter {
                guard !editorLifecycleCoordinator.hasActiveParticipant
                    || editorLifecycleCoordinator.remapActiveDocument(
                        expectedOldPath: selectedBefore,
                        to: selectedAfter
                    ) else {
                    errorMessage = "The folder was renamed, but the open editor could not be rebound safely. Reopen the note before editing."
                    return
                }
            }
            await refresh {
                if case .folder(let selectedFolder)? = self.sidebarSelection,
                   let remapped = self.remappedDescendant(
                    selectedFolder, from: relPath, to: newPath
                   ) {
                    self.sidebarSelection = .folder(remapped)
                }
                if let selectedAfter { self.selectedEntryID = selectedAfter }
            }
            DebugLog.append("renameFolder [\(relPath)] -> [\(newPath)]: ok")
        } catch {
            DebugLog.append("renameFolder [\(relPath)]: FAILED \(error)")
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    // MARK: - Intents (entries)

    func renameEntry(_ entry: Entry, toTitle title: String) async {
        guard recorder.currentEntryPath != entry.relativePath else { return }
        if selectedEntryID == entry.relativePath {
            guard await editorLifecycleCoordinator.prepare(for: .externalReload) else { return }
        }
        await perform("renameEntry [\(entry.relativePath)] -> \(title)") { service in
            let newPath = try await service.renameEntry(at: entry.relativePath, toTitle: title)
            await MainActor.run {
                self.transcriptionQueue?.repointItems(from: entry.relativePath, to: newPath)
                if self.selectedEntryID == entry.relativePath {
                    guard !self.editorLifecycleCoordinator.hasActiveParticipant
                        || self.editorLifecycleCoordinator.remapActiveDocument(
                            expectedOldPath: entry.relativePath,
                            to: newPath
                        ) else {
                        self.errorMessage = "The note was renamed, but the open editor could not be rebound safely. Reopen it before editing."
                        return
                    }
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func moveItem(atRelativePath relPath: RelativePath, toFolder destFolder: RelativePath) async {
        let result = await moveEntry(
            atRelativePath: relPath,
            toFolder: destFolder,
            enforceQuickMoveAvailability: false
        )
        if case .failure(let failure) = result {
            errorMessage = failure.localizedDescription
        }
    }

    /// Shared move intent for Quick Move, context-menu Move To, and drag/drop.
    /// The refreshed snapshot, queue repoint, and selection update are
    /// published in one main-actor turn so the selected detail never briefly
    /// points at a path that is absent from the snapshot.
    func moveEntry(
        atRelativePath relPath: RelativePath,
        toFolder destFolder: RelativePath
    ) async -> QuickMoveResult {
        await moveEntry(
            atRelativePath: relPath,
            toFolder: destFolder,
            enforceQuickMoveAvailability: true
        )
    }

    private func moveEntry(
        atRelativePath relPath: RelativePath,
        toFolder destFolder: RelativePath,
        enforceQuickMoveAvailability: Bool
    ) async -> QuickMoveResult {
        let selectedBefore = selectedEntryID
        if let selectedBefore, pathsOverlap(relPath, selectedBefore) {
            guard await editorLifecycleCoordinator.prepare(for: .externalReload) else {
                return .failure(.unavailable("The current note could not be saved."))
            }
        }
        if isQuickMoveInFlight {
            return .failure(.unavailable("Wait for the current move to finish."))
        }
        if enforceQuickMoveAvailability,
           let reason = quickMoveBlockedReason(for: relPath) {
            return .failure(.unavailable(reason))
        }
        guard let service else {
            return .failure(.unavailable("Open a vault before moving a note."))
        }

        isQuickMoveInFlight = true
        defer { isQuickMoveInFlight = false }

        do {
            let newPath = try await service.moveItem(at: relPath, toFolder: destFolder)
            let selectedAfter = selectedBefore.flatMap {
                remappedDescendant($0, from: relPath, to: newPath)
            }
            if let selectedBefore, let selectedAfter,
               editorLifecycleCoordinator.hasActiveParticipant {
                guard editorLifecycleCoordinator.remapActiveDocument(
                    expectedOldPath: selectedBefore,
                    to: selectedAfter
                ) else {
                    throw VaultError.notFound("The open editor could not be rebound after moving the note.")
                }
            }
            await refresh {
                self.transcriptionQueue?.repointItems(from: relPath, to: newPath)
                if let selectedAfter { self.selectedEntryID = selectedAfter }
                if self.quickMoveEntryPath == relPath {
                    self.quickMoveEntryPath = newPath
                }
            }
            refreshVaultSearchIfVisible()
            DebugLog.append("moveItem [\(relPath)] -> [\(destFolder)]: ok")
            return .success(
                QuickMoveSuccess(
                    sourcePath: relPath,
                    destinationFolder: destFolder,
                    movedPath: newPath
                )
            )
        } catch {
            DebugLog.append("moveItem [\(relPath)] -> [\(destFolder)]: FAILED \(error)")
            return .failure(
                .classify(
                    error,
                    sourcePath: relPath,
                    destinationFolder: destFolder
                )
            )
        }
    }

    func deleteItem(atRelativePath relPath: RelativePath) async {
        guard recorder.currentEntryPath != relPath else { return }
        let deletingSelectedDocument = selectedEntryID.map {
            pathsOverlap(relPath, $0)
        } ?? false
        let selectionIntent = deletingSelectedDocument ? beginSelectionIntent() : nil
        if let selectionIntent {
            guard await prepareSelectionIntent(selectionIntent, destination: nil) else { return }
        }
        // Standard list semantics: deleting the selected entry selects the
        // one that takes its place (the next below, else the new last).
        // Computed from the displayed order before the row disappears.
        var successorID: String?
        let entries = displayedEntries
        if deletingSelectedDocument,
           selectedEntryID != nil,
           let index = entries.firstIndex(where: { $0.id == relPath }) {
            successorID = index + 1 < entries.count
                ? entries[index + 1].id
                : (index > 0 ? entries[index - 1].id : nil)
        }
        await perform("deleteItem [\(relPath)]") { service in
            try await service.trashItem(atRelativePath: relPath)
            await MainActor.run {
                self.transcriptionQueue?.evictItems(underPath: relPath)
                if let selected = self.selectedEntryID,
                   self.pathsOverlap(relPath, selected) { self.selectedEntryID = nil }
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(relPath.parentRelativePath)
                }
            }
        }
        // Only after the refresh confirmed the delete (entry gone, successor
        // still present) — a failed trash keeps the original selection.
        if let successorID, selectedEntryID == nil,
           selectionIntent.map(selectionIntentIsCurrent) ?? true,
           snapshot?.entry(withID: relPath) == nil,
           snapshot?.entry(withID: successorID) != nil {
            selectedEntryID = successorID
        }
    }

    func toggleFavorite(for entry: Entry) async {
        guard recorder.currentEntryPath != entry.relativePath else { return }
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

    /// Shared by the visible Compress control, its menu item, and remapped
    /// keyboard dispatch so all three report the same availability.
    func compressionBlockedReason(for entry: Entry) -> String? {
        if trimModeActive {
            return "Finish or cancel trimming before compressing audio."
        }
        if let reason = trimBlockedReason(for: entry, duration: entry.duration) {
            return reason
        }
        if entry.silenceDetectionMode == .speech {
            return speechTranscriptAvailability(for: entry).explanation
        }
        return nil
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
        guard recorder.currentEntryPath != entry.relativePath else { return }
        guard let service else { return }
        let intent = beginSelectionIntent()
        guard await prepareSelectionIntent(intent, destination: nil) else { return }
        do {
            let newPath = try await service.duplicateEntry(at: entry.relativePath)
            DebugLog.append("duplicateEntry [\(entry.relativePath)] -> [\(newPath)]")
            await refresh {
                if self.selectionIntentIsCurrent(intent) { self.selectedEntryID = newPath }
            }
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
        let intent = beginSelectionIntent()
        Task {
            guard await prepareSelectionIntent(intent, destination: hit.entryPath) else { return }
            player.pause()
            sidebarSelection = .folder(hit.entryPath.parentRelativePath)
            selectedEntryID = hit.entryPath
            // Title/metadata hits select the entry itself; only content
            // ranges belong to a transcript layer and drive text/audio cueing.
            transcriptNavigationRequest = hit.matchKind == .content
                ? TranscriptNavigationRequest(hit: hit)
                : nil
            isVaultSearchPresented = false
        }
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
            if vaultSearchFilters.selectedTags.isEmpty {
                vaultSearchResults = []
            } else {
                vaultSearchResults = metadataSearchHits(
                    matching: vaultSearchFilters
                )
            }
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
        guard isVaultSearchPresented,
              !vaultSearchQuery.isEmpty || !vaultSearchFilters.selectedTags.isEmpty
        else { return }
        scheduleVaultSearch(immediate: true)
    }

    private func metadataSearchHits(
        matching filters: VaultSearchFilters
    ) -> [SearchHit] {
        guard let snapshot else { return [] }
        return snapshot.allEntries
            .filter { filters.matches($0) }
            .sorted {
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.relativePath.localizedStandardCompare($1.relativePath)
                    == .orderedAscending
            }
            .prefix(VaultSearchFilters.displayedResultLimit)
            .map { entry in
                let matchingTags = entry.tags.filter {
                    EditorTagExtractor.matchesAny(
                        entryTags: [$0],
                        selectedTags: filters.selectedTags
                    )
                }
                return SearchHit(
                    entryPath: entry.relativePath,
                    layer: .edited,
                    title: entry.displayTitle,
                    snippet: matchingTags.map { "#\($0.display)" }.joined(separator: "  "),
                    matchKind: .metadata,
                    matchRange: 0..<0,
                    snippetMatchRange: 0..<0,
                    score: 0
                )
            }
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

    // MARK: - App command catalog and dispatch

    func quickMoveBlockedReason(for entryPath: RelativePath) -> String? {
        guard phase == .ready,
              let entry = snapshot?.entry(withID: entryPath) else {
            return "Select a note before moving it."
        }
        if isQuickMoveInFlight { return "Wait for the current move to finish." }
        if recorder.state != .idle || recorder.sessionTarget != nil {
            return "Finish or cancel the active recording before moving this note."
        }
        if trimModeActive { return "Finish or cancel trimming before moving this note." }
        if replacementModeActive {
            return "Finish or cancel Replace Audio before moving this note."
        }
        if compressingEntryPaths.contains(entryPath)
            || clipMutationEntryPaths.contains(entryPath) {
            return "Wait for the current audio operation to finish before moving this note."
        }
        if transcriptionQueue?.items.contains(where: {
            $0.entryRelativePath == entryPath && $0.state != .failed
        }) == true {
            return "Wait for this note's transcription to finish before moving it."
        }
        let hasDestination = snapshot?.root.allFolders.contains {
            $0.relativePath != entry.parentRelativePath
        } == true
        if !hasDestination { return "Create another vault folder before moving this note." }
        return nil
    }

    func requestQuickMove() {
        guard let entry = selectedEntry else { return }
        if let reason = quickMoveBlockedReason(for: entry.relativePath) {
            errorMessage = reason
            return
        }
        quickMovePreparationEntryPath = entry.relativePath
        quickMovePreparationRevision &+= 1
        if workbenchUIState.isEditing {
            requestWorkbenchAction(.finishEditingForQuickMove)
        } else {
            completeQuickMovePreparation(for: entry.relativePath, saved: true)
        }
    }

    private func requestAppWindow(_ request: AppWindowRequest) {
        appWindowRequest = request
        appWindowRequestRevision &+= 1
        switch request {
        case .about:
            AppWindowPresenter.openAuxiliaryWindow(id: AboutCommands.windowID)
        case .keyboardShortcuts:
            AppWindowPresenter.openAuxiliaryWindow(
                id: KeyboardShortcutsCommands.windowID
            )
        }
    }

    func isAppCommandEnabled(_ action: AppShortcutAction) -> Bool {
        if action == .showAbout || action == .showKeyboardShortcuts { return true }
        guard phase == .ready else { return false }

        switch action {
        case .newRecording:
            return recorder.state == .idle && recorder.sessionTarget == nil
        case .toggleRecording:
            return recorder.state != .finalizing
        case .togglePausePlayback:
            switch recorder.state {
            case .recording:
                if case .replacementTake? = recorder.sessionTarget { return false }
                return true
            case .paused: return true
            case .idle: return player.url != nil
            case .finalizing: return false
            }
        case .importAudio, .newFolder, .searchVault,
             .sortByDate, .sortByDuration, .sortByTitle, .sortByRecentlyEdited,
             .goToVaultRoot, .goToFavorites, .goToRecentlyDeleted,
             .showTranscriptionQueue:
            return true

        case .toggleFavorite, .renameEntry, .duplicateEntry, .showInfo,
             .revealInFinder:
            return selectedEntry != nil
        case .moveNote:
            guard let entry = selectedEntry else { return false }
            return !isQuickMovePresented
                && quickMovePreparationEntryPath == nil
                && quickMoveBlockedReason(for: entry.relativePath) == nil
        case .moveToRecentlyDeleted:
            guard let entry = selectedEntry else { return false }
            return recorder.currentEntryPath != entry.relativePath
                && !trimModeActive && !replacementModeActive
                && !compressingEntryPaths.contains(entry.relativePath)
                && !clipMutationEntryPaths.contains(entry.relativePath)
        case .extendRecording:
            if recorder.extensionSession != nil {
                return recorder.state == .recording || recorder.state == .paused
            }
            return selectedEntry.map { extensionBlockReason(for: $0) == nil } ?? false
        case .editOrSaveNote:
            return workbenchUIState.isEditing
                ? workbenchUIState.canSaveNote
                : workbenchUIState.canEditNote
        case .copyMarkdown:
            return workbenchUIState.hasContent
        case .toggleTranscriptLayer:
            return workbenchUIState.canToggleLayer && !workbenchUIState.isEditing
        case .retranscribe:
            return selectedEntry?.hasAudio == true && !replacementModeActive
        case .trimAudio:
            if trimModeActive { return true }
            return selectedEntry.map {
                trimBlockedReason(for: $0, duration: $0.duration) == nil
            } ?? false
        case .replaceAudio:
            return selectedEntry.map { replacementBlockedReason(for: $0) == nil } ?? false
        case .compressAudio:
            return selectedEntry.map { compressionBlockedReason(for: $0) == nil }
                ?? false
        case .restoreOriginalAudio:
            return selectedEntry.map { originalAudioTrashItem(for: $0) != nil } ?? false
        case .toggleSpeakerDetection:
            return workbenchUIState.canToggleSpeakerDetection
        case .renameSpeakers:
            return workbenchUIState.hasSpeakers && !workbenchUIState.isEditing
        case .deleteAudio:
            guard let entry = selectedEntry else { return false }
            return entry.hasAudio
                && recorder.currentEntryPath != entry.relativePath
                && !compressingEntryPaths.contains(entry.relativePath)
                && !clipMutationEntryPaths.contains(entry.relativePath)
                && !replacementModeActive && !trimModeActive
        case .exportMarkdown:
            return selectedEntry?.hasTranscript == true
        case .shareAudio:
            return selectedEntry?.hasAudio == true
        case .openInObsidian:
            return vaultHasObsidianConfig && selectedEntry?.hasTranscript == true

        case .undoClipEdit, .redoClipEdit:
            if editorInputOwnsInput { return workbenchUIState.editorReady }
            return selectedEntry.map { clipEditBlockReason(for: $0) == nil } ?? false
        case .skipBackward, .skipForward,
             .jump0, .jump1, .jump2, .jump3, .jump4,
             .jump5, .jump6, .jump7, .jump8, .jump9,
             .decreasePlaybackSpeed, .increasePlaybackSpeed,
             .resetPlaybackSpeed:
            return player.url != nil
        case .toggleSkipSilence:
            return true
        case .enterZenMode:
            if case .replacementTake? = recorder.sessionTarget { return false }
            return !recorder.isZenMode
        case .findInNote:
            return selectedEntry != nil && !isVaultSearchPresented
        case .previousFolder, .nextFolder:
            return snapshot != nil
        case .showAbout, .showKeyboardShortcuts:
            return true
        }
    }

    func performAppCommand(_ action: AppShortcutAction) {
        guard isAppCommandEnabled(action) else {
            if action == .moveNote, let entry = selectedEntry {
                errorMessage = quickMoveBlockedReason(for: entry.relativePath)
            } else if (action == .undoClipEdit || action == .redoClipEdit),
                      let entry = selectedEntry {
                errorMessage = clipEditBlockReason(for: entry)
            }
            return
        }

        switch action {
        case .newRecording:
            Task { await startRecording() }
        case .toggleRecording:
            Task {
                await performRecordingCommand(
                    recorder.state == .idle ? .startNew : .stopAndSave
                )
            }
        case .togglePausePlayback:
            switch recorder.state {
            case .recording, .paused: Task { await toggleRecordingPause() }
            case .idle: player.togglePlayPause()
            case .finalizing: break
            }
        case .importAudio: importViaPanel()
        case .newFolder: requestNewFolder()
        case .toggleFavorite:
            if let entry = selectedEntry { Task { await toggleFavorite(for: entry) } }
        case .renameEntry: requestRenameEntry()
        case .duplicateEntry:
            if let entry = selectedEntry { Task { await duplicateEntry(entry) } }
        case .moveNote: requestQuickMove()
        case .moveToRecentlyDeleted:
            if let entry = selectedEntry {
                Task { await deleteItem(atRelativePath: entry.relativePath) }
            }
        case .extendRecording:
            if recorder.extensionSession != nil {
                if recorder.state == .recording || recorder.state == .paused {
                    Task { await stopRecording() }
                }
            } else {
                requestEntryAction(.extendRecording)
            }
        case .editOrSaveNote: requestWorkbenchAction(.editOrSave)
        case .copyMarkdown: requestWorkbenchAction(.copyAsMarkdown)
        case .toggleTranscriptLayer: requestWorkbenchAction(.toggleLayer)
        case .retranscribe: requestEntryAction(.retranscribe)
        case .trimAudio: toggleTrimFromShortcut()
        case .replaceAudio:
            if let entry = selectedEntry { beginReplacement(for: entry) }
        case .compressAudio: requestEntryAction(.compress)
        case .restoreOriginalAudio: requestEntryAction(.restoreOriginalAudio)
        case .toggleSpeakerDetection: requestWorkbenchAction(.toggleSpeakerDetection)
        case .renameSpeakers: requestWorkbenchAction(.renameSpeakers)
        case .deleteAudio: requestEntryAction(.deleteAudio)
        case .showInfo: requestEntryAction(.showInfo)
        case .revealInFinder:
            if let entry = selectedEntry { revealInFinder(relativePath: entry.relativePath) }
        case .exportMarkdown: requestEntryAction(.exportMarkdown)
        case .shareAudio:
            if let entry = selectedEntry { shareAudioFromMenu(for: entry) }
        case .openInObsidian:
            if let entry = selectedEntry { openInObsidian(entry: entry) }
        case .undoClipEdit, .redoClipEdit:
            if editorInputOwnsInput {
                requestWorkbenchAction(.editorCommand(
                    action == .undoClipEdit ? .undo : .redo
                ))
            } else if let entry = selectedEntry {
                Task {
                    await performClipEdit(
                        action == .undoClipEdit ? .undo : .redo,
                        for: entry
                    )
                }
            }
        case .skipBackward: player.skipBackward()
        case .skipForward: player.skipForward()
        case .jump0, .jump1, .jump2, .jump3, .jump4,
             .jump5, .jump6, .jump7, .jump8, .jump9:
            if let fraction = action.playbackFraction { player.seek(toFraction: fraction) }
        case .decreasePlaybackSpeed: player.stepSpeed(-1)
        case .increasePlaybackSpeed: player.stepSpeed(1)
        case .resetPlaybackSpeed: player.speed = 1
        case .toggleSkipSilence: player.skipSilence.toggle()
        case .enterZenMode: recorder.isZenMode = true
        case .findInNote: requestInNoteFind()
        case .searchVault: presentVaultSearch()
        case .previousFolder: _ = moveSidebarSelection(by: -1)
        case .nextFolder: _ = moveSidebarSelection(by: 1)
        case .sortByDate: selectEntrySortOrder(.dateNewest)
        case .sortByDuration: selectEntrySortOrder(.duration)
        case .sortByTitle: selectEntrySortOrder(.title)
        case .sortByRecentlyEdited: selectEntrySortOrder(.recentlyEdited)
        case .goToVaultRoot: requestSidebarSelection(.folder(""))
        case .goToFavorites: requestSidebarSelection(.favorites)
        case .goToRecentlyDeleted: requestSidebarSelection(.recentlyDeleted)
        case .showTranscriptionQueue: requestQueuePopover()
        case .showAbout: requestAppWindow(.about)
        case .showKeyboardShortcuts: requestAppWindow(.keyboardShortcuts)
        }
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

    /// Matches every configurable local binding before the responder chain.
    /// Unassigned/reserved/conflicting bindings never reach the dispatcher;
    /// bare keys and focus-sensitive commands defer to editable text.
    private func handleKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard !shortcutCaptureOwnsInput else { return false }

        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let focusedTextView = NSApp.keyWindow?.firstResponder as? NSTextView
        let editingTextView = focusedTextView?.isEditable == true ? focusedTextView : nil
        let editorOwnsText = editingTextView != nil || editorInputOwnsInput

        // Escape remains structural and fixed. Give sheets, panels, windows,
        // and editors first refusal before the workflow-level fallback.
        if keyCode == escapeKeyCode, modifiers.isEmpty {
            guard !editorOwnsText, !foregroundPresentationOwnsEscape else {
                return false
            }
            return handleExitCommand()
        }

        if let action = appShortcutAction(
            forKeyCode: keyCode,
            modifiers: modifiers,
            editableTextHasFocus: editorOwnsText
        ) {
            performAppCommand(action)
            return true
        }

        // Plain Up/Down remain native list navigation. When the middle split
        // column is collapsed its List responder is absent, so preserve the
        // existing equivalent selection fallback without making it remappable.
        if (keyCode == upArrowKeyCode || keyCode == downArrowKeyCode),
           modifiers.isEmpty, !editorOwnsText, middleColumnIsCollapsed {
            return moveMiddleSelection(by: keyCode == downArrowKeyCode ? 1 : -1)
        }
        return false
    }

    /// Testable edge of the app-local monitor. Preferences are read live on
    /// every event, so remapping, clearing, conflict changes, and capture
    /// ownership take effect without reinstalling the monitor or relaunching.
    func appShortcutAction(
        forKeyCode keyCode: UInt16,
        modifiers: ShortcutModifiers,
        editableTextHasFocus: Bool
    ) -> AppShortcutAction? {
        AppShortcutMatcher.action(
            forKeyCode: keyCode,
            modifiers: modifiers,
            preferences: appShortcutPreferences,
            globalBindings: assignedGlobalShortcutBindings,
            editableTextHasFocus: editableTextHasFocus,
            captureOwnsInput: shortcutCaptureOwnsInput
        )
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
        requestSidebarSelection(destinations[nextIndex])
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
            requestEntrySelection(nextID)
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

    func showGlobalIndicatorManually() {
        isGlobalIndicatorManuallyPresented = true
    }

    func dismissGlobalIndicatorManually() {
        isGlobalIndicatorManuallyPresented = false
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
        defer { recordingCommandGate.finish(command) }

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
                    duration: finalDuration,
                    until: .now.addingTimeInterval(2.5)
                ))
            }
        }
    }

    private func recordingCommandAvailabilityState(
        for command: RecordingCommand
    ) -> RecordingCommandAvailabilityState {
        switch recorder.state {
        case .recording: return .recording
        case .paused: return .paused
        case .finalizing: return .finalizing
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

    /// A manually presented indicator stays meaningful when global hotkeys
    /// are disabled, so manual presentation drops the registered-shortcut
    /// requirement.
    var globalIndicatorPresentationState: GlobalRecordingPresentationState {
        recordingPresentationState(
            requiresRegisteredShortcut: !isGlobalIndicatorManuallyPresented
        )
    }

    private func recordingPresentationState(
        requiresRegisteredShortcut: Bool
    ) -> GlobalRecordingPresentationState {
        if let globalRecordingTransientState { return globalRecordingTransientState }
        let toggle = (globalShortcutPreferences.bindings[.toggleRecording] ?? nil)?.glyphDescription ?? ""
        let pause = (globalShortcutPreferences.bindings[.pauseResumeRecording] ?? nil)?.glyphDescription ?? ""
        switch recorder.state {
        case .recording:
            return .recording(elapsed: recorder.elapsed, pauseShortcut: pause, stopShortcut: toggle)
        case .paused:
            return .paused(elapsed: recorder.elapsed, pauseShortcut: pause, stopShortcut: toggle)
        case .finalizing:
            return .saving(elapsed: recorder.elapsed)
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
        guard await RecorderService.ensureMicPermission() else {
            errorMessage = """
            Transcride needs microphone access to record. \
            Enable it in System Settings → Privacy & Security → Microphone, then try again.
            """
            globalRecordingTransientState = .needsAttention(errorMessage ?? "Microphone access is required.")
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let quality = RecordingQuality(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
        ) ?? .compressed
        let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""

        let folder = newEntryTargetFolder
        var createdPath: RelativePath?
        do {
            let relPath = try await service.createEntryFolder(inFolder: folder, date: .now)
            createdPath = relPath
            try recorder.start(
                entryURL: vaultURL.appendingRelativePath(relPath),
                relativePath: relPath,
                quality: quality,
                preferredMicUID: micUID
            )
            updateLiveTranscription()
            await refresh()
        } catch {
            DebugLog.append("startRecording FAILED \(error)")
            if let createdPath {
                try? await service.removeEmptyEntryFolder(at: createdPath)
            }
            errorMessage = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func extensionBlockReason(for entry: Entry) -> RecordingExtensionBlockReason? {
        guard entry.hasAudio else { return entry.audioDeleted ? .audioDeleted : .noAudio }
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
        guard await RecorderService.ensureMicPermission() else {
            errorMessage = "Transcride needs microphone access to record a replacement take. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        do {
            var capturing = session
            capturing.phase = .capturing
            replacementSession = capturing
            try await service.saveReplacementSession(capturing)
            let quality = RecordingQuality(
                rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
            ) ?? .compressed
            let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""
            let target = ReplacementRecordingTarget(
                entryRelativePath: entry.relativePath,
                sessionID: capturing.id,
                region: capturing.region,
                takeNumber: capturing.takes.count + 1
            )
            recorder.onReplacementBoundaryReached = { [weak self] in
                Task { @MainActor [weak self] in await self?.stopReplacementTake() }
            }
            try recorder.start(
                entryURL: vaultURL.appendingRelativePath(entry.relativePath),
                relativePath: entry.relativePath,
                quality: quality,
                preferredMicUID: micUID,
                target: .replacementTake(target)
            )
            replacementPreviewLabel = "Recording Take \(target.takeNumber)"
        } catch {
            replacementSession?.phase = .failed
            replacementSession?.failureMessage = error.localizedDescription
            errorMessage = "The replacement take could not start: \(error.localizedDescription)"
        }
    }

    func stopReplacementTake() async {
        guard case .replacementTake? = recorder.sessionTarget,
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
            if selectedEntryID == session.entryRelativePath { await refresh() }
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
            recorder.cancelReplacementCapture()
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
        await validateExtensionAvailability(for: entry)
        guard let vaultURL, let audioName = entry.audioFileName,
              extensionBlockReason(for: entry) == nil else { return }
        guard await RecorderService.ensureMicPermission() else {
            errorMessage = "Transcride needs microphone access to extend a recording. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        player.pause()
        player.unload()
        let quality = RecordingQuality(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.recordingQuality) ?? ""
        ) ?? .compressed
        let micUID = UserDefaults.standard.string(forKey: PreferenceKey.preferredMicUID) ?? ""
        let target = RecordingExtensionTarget(
            entryRelativePath: entry.relativePath,
            sourceAudioFileName: audioName,
            sourceDuration: entry.duration ?? 0
        )
        do {
            try recorder.start(
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
        if case .replacementTake? = recorder.sessionTarget {
            await stopReplacementTake()
            return recorder.state == .idle && recorder.alertMessage == nil
        }
        stopLiveTranscription()
        guard let outcome = await recorder.stop() else { return false }
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
                _ = await refreshSelectingEntry(relPath)
                return true
            } catch {
                recorder.completeExtensionWorkflow(error: error)
                errorMessage = "The extension segment is safe, but it could not be appended: \(error.localizedDescription)"
                let discovery = await service.recordingExtensionRecoveries()
                extensionRecoveries = discovery.recoverable
                isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
                return false
            }
        }
        await service?.synchronizeSearchEntry(at: relPath)
        // Enqueue before the rescan so the entry's first selected frame
        // already carries its "waiting to transcribe" status row.
        TranscriptionSeam.audioEntryReady(entryRelativePath: relPath, source: .recorded)
        _ = await refreshSelectingEntry(relPath)
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
        guard let cancelled = recorder.cancelActiveCapture() else { return }
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
            if selectedEntryID == cancelled.entryRelativePath { await refresh() }
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
            isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
            audioRevision &+= 1
            _ = await refreshSelectingEntry(recovery.entryRelativePath)
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
            isExtensionRecoveryPresented = !extensionRecoveries.isEmpty
            _ = await refreshSelectingEntry(newPath)
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
                if self.selectedEntryID == originalPath, outcome.entryRelativePath != originalPath {
                    if self.editorLifecycleCoordinator.remapActiveDocument(
                        expectedOldPath: originalPath,
                        to: outcome.entryRelativePath
                    ) {
                        self.selectedEntryID = outcome.entryRelativePath
                    } else {
                        self.errorMessage = "The note was retitled, but the open editor could not be rebound safely. Reopen it before editing."
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
        let intent = beginSelectionIntent()
        guard await prepareSelectionIntent(intent, destination: nil) else { return }
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
        if let lastImported, selectionIntentIsCurrent(intent) {
            selectedEntryID = lastImported
        }
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
            if selectedEntryID == path { await refresh() }
            refreshVaultSearchIfVisible()
        } catch {
            errorMessage = "The clip could not be \(direction == .undo ? "undone" : "redone"): \(error.localizedDescription)"
            if selectedEntryID == path { await refresh() }
        }
    }

    // MARK: - Intents (speaker rename, TRN-6)

    /// Applies speaker renames (machine id → display name; nil/empty removes)
    /// and reloads the open transcript so the new labels render everywhere.
    func renameSpeakers(_ names: [String: String?], for entry: Entry) async {
        if selectedEntryID == entry.relativePath {
            guard await editorLifecycleCoordinator.prepare(for: .externalReload) else { return }
        }
        await perform("renameSpeakers [\(entry.relativePath)]") { service in
            try await service.saveSpeakerNames(names, atEntryPath: entry.relativePath)
            await MainActor.run { self.transcriptRevision += 1 }
        }
    }

    /// Changes only the presentation preference for cached speaker ids. The
    /// Original JSON is never rewritten and no transcription work is queued.
    func setSpeakerDetectionEnabled(_ enabled: Bool, for entry: Entry) async {
        if selectedEntryID == entry.relativePath {
            guard await editorLifecycleCoordinator.prepare(for: .externalReload) else { return }
        }
        await perform("setSpeakerDetectionEnabled [\(entry.relativePath)] = \(enabled)") { service in
            try await service.setSpeakerDetectionEnabled(
                enabled, atEntryPath: entry.relativePath
            )
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
        await readTranscript(atEntryPath: entry.relativePath)
    }

    func readTranscript(atEntryPath entryPath: RelativePath) async -> FrontmatterDocument? {
        await service?.readTranscript(atEntryPath: entryPath)
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
            await refresh()
            refreshVaultSearchIfVisible()
            return saved
        } catch {
            errorMessage = "Could not save the transcript: \(error.localizedDescription)"
            return nil
        }
    }

    func compareAndSaveTranscriptBody(
        _ body: String,
        expectedRevision: EditorBodyRevision,
        markHandEdited: Bool,
        clearHandEdited: Bool = false,
        for entry: Entry
    ) async -> TranscriptBodySaveResult? {
        await compareAndSaveTranscriptBody(
            body,
            expectedRevision: expectedRevision,
            markHandEdited: markHandEdited,
            clearHandEdited: clearHandEdited,
            atEntryPath: entry.relativePath
        )
    }

    func compareAndSaveTranscriptBody(
        _ body: String,
        expectedRevision: EditorBodyRevision,
        markHandEdited: Bool,
        clearHandEdited: Bool = false,
        atEntryPath entryPath: RelativePath
    ) async -> TranscriptBodySaveResult? {
        guard let service else { return nil }
        do {
            let result = try await service.compareAndSaveTranscriptBody(
                body,
                expectedRevision: expectedRevision,
                markHandEdited: markHandEdited,
                clearHandEdited: clearHandEdited,
                atEntryPath: entryPath
            )
            if case .saved = result {
                await refresh()
                refreshVaultSearchIfVisible()
            }
            return result
        } catch {
            errorMessage = "Could not save the transcript: \(error.localizedDescription)"
            return nil
        }
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
