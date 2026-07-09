import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case folder(RelativePath)
    case recentlyDeleted
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
    }

    private(set) var phase: Phase = .launching
    private(set) var vaultURL: URL?
    private(set) var snapshot: VaultSnapshot?
    private(set) var trashItems: [TrashItem] = []

    let recorder = RecorderService()
    let player = PlayerService()
    let inputDevices = AudioInputDevices()
    let modelManager = ModelManager()
    let liveTranscriber = LiveTranscriber()

    private(set) var transcriptionQueue: TranscriptionQueue?
    /// Bumped whenever a transcription lands so the detail view re-reads
    /// `transcript.md` (the FSEvents watcher ignores our own writes).
    private(set) var transcriptRevision = 0

    var sidebarSelection: SidebarSelection? = .folder("")
    var selectedEntryID: String? {
        didSet {
            // PLY: switching entries stops playback; returning doesn't resume.
            if selectedEntryID != oldValue { player.unload() }
        }
    }
    var errorMessage: String?

    private var service: VaultService?
    private var watcher: FSEventsWatcher?
    /// URL currently holding security-scoped access (stopAccessing on switch).
    private var scopedURL: URL?

    var selectedEntry: Entry? {
        guard let selectedEntryID else { return nil }
        return snapshot?.entry(withID: selectedEntryID)
    }

    var selectedFolder: FolderNode? {
        guard case .folder(let relPath)? = sidebarSelection else { return nil }
        return snapshot?.folder(at: relPath)
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
        if saveBookmark {
            do {
                try VaultBookmark.save(url)
            } catch {
                errorMessage = "Could not save vault access: \(error.localizedDescription)"
            }
        }

        vaultURL = url
        let service = VaultService(rootURL: url)
        self.service = service
        snapshot = nil
        trashItems = []
        sidebarSelection = .folder("")
        selectedEntryID = nil
        phase = .ready

        transcriptionQueue?.shutdown()
        let queue = TranscriptionQueue(vaultRoot: url, service: service)
        queue.onEntryTranscribed = { [weak self] originalPath, outcome in
            self?.entryTranscribed(originalPath: originalPath, outcome: outcome)
        }
        transcriptionQueue = queue
        TranscriptionSeam.queue = queue

        watcher = FSEventsWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }

        // 30-day purge on launch/open, then first scan.
        _ = try? await service.purgeTrash()
        await refresh()
    }

    func refresh() async {
        guard let service else { return }
        let snap = await service.snapshot()
        let trash = (try? await service.trashItems()) ?? []
        snapshot = snap
        trashItems = trash
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
        if selectedEntryID == relPath, let entries = selectedFolder?.entries,
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

    // MARK: - Keyboard (Z / Space / Shift+Space / Shift+Delete)

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
    private let deleteKeyCode: UInt16 = 51
    private let zenKeyCode: UInt16 = 6

    /// Returns true when the event was consumed.
    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard phase == .ready else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Field editors (TextField, search) and TextEditor are all NSTextView.
        let focusedTextView = NSApp.keyWindow?.firstResponder as? NSTextView

        if keyCode == zenKeyCode {
            // Plain Z enters Zen from anywhere except text input. Once Zen is
            // active, Escape remains the deliberate exit control.
            guard modifiers.isEmpty, focusedTextView == nil else { return false }
            recorder.isZenMode = true
            return true
        }

        if keyCode == deleteKeyCode {
            // Shift+Delete: straight to Recently Deleted, no confirmation —
            // it's restorable for 30 days, so there's nothing to warn about.
            guard modifiers == .shift, focusedTextView == nil,
                  let entry = selectedEntry, recorder.currentEntryPath != entry.relativePath
            else { return false }
            Task { await deleteItem(atRelativePath: entry.relativePath) }
            return true
        }

        guard keyCode == spaceKeyCode else { return false }
        if modifiers == .shift {
            if let focusedTextView {
                // Typing wins: Shift+Space while writing inserts a space
                // instead of reaching the Start/Stop Recording menu item.
                focusedTextView.insertText(" ", replacementRange: focusedTextView.selectedRange())
                return true
            }
            return false // falls through to the File-menu item
        }
        if modifiers.isEmpty, focusedTextView == nil {
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
        await refresh()
        selectedEntryID = relPath
        TranscriptionSeam.audioEntryReady(entryRelativePath: relPath, source: .recorded)
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
        transcriptRevision += 1
        if selectedEntryID == originalPath, outcome.entryRelativePath != originalPath {
            selectedEntryID = outcome.entryRelativePath
        }
        Task { await refresh() }
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

    // MARK: - Intents (trash)

    func restoreTrashItem(_ item: TrashItem) async {
        await perform("restore [\(item.trashedName)]") { service in
            _ = try await service.restore(item)
        }
    }

    func deleteTrashItemPermanently(_ item: TrashItem) async {
        await perform("deletePermanently [\(item.trashedName)]") { service in
            try await service.deletePermanently(item)
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

    func readTranscript(for entry: Entry) async -> FrontmatterDocument? {
        await service?.readTranscript(atEntryPath: entry.relativePath)
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
    }
}
