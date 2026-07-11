import AppKit
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
        case retranscribe, trim, restoreOriginalAudio, exportMarkdown, deleteAudio, showInfo
    }

    enum WorkbenchActionRequest {
        case editOrSave, copyAsMarkdown, toggleLayer, renameSpeakers
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

    func setTrimModeActive(_ active: Bool) {
        trimModeActive = active
    }

    var sidebarSelection: SidebarSelection? = .folder("") {
        didSet {
            guard sidebarSelection != oldValue, let selectedEntryID else { return }
            let selectionStillVisible = displayedEntries.contains { $0.id == selectedEntryID }
            if !selectionStillVisible {
                self.selectedEntryID = nil
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
            if selectedEntryID != oldValue { player.unload() }
        }
    }
    var errorMessage: String?
    /// Informational notice kept separate from errors so a protected edited
    /// layer does not look like a failed retranscription.
    var transcriptNoticeMessage: String?

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
        installKeyMonitor()
        Task { await modelManager.refresh() }
        if let url = VaultBookmark.resolve() {
            await openVault(at: url, isSecurityScoped: true, saveBookmark: false)
        } else {
            phase = .needsVault
        }
    }

    /// Opens `url` as the vault, replacing any current vault.
    func openVault(at url: URL, isSecurityScoped: Bool, saveBookmark: Bool) async {
        if recorder.isActive {
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

        watcher = FSEventsWatcher(url: url) { [weak self] paths in
            Task {
                await service.synchronizeSearchIndex(changedAbsolutePaths: paths)
                await self?.handleExternalVaultChange(for: service)
            }
        }
        // Retention purge on launch/open (window configurable per vault,
        // SET-2), then first scan.
        storageSummary = nil
        trashRetentionDays = await service.trashRetentionDays()
        _ = try? await service.purgeTrash()
        await refresh()

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

    private func handleExternalVaultChange(for changedService: VaultService) async {
        guard service === changedService else { return }
        externalVaultRevision &+= 1
        await refresh()
        refreshVaultSearchIfVisible()
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
        await perform("renameFolder [\(relPath)] -> \(newName)") { service in
            let newPath = try await service.renameFolder(at: relPath, to: newName)
            await MainActor.run {
                if self.sidebarSelection == .folder(relPath) {
                    self.sidebarSelection = .folder(newPath)
                }
            }
        }
    }

    // MARK: - Intents (entries)

    func renameEntry(_ entry: Entry, toTitle title: String) async {
        await perform("renameEntry [\(entry.relativePath)] -> \(title)") { service in
            let newPath = try await service.renameEntry(at: entry.relativePath, toTitle: title)
            await MainActor.run {
                self.transcriptionQueue?.repointItems(from: entry.relativePath, to: newPath)
                if self.selectedEntryID == entry.relativePath {
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func moveItem(atRelativePath relPath: RelativePath, toFolder destFolder: RelativePath) async {
        await perform("moveItem [\(relPath)] -> [\(destFolder)]") { service in
            let newPath = try await service.moveItem(at: relPath, toFolder: destFolder)
            await MainActor.run {
                self.transcriptionQueue?.repointItems(from: relPath, to: newPath)
                if self.selectedEntryID == relPath {
                    self.selectedEntryID = newPath
                }
            }
        }
    }

    func deleteItem(atRelativePath relPath: RelativePath) async {
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
        let favorite = !entry.favorite
        await perform("setFavorite \(favorite) [\(entry.relativePath)]") { service in
            try await service.setFavorite(favorite, atEntryPath: entry.relativePath)
        }
    }

    /// Duplicate Entry (LIB-3): fresh timestamp folder, all files copied,
    /// title "… copy". The copy becomes the selection so the user lands on
    /// what they just made.
    func duplicateEntry(_ entry: Entry) async {
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

    // MARK: - Keyboard (search / find / Z / Space / arrows / delete / brackets)

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

    private let spaceKeyCode: UInt16 = 49
    private let escapeKeyCode: UInt16 = 53
    private let deleteKeyCode: UInt16 = 51
    private let zenKeyCode: UInt16 = 6
    private let findKeyCode: UInt16 = 3
    private let leftBracketKeyCode: UInt16 = 33
    private let rightBracketKeyCode: UInt16 = 30
    private let backslashKeyCode: UInt16 = 42
    private let leftArrowKeyCode: UInt16 = 123
    private let rightArrowKeyCode: UInt16 = 124
    private let downArrowKeyCode: UInt16 = 125
    private let upArrowKeyCode: UInt16 = 126

    /// Returns true when the event was consumed.
    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard phase == .ready else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Field editors (TextField, search) and TextEditor are all NSTextView.
        let focusedTextView = NSApp.keyWindow?.firstResponder as? NSTextView
        // A selectable read-only transcript should not suppress transport
        // shortcuts. Only an actual editor or field editor owns typing keys.
        let editingTextView = focusedTextView?.isEditable == true ? focusedTextView : nil

        if keyCode == findKeyCode, modifiers == [.command, .shift] {
            presentVaultSearch()
            return true
        }
        if keyCode == findKeyCode, modifiers == .command {
            guard !isVaultSearchPresented else { return false }
            requestInNoteFind()
            return selectedEntry != nil
        }

        if keyCode == escapeKeyCode, modifiers.isEmpty, trimModeActive {
            cancelTrimRequestRevision &+= 1
            return true
        }

        if keyCode == zenKeyCode {
            // Plain Z enters Zen from anywhere except text input. Once Zen is
            // active, Escape remains the deliberate exit control.
            guard modifiers.isEmpty, editingTextView == nil else { return false }
            recorder.isZenMode = true
            return true
        }

        if keyCode == leftBracketKeyCode || keyCode == rightBracketKeyCode || keyCode == backslashKeyCode {
            // [ and ] step playback speed and \ resets it to 1× whenever an
            // entry with audio is open, matching the transport speed control.
            guard modifiers.isEmpty, editingTextView == nil, player.url != nil else { return false }
            if keyCode == backslashKeyCode {
                player.speed = 1.0
            } else {
                player.stepSpeed(keyCode == rightBracketKeyCode ? 1 : -1)
            }
            return true
        }

        if keyCode == leftArrowKeyCode || keyCode == rightArrowKeyCode {
            // Left/Right skip the loaded audio by 15 seconds. Up/Down are
            // deliberately not intercepted so list clip selection keeps its
            // native keyboard behavior.
            // AppKit marks arrow events as numeric-pad/function keys even on
            // the built-in keyboard; those implicit flags are not user-held
            // modifiers and must not block the shortcut.
            let explicitModifiers = modifiers.subtracting([.numericPad, .function])
            guard explicitModifiers.isEmpty, editingTextView == nil, player.url != nil else { return false }
            player.skip(keyCode == rightArrowKeyCode ? 15 : -15)
            return true
        }

        if keyCode == upArrowKeyCode || keyCode == downArrowKeyCode {
            // Option-Up/Down navigates the far-left folder/sidebar pane while
            // leaving keyboard focus in the clip list. Plain Up/Down falls
            // through to the List's native adjacent-clip selection.
            let explicitModifiers = modifiers.subtracting([.numericPad, .function])
            guard explicitModifiers == .option, editingTextView == nil else { return false }
            return moveSidebarSelection(by: keyCode == downArrowKeyCode ? 1 : -1)
        }

        if keyCode == deleteKeyCode {
            // Command+Delete and Shift+Delete both move the selected clip
            // straight to Recently Deleted. Text editing keeps ownership of
            // either chord while an editable field or note has focus.
            guard modifiers == .command || modifiers == .shift, editingTextView == nil,
                  let entry = selectedEntry, recorder.currentEntryPath != entry.relativePath
            else { return false }
            Task { await deleteItem(atRelativePath: entry.relativePath) }
            return true
        }

        guard keyCode == spaceKeyCode else { return false }
        if modifiers == .shift {
            if let focusedTextView = editingTextView {
                // Typing wins: Shift+Space while writing inserts a space
                // instead of reaching the Start/Stop Recording menu item.
                focusedTextView.insertText(" ", replacementRange: focusedTextView.selectedRange())
                return true
            }
            return false // falls through to the File-menu item
        }
        if modifiers.isEmpty, editingTextView == nil {
            // While recording, Space is the pause/resume control; playback
            // only gets Space when the recorder is idle.
            switch recorder.state {
            case .recording:
                recorder.pause()
                return true
            case .paused:
                recorder.resume()
                return true
            case .finalizing:
                return false
            case .idle:
                if player.url != nil {
                    player.togglePlayPause()
                    return true
                }
            }
        }
        return false
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

    // MARK: - Intents (recording)

    /// Folder new recordings/imports land in: the selected folder, or the
    /// vault root when none / Recently Deleted is selected.
    private var newEntryTargetFolder: RelativePath {
        if case .folder(let relPath)? = sidebarSelection { return relPath }
        return ""
    }

    func startRecording() async {
        guard let service, let vaultURL, !recorder.isActive else { return }
        guard await RecorderService.ensureMicPermission() else {
            errorMessage = """
            Transcride needs microphone access to record. \
            Enable it in System Settings → Privacy & Security → Microphone, then try again.
            """
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

    func stopRecording() async {
        stopLiveTranscription()
        guard let relPath = await recorder.stop() else { return }
        await service?.synchronizeSearchEntry(at: relPath)
        // Enqueue before the rescan so the entry's first selected frame
        // already carries its "waiting to transcribe" status row.
        TranscriptionSeam.audioEntryReady(entryRelativePath: relPath, source: .recorded)
        await refresh { self.selectedEntryID = relPath }
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
                    self.selectedEntryID = outcome.entryRelativePath
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
        // An audio restore rearranges files the player or a running
        // transcription may hold open; both must let go first.
        if item.kind.isAudio, let vaultURL,
           player.url?.deletingLastPathComponent().path
               == vaultURL.appendingRelativePath(item.originalPath).path {
            player.unload()
        }
        if item.kind == .preTrimAudio {
            transcriptionQueue?.evictItems(underPath: item.originalPath)
        }
        await perform("restore [\(item.trashedName)]") { service in
            _ = try await service.restore(item)
            await MainActor.run {
                self.audioRevision &+= 1
                if item.kind == .preTrimAudio {
                    // The transcript still matches the displaced trimmed
                    // audio; bring the text back in line with the disk.
                    self.transcriptionQueue?.enqueue(
                        entryRelativePath: item.originalPath,
                        source: "trim-restore",
                        isRetranscribe: true
                    )
                }
            }
        }
    }

    func deleteTrashItemPermanently(_ item: TrashItem) async {
        await perform("deletePermanently [\(item.trashedName)]") { service in
            try await service.deletePermanently(item)
        }
    }

    /// Empties Recently Deleted in one pass (Voice Memos' "Delete All").
    /// The caller confirms first — this is the one unrecoverable bulk action.
    func emptyTrash() async {
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
        await service?.readTranscriptContent(atEntryPath: entry.relativePath)
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
