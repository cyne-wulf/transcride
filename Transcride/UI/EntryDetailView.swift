import SwiftUI

/// Voice Memos-style detail workbench: transcript first, playback shelf below,
/// with entry metadata tucked behind Show Info.
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?
    @State private var original: TranscriptOriginal?
    @State private var extensionTranscriptState: ExtensionTranscriptState?
    @State private var loadedEntryPath: RelativePath?
    @State private var showingInfo = false
    @State private var showingRetranscribe = false
    // Payload separate from isPresented — SwiftUI clears the presentation
    // binding before running dialog button actions.
    @State private var showingDeleteAudio = false
    @State private var deleteAudioByteSize: Int64?
    @State private var isTrimming = false
    @State private var showingCompressConfirm = false
    @State private var showingRestoreOriginal = false
    @State private var restoringOriginalItem: TrashItem?
    @State private var showingExport = false

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                entryDetail(entry)
                    .task(id: taskKey(for: entry)) {
                        if loadedEntryPath != entry.relativePath {
                            // A loaded path that vanished from the snapshot is
                            // the same entry renamed (auto-title, retitle), not
                            // a switch: keep the content up and swap in place
                            // instead of dropping to the loading placeholder.
                            if let loadedEntryPath, document != nil || original != nil,
                               model.snapshot?.entry(withID: loadedEntryPath) == nil {
                                self.loadedEntryPath = entry.relativePath
                            } else {
                                document = nil
                                original = nil
                                extensionTranscriptState = nil
                                loadedEntryPath = nil
                                isTrimming = false
                                model.player.unload()
                            }
                        }
                        let speechAvailability = model.speechTranscriptAvailability(for: entry)
                        model.player.configureSilenceDetection(
                            entryID: entry.relativePath,
                            mode: entry.silenceDetectionMode
                        )
                        guard let content = await model.readTranscriptContent(for: entry),
                              !Task.isCancelled,
                              model.selectedEntryID == entry.relativePath else { return }
                        document = content.edited
                        original = content.original
                        extensionTranscriptState = content.extensionState
                        loadedEntryPath = entry.relativePath
                        model.player.setTranscriptForSilenceSkipping(
                            content.original,
                            duration: content.extensionState?.knownTranscriptDuration
                                ?? entry.duration,
                            availability: speechAvailability,
                            entryID: entry.relativePath
                        )
                    }
            } else {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "waveform",
                    description: Text("Select an entry to see its transcript — or start talking with a new recording.")
                )
            }
        }
        .toolbar {
            // The middle/detail boundary must exist independently of selection.
            // Putting this spacer inside entryDetail makes SwiftUI remove the
            // detail toolbar section on a fresh launch, so EntryListView's Queue
            // and Sort controls drift to the window's trailing edge.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            } else {
                ToolbarItem(id: "detailAnchor") {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Reload for entry/title changes, external vault writes, or a landed
    /// transcription. Deliberately exclude `entry.snippet`: autosave refreshes
    /// that list preview, and reloading the editor from an earlier debounced
    /// save could otherwise overwrite newer unsaved keystrokes.
    private func taskKey(for entry: Entry) -> String {
        "\(entry.relativePath)|\(entry.title ?? "")|silence:\(entry.silenceDetectionMode.rawValue)|speech:\(entry.speechTranscriptAvailability)|external:\(model.externalVaultRevision)|transcription:\(model.transcriptRevision)"
    }

    private func infoPopover(_ entry: Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            infoRow("Created", entry.created.formatted(date: .complete, time: .standard))
            if let duration = entry.duration {
                infoRow("Duration", EntryListView.formatDuration(duration))
            }
            infoRow("Audio", entry.hasAudio ? "Yes" : (entry.audioDeleted ? "Deleted" : "None"))
            if let source = document?.source { infoRow("Source", source) }
            if let engine = document?.engine { infoRow("Engine", engine) }
            infoRow("Favorite", entry.favorite ? "Yes" : "No")
            infoRow("Folder", entry.parentRelativePath.isEmpty ? "Vault Root" : entry.parentRelativePath)
            infoRow("Entry ID", entry.folderName.string)
        }
        .font(.callout)
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func entryDetail(_ entry: Entry) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text(entry.created.formatted(date: .omitted, time: .shortened))
                        if let duration = entry.duration {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(EntryListView.formatDuration(duration))
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)

                if loadedEntryPath == entry.relativePath, document != nil || original != nil {
                    // Full pane width: the workbench pins its action row to the
                    // pane's top-right corner and centers the note column itself.
                    TranscriptWorkbenchView(
                        entry: entry,
                        original: original,
                        extensionState: extensionTranscriptState,
                        document: $document
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                } else if loadedEntryPath != entry.relativePath {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.hasTranscript {
                    ContentUnavailableView(
                        "Transcript Is Empty",
                        systemImage: "text.document",
                        description: Text("Check the transcription queue in the toolbar.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Transcript",
                        systemImage: "text.badge.xmark",
                        description: Text("This entry does not have a transcript file yet.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let queue = model.transcriptionQueue,
                   let queueItem = queue.items.first(where: { $0.entryRelativePath == entry.relativePath }) {
                    transcriptionStatus(queueItem, queue: queue)
                        .padding(.horizontal, 36)
                        .padding(.top, 6)
                        .frame(maxWidth: 900)
                }
            }
            // Keep playback out of the transcript's vertical stack. This local
            // inset reserves the shelf above MainView's recorder inset, so the
            // native transcript scroller is proposed only the space between
            // the title and playback controls and cannot push either bar away.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if entry.hasAudio {
                    playbackShelf(entry, availableHeight: proxy.size.height)
                }
            }
        }
        .contentShape(Rectangle())
        .onExitCommand {
            model.handleExitCommand()
        }
        .onChange(of: isTrimming) { _, active in
            model.setTrimModeActive(active)
        }
        .onChange(of: model.cancelTrimRequestRevision) { _, _ in
            if isTrimming { isTrimming = false }
        }
        .onChange(of: model.speechTranscriptAvailability(for: entry)) { _, availability in
            model.player.configureSilenceDetection(
                entryID: entry.relativePath, mode: entry.silenceDetectionMode
            )
            model.player.setTranscriptForSilenceSkipping(
                original,
                duration: extensionTranscriptState?.knownTranscriptDuration ?? entry.duration,
                availability: availability,
                entryID: entry.relativePath
            )
        }
        .onDisappear {
            model.setTrimModeActive(false)
        }
        .contextMenu {
            Button(entry.favorite ? "Unfavorite" : "Favorite") {
                Task { await model.toggleFavorite(for: entry) }
            }
            Button("Duplicate Entry") { Task { await model.duplicateEntry(entry) } }
            Divider()
            Button("Show Info") { showingInfo = true }
            Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
            if model.originalAudioTrashItem(for: entry) != nil {
                Button("Restore Original Audio…") { promptRestoreOriginal(entry) }
            }
            if entry.hasAudio {
                Button("Extend Recording") { Task { await model.startExtension(for: entry) } }
                    .disabled(model.extensionBlockReason(for: entry) != nil)
                Button("Compress Audio…") { showingCompressConfirm = true }
                    .disabled(!canCompress(entry))
            }
            if entry.hasAudio || entry.audioDeleted {
                Divider()
                Button("Delete Audio…", role: .destructive) { promptDeleteAudio(entry) }
                    .disabled(!canDeleteAudio(entry))
            }
        }
        .toolbar {
            ToolbarItem(id: "detailFavorite", placement: .primaryAction) {
                Button {
                    Task { await model.toggleFavorite(for: entry) }
                } label: {
                    Label(
                        entry.favorite ? "Unfavorite" : "Favorite",
                        systemImage: entry.favorite ? "star.fill" : "star"
                    )
                }
                .help(entry.favorite ? "Remove from Favorites" : "Add to Favorites")
            }
            ToolbarItem(id: "detailRetranscribe", placement: .primaryAction) {
                Button {
                    showingRetranscribe = true
                } label: {
                    Label("Retranscribe", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!entry.hasAudio || model.replacementModeActive)
                .help(entry.audioUnavailableExplanation
                    ?? (entry.hasAudio
                        ? "Retranscribe with a different model"
                        : "No audio is available to retranscribe"))
            }
            ToolbarItem(id: "detailInfo", placement: .primaryAction) {
                Button {
                    showingInfo.toggle()
                } label: {
                    Label("Show Info", systemImage: "info.circle")
                }
                .help("Show Info")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    infoPopover(entry)
                }
            }
            ToolbarItem(id: "detailReveal", placement: .primaryAction) {
                Button {
                    model.revealInFinder(relativePath: entry.relativePath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
            }
            ToolbarItem(id: "detailMore", placement: .primaryAction) {
                Menu {
                    if entry.hasAudio {
                        Button("Extend Recording") {
                            Task { await model.startExtension(for: entry) }
                        }
                        .disabled(model.extensionBlockReason(for: entry) != nil)
                        .help(model.extensionBlockReason(for: entry)?.explanation
                            ?? "Extend Recording")
                        Button("Replace Audio…") {
                            isTrimming = false
                            model.beginReplacement(for: entry)
                        }
                        .disabled(model.replacementBlockedReason(for: entry) != nil)
                        .help(model.replacementBlockedReason(for: entry)
                            ?? "Replace an exact selected region with a new take")
                        Divider()
                    }
                    if entry.hasAudio || entry.audioDeleted {
                        Button("Trim Audio…") { isTrimming = true }
                            .disabled(!canTrim(entry))
                            .help(entry.audioUnavailableExplanation
                                ?? "Select the range of audio to keep")
                        Button("Compress Audio…") { showingCompressConfirm = true }
                            .disabled(!canCompress(entry))
                            .help(compressBlockedReason(entry)
                                ?? "Remove silence longer than 1.5 seconds")
                    }
                    if entry.hasAudio {
                        Menu("Silence Detection") {
                            Button {
                                Task { await model.setSilenceDetectionMode(.waveform, for: entry) }
                            } label: {
                                silenceDetectionChoiceLabel(.waveform, entry: entry)
                            }
                            Button {
                                Task { await model.setSilenceDetectionMode(.speech, for: entry) }
                            } label: {
                                silenceDetectionChoiceLabel(.speech, entry: entry)
                            }
                            .disabled(model.speechTranscriptAvailability(for: entry) != .available)
                            .help(model.speechTranscriptAvailability(for: entry).explanation
                                ?? "Use timed Original transcript gaps; useful when room noise stays above the waveform threshold")
                        }
                        .help(silenceDetectionHelp(entry))
                    }
                    if entry.hasAudio {
                        Toggle("Loop Audio", isOn: Binding(
                            get: { model.player.loopAudio },
                            set: { model.player.loopAudio = $0 }
                        ))
                        .help("Restart this audio automatically when playback reaches the end")
                    }
                    if model.originalAudioTrashItem(for: entry) != nil {
                        Button("Restore Original Audio…") { promptRestoreOriginal(entry) }
                            .help("Undo trimming and restore the full retained clip")
                    }
                    Button("Duplicate Entry") { Task { await model.duplicateEntry(entry) } }
                    Divider()
                    Button("Export Markdown…") { showingExport = true }
                        .disabled(original == nil && document == nil)
                        .help("Write this note as a clean .md file into a folder")
                    if entry.hasAudio, let audioURL = model.audioURL(for: entry) {
                        ShareLink(item: audioURL) {
                            Label("Share Audio…", systemImage: "square.and.arrow.up")
                        }
                        .help("Send the audio file with AirDrop, Messages, Mail…")
                    } else if entry.audioDeleted {
                        Button("Share Audio…") {}
                            .disabled(true)
                            .help(entry.audioUnavailableExplanation ?? "")
                    }
                    if model.vaultHasObsidianConfig, entry.hasTranscript {
                        Button("Open in Obsidian") { model.openInObsidian(entry: entry) }
                            .help("Open this note in Obsidian")
                    }
                    if entry.hasAudio || entry.audioDeleted {
                        Divider()
                        Button("Delete Audio…", role: .destructive) { promptDeleteAudio(entry) }
                            .disabled(!canDeleteAudio(entry))
                            .help(entry.audioUnavailableExplanation ?? "")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
        .onChange(of: model.entryActionRevision) { _, _ in
            // Menu-bar items reach this view's sheets/prompts through the
            // request pattern; conditions mirror the equivalent buttons.
            switch model.entryActionRequest {
            case .extendRecording:
                if model.extensionBlockReason(for: entry) == nil {
                    Task { await model.startExtension(for: entry) }
                }
            case .retranscribe:
                if entry.hasAudio { showingRetranscribe = true }
            case .trim:
                if canTrim(entry) { isTrimming = true }
            case .compress:
                if canCompress(entry) { showingCompressConfirm = true }
            case .restoreOriginalAudio:
                promptRestoreOriginal(entry)
            case .exportMarkdown:
                if original != nil || document != nil { showingExport = true }
            case .deleteAudio:
                if canDeleteAudio(entry) { promptDeleteAudio(entry) }
            case .showInfo:
                showingInfo = true
            case nil:
                break
            }
        }
        .sheet(isPresented: $showingRetranscribe) {
            RetranscribeSheet(entry: entry)
        }
        .sheet(isPresented: $showingExport) {
            ExportMarkdownSheet(entry: entry, original: original, document: document)
        }
        .confirmationDialog(
            "Compress “\(entry.displayTitle)” by removing long silence?",
            isPresented: $showingCompressConfirm,
            titleVisibility: .visible
        ) {
            Button("Compress and Retranscribe", role: .destructive) {
                Task { await model.compressAudio(for: entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(compressionConfirmationMessage(entry))
        }
        .confirmationDialog(
            "Restore the full original audio of “\(entry.displayTitle)”?",
            isPresented: $showingRestoreOriginal,
            titleVisibility: .visible
        ) {
            Button("Restore Original Audio") {
                if let item = restoringOriginalItem {
                    isTrimming = false
                    Task { await model.restoreTrashItem(item) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current trimmed audio moves to Recently Deleted, and the entry "
                + "is re-transcribed to match the restored full clip. Your Edited layer is not overwritten.")
        }
        .confirmationDialog(
            "Delete the audio from “\(entry.displayTitle)”?",
            isPresented: $showingDeleteAudio,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                Task { await model.deleteAudio(for: entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAudioMessage)
        }
    }

    // MARK: - Delete audio (AUD-1)

    /// Deleting audio needs the file intact: not mid-recording, not vanished.
    private func canDeleteAudio(_ entry: Entry) -> Bool {
        entry.hasAudio
            && model.recorder.currentEntryPath != entry.relativePath
            && !model.compressingEntryPaths.contains(entry.relativePath)
            && !model.clipMutationEntryPaths.contains(entry.relativePath)
            && !model.replacementModeActive
    }

    // MARK: - Trim (AUD-3)

    /// Trimming needs stable audio: not mid-recording and not being read by a
    /// queued or running transcription.
    private func canTrim(_ entry: Entry) -> Bool {
        model.trimBlockedReason(for: entry, duration: entry.duration) == nil
    }

    private func canCompress(_ entry: Entry) -> Bool {
        compressBlockedReason(entry) == nil
    }

    private func compressBlockedReason(_ entry: Entry) -> String? {
        guard canTrim(entry), !model.compressingEntryPaths.contains(entry.relativePath) else {
            return "Wait until audio processing is idle."
        }
        if entry.silenceDetectionMode == .speech {
            return model.speechTranscriptAvailability(for: entry).explanation
        }
        return nil
    }

    private func silenceDetectionHelp(_ entry: Entry) -> String {
        model.speechTranscriptAvailability(for: entry).explanation
            ?? "Waveform uses audio level. Speech Transcript uses timed word gaps and remains useful in noisy rooms."
    }

    @ViewBuilder
    private func silenceDetectionChoiceLabel(
        _ mode: SilenceDetectionMode, entry: Entry
    ) -> some View {
        if entry.silenceDetectionMode == mode {
            Label(mode.displayName, systemImage: "checkmark")
        } else {
            Text(mode.displayName)
        }
    }

    private func compressionConfirmationMessage(_ entry: Entry) -> String {
        let shared = " Silence longer than 1.5 seconds is removed with 0.1-second padding. This changes later timestamps, so the full audio is re-transcribed. A hand-edited note is never overwritten, and the original audio remains recoverable in Recently Deleted."
        if entry.silenceDetectionMode == .speech {
            return "Speech Transcript keeps only regions detected as speech. All other audio—including music, applause, or ambient sound—may be removed." + shared
        }
        return "Waveform detection uses the audio level." + shared
    }

    private func promptDeleteAudio(_ entry: Entry) {
        Task {
            deleteAudioByteSize = await model.audioFileByteSize(for: entry)
            showingDeleteAudio = true
        }
    }

    private func promptRestoreOriginal(_ entry: Entry) {
        guard let item = model.originalAudioTrashItem(for: entry) else { return }
        restoringOriginalItem = item
        showingRestoreOriginal = true
    }

    private var deleteAudioMessage: String {
        let size = deleteAudioByteSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "its disk space"
        return "This frees \(size). The transcript is kept, and the audio "
            + "can be restored from Recently Deleted for \(model.trashRetentionDays) days."
    }

    private func playbackShelf(_ entry: Entry, availableHeight: CGFloat) -> some View {
        let compact = availableHeight < 620
        return PlaybackSection(entry: entry, availableHeight: availableHeight, isTrimming: $isTrimming)
            .frame(maxWidth: 900)
            .padding(.horizontal, 36)
            .padding(.top, compact ? 6 : 10)
            .padding(.bottom, compact ? 8 : 18)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-playback-shelf")
    }

    /// Inline transcription state for the open entry (TRN-3): the queue
    /// popover is easy to miss, so the entry itself says it's being worked on.
    @ViewBuilder
    private func transcriptionStatus(_ item: TranscriptionQueueItem, queue: TranscriptionQueue) -> some View {
        HStack(spacing: 8) {
            switch item.state {
            case .waiting:
                ProgressView().controlSize(.small)
                Text("Waiting to transcribe…")
            case .running:
                if queue.speakerPhaseItemIDs.contains(item.id) {
                    ProgressView(value: queue.progressByItemID[item.id] ?? 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                    Text("Detecting speakers…")
                } else if (queue.progressByItemID[item.id] ?? 0) <= 0.001 {
                    // No engine progress yet means the model is still loading
                    // (first load compiles for the Neural Engine — minutes).
                    ProgressView().controlSize(.small)
                    Text("Preparing model…")
                } else {
                    ProgressView(value: queue.progressByItemID[item.id] ?? 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                    Text("Transcribing…")
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(item.errorMessage ?? "Transcription failed.")
                Button("Retry") { queue.retry(itemID: item.id) }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

}

/// Waveform + transport for an entry with audio (PLY-3, PLY-4). The waveform
/// comes from the entry's `waveform.json`, generated on first open when
/// missing. Space toggles play/pause via the play button's key equivalent.
private struct PlaybackSection: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let availableHeight: CGFloat
    @Binding var isTrimming: Bool

    @State private var waveform: WaveformData?
    @State private var waveformError: String?
    @State private var sectionWidth: CGFloat = 420
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var showingTrimConfirm = false
    @State private var replacementStart: Double = 0
    @State private var replacementEnd: Double = 0
    @State private var replacementInitializedEntryPath: RelativePath?
    @State private var showingBakeConfirm = false
    @State private var showingChangeRegionConfirm = false
    @State private var replacementCompositeWaveform: WaveformData?

    private var player: PlayerService { model.player }

    /// Best-known audio length for trim math (the waveform cache carries the
    /// decoded duration; the player's may still be loading).
    private var trimDuration: Double {
        waveform?.duration ?? (player.duration > 0 ? player.duration : entry.duration ?? 0)
    }

    private var trimSelection: TrimSelection {
        TrimSelection(start: trimStart, end: trimEnd)
    }

    private var replacementSelection: AudioRangeSelection {
        AudioRangeSelection(start: replacementStart, end: replacementEnd)
    }

    private var isReplacing: Bool {
        model.replacementEntryPath == entry.relativePath
    }

    private var displayedWaveform: WaveformData? {
        if isReplacing, let replacementCompositeWaveform {
            return replacementCompositeWaveform
        }
        return waveform
    }

    /// Why trim mode can't start right now; nil when it can.
    private var trimBlockedReason: String? {
        model.trimBlockedReason(for: entry, duration: trimDuration)
    }

    /// Controls grow modestly with the detail column while preserving the
    /// compact proportions of Voice Memos' lower playback shelf.
    private var controlScale: CGFloat {
        min(max(sectionWidth / 620, 0.9), 1.15) * heightScale
    }

    /// Preserve the full Voice Memos hierarchy while leaving a useful text
    /// viewport in short windows. This scales proportions instead of assigning
    /// any fixed transcript height, so large windows retain the spacious shelf.
    private var heightScale: CGFloat {
        if availableHeight < 420 { return 0.74 }
        if availableHeight < 520 { return 0.84 }
        if availableHeight < 620 { return 0.92 }
        return 1
    }

    var body: some View {
        VStack(spacing: 8 * controlScale) {
            if isActiveExtension {
                extensionShelf
            } else if isReplacing {
                waveformShelf
            } else {
                waveformShelf

                Text(Self.playheadLabel(player.currentTime))
                    .font(.system(size: 36 * controlScale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                transport
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            sectionWidth = width
        }
        .task(id: "\(entry.relativePath)|\(entry.audioFileName ?? "")|audio:\(model.audioRevision)") {
            await model.validateExtensionAvailability(for: entry)
            if let url = model.audioURL(for: entry) {
                player.load(url: url, knownDuration: entry.duration)
            }
            waveform = nil
            waveformError = nil
            do {
                waveform = try await model.waveform(for: entry)
                rebuildReplacementCompositeWaveform()
                if let waveform {
                    model.player.setWaveformForSilenceSkipping(
                        waveform, entryID: entry.relativePath
                    )
                }
            } catch is CancellationError {
                // switched away mid-generation; next open restarts it
            } catch {
                waveformError = error.localizedDescription
            }
        }
        .onChange(of: isTrimming) { _, trimming in
            guard trimming else {
                player.clearPlaybackRange()
                return
            }
            guard trimBlockedReason == nil else {
                isTrimming = false
                return
            }
            trimStart = 0
            trimEnd = trimDuration
            player.setPlaybackRange(start: trimStart, end: trimEnd)
        }
        .onChange(of: trimStart) { _, start in
            guard isTrimming else { return }
            player.setPlaybackRange(start: start, end: trimEnd)
        }
        .onChange(of: trimEnd) { _, end in
            guard isTrimming else { return }
            player.setPlaybackRange(start: trimStart, end: end)
        }
        .onChange(of: model.replacementEntryPath, initial: true) { _, path in
            guard path == entry.relativePath else {
                replacementInitializedEntryPath = nil
                replacementCompositeWaveform = nil
                return
            }
            initializeReplacementSelectionIfNeeded()
            rebuildReplacementCompositeWaveform()
        }
        .onChange(of: model.replacementTakeWaveformID, initial: true) { _, _ in
            rebuildReplacementCompositeWaveform()
        }
        .onChange(of: model.replacementSession?.selectedTakeID, initial: true) { _, _ in
            rebuildReplacementCompositeWaveform()
        }
        .onChange(of: trimDuration, initial: true) { _, _ in
            guard isReplacing else { return }
            initializeReplacementSelectionIfNeeded()
        }
        .confirmationDialog(
            "Trim “\(entry.displayTitle)” to the selected range?",
            isPresented: $showingTrimConfirm,
            titleVisibility: .visible
        ) {
            Button("Trim and Retranscribe", role: .destructive) {
                let selection = trimSelection
                isTrimming = false
                Task { await model.trimAudio(for: entry, selection: selection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trimConfirmMessage)
        }
        .confirmationDialog(
            "Bake the selected take into “\(entry.displayTitle)” ?",
            isPresented: $showingBakeConfirm,
            titleVisibility: .visible
        ) {
            Button("Bake Selected Take", role: .destructive) {
                Task { await model.bakeSelectedReplacement() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chosen take replaces exactly the selected time range. The full audio is re-transcribed; a hand-edited note remains untouched. The prior audio version stays recoverable in Recently Deleted.")
        }
        .confirmationDialog(
            "Change the replacement region?",
            isPresented: $showingChangeRegionConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Takes and Change Region", role: .destructive) {
                Task {
                    await model.cancelReplacement()
                    model.beginReplacement(for: entry)
                }
            }
            Button("Keep Current Region", role: .cancel) {}
        } message: {
            Text("All temporary takes for this locked region will be discarded. The entry audio and transcripts remain unchanged.")
        }
    }

    private var isActiveExtension: Bool {
        model.recorder.currentEntryPath == entry.relativePath
            && model.recorder.extensionSession != nil
    }

    private func initializeReplacementSelectionIfNeeded() {
        guard trimDuration > 0,
              replacementInitializedEntryPath != entry.relativePath else { return }
        if let session = model.replacementSession,
           session.entryRelativePath == entry.relativePath {
            replacementStart = session.region.start
            replacementEnd = session.region.end
        } else {
            let initial = AudioRangeSelection.initialReplacementSelection(
                forDuration: trimDuration
            )
            replacementStart = initial.start
            replacementEnd = initial.end
        }
        replacementInitializedEntryPath = entry.relativePath
    }

    private func rebuildReplacementCompositeWaveform() {
        guard isReplacing,
              let waveform,
              let session = model.replacementSession,
              let selectedTakeID = session.selectedTakeID,
              model.replacementTakeWaveformID == selectedTakeID,
              let takeWaveform = model.replacementTakeWaveform else {
            replacementCompositeWaveform = nil
            return
        }
        replacementCompositeWaveform = waveform.previewReplacing(
            start: session.region.start,
            end: session.region.end,
            with: takeWaveform
        )
    }

    private var extensionShelf: some View {
        VStack(spacing: 10 * controlScale) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.recorder.state == .paused ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                Text(model.recorder.state == .finalizing ? "Finishing extension…" : "Extending")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Combined: " + EntryListView.formatDuration(
                    (entry.duration ?? 0) + model.recorder.elapsed
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LiveWaveformView(peaks: model.recorder.livePeaks)
                .frame(height: 56 * controlScale)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .opacity(model.recorder.state == .paused ? 0.45 : 1)
                .accessibilityLabel("Live extension waveform")

            Text(Self.playheadLabel(model.recorder.elapsed))
                .font(.system(size: 36 * controlScale, weight: .semibold, design: .rounded))
                .monospacedDigit()

            HStack(spacing: 24 * controlScale) {
                if model.recorder.state == .finalizing {
                    ProgressView().controlSize(.small)
                } else {
                    TransportButton(
                        systemImage: model.recorder.state == .paused ? "record.circle" : "pause.fill",
                        size: 20 * controlScale,
                        help: model.recorder.state == .paused ? "Resume Extension (Space)" : "Pause Extension (Space)"
                    ) {
                        Task { await model.toggleRecordingPause() }
                    }
                    TransportButton(
                        systemImage: "stop.fill", size: 20 * controlScale,
                        help: "Stop and Append Extension"
                    ) {
                        Task { await model.stopRecording() }
                    }
                    .accessibilityLabel("Stop Extending")
                }
            }
            .padding(.horizontal, 22 * controlScale)
            .padding(.vertical, 7 * controlScale)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.7), lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extension-transport")
    }

    private var trimConfirmMessage: String {
        "This keeps \(EntryListView.formatDuration(trimSelection.length)) of "
            + "\(EntryListView.formatDuration(trimDuration)) and re-transcribes the audio "
            + "(a hand-edited note is never overwritten). The original audio can be restored "
            + "from Recently Deleted for \(model.trashRetentionDays) days."
    }

    private var waveformShelf: some View {
        VStack(spacing: 5) {
            waveformArea
                .frame(height: 56 * controlScale)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if isTrimming, waveform != nil {
                        TrimSelectionOverlay(
                            start: $trimStart,
                            end: $trimEnd,
                            duration: trimDuration,
                            onSeek: { player.seek(toFraction: $0) }
                        )
                            .padding(.horizontal, 8)
                    } else if isReplacing, waveform != nil {
                        AudioRangeSelectionOverlay(
                            start: $replacementStart,
                            end: $replacementEnd,
                            duration: trimDuration,
                            purpose: .replace,
                            isLocked: model.replacementSession != nil,
                            onSeek: { player.seek(toFraction: $0) }
                        )
                        .padding(.horizontal, 8)
                    }
                }

            if isTrimming {
                trimControls
            } else if isReplacing {
                replacementControls
            } else {
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(EntryListView.formatDuration(player.duration))
                        .padding(.trailing, audioDragURL == nil ? 0 : 2)
                    audioDragChip
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var replacementControls: some View {
        VStack(spacing: 9) {
            Text("Replace \(EntryListView.formatDuration(replacementStart)) – "
                + "\(EntryListView.formatDuration(replacementEnd)) · "
                + EntryListView.formatDuration(
                    model.replacementSession?.region.duration ?? replacementSelection.length
                ))
                .font(.callout.weight(.semibold).monospacedDigit())

            if model.replacementSession == nil {
                HStack(spacing: 6) {
                    Button("−0.01 Start") {
                        replacementStart = max(0, replacementStart - 0.01)
                    }
                    Button("+0.01 Start") {
                        replacementStart = min(replacementEnd - 0.5, replacementStart + 0.01)
                    }
                    Button("−0.01 End") {
                        replacementEnd = max(replacementStart + 0.5, replacementEnd - 0.01)
                    }
                    Button("+0.01 End") {
                        replacementEnd = min(trimDuration, replacementEnd + 0.01)
                    }
                }
                .font(.caption)
                .controlSize(.small)
            }

            replacementTransport

            if let label = model.replacementPreviewLabel {
                Text("Hearing: \(label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.recorder.currentEntryPath == entry.relativePath,
               case .replacementTake? = model.recorder.sessionTarget {
                VStack(spacing: 7) {
                    ProgressView(
                        value: min(model.recorder.elapsed,
                                   model.replacementSession?.region.duration ?? 1),
                        total: model.replacementSession?.region.duration ?? 1
                    )
                    Text("Recording Take \((model.replacementSession?.takes.count ?? 0) + 1) · "
                        + EntryListView.formatDuration(model.recorder.elapsed))
                        .font(.caption.monospacedDigit())
                    Button("Stop Early") {
                        Task { await model.stopReplacementTake() }
                    }
                    .help("Keep this attempt as an Incomplete Take")
                }
            } else if let session = model.replacementSession {
                if !session.takes.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(session.takes) { take in
                            HStack(spacing: 7) {
                                Button {
                                    Task { await model.selectReplacementTake(take) }
                                } label: {
                                    Image(systemName: session.selectedTakeID == take.id
                                        ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                .disabled(take.status != .complete)
                                Text("Take \(take.number)")
                                    .fontWeight(.semibold)
                                Text(EntryListView.formatDuration(take.duration))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(take.createdAt.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.tertiary)
                                if take.status == .incomplete {
                                    Text("Incomplete")
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Button("Play") { Task { await model.playReplacementTake(take) } }
                                Button("Play in Context") {
                                    Task { await model.previewReplacementInContext(take) }
                                }
                                .disabled(take.status != .complete)
                                if let url = model.replacementTakeURL(take) {
                                    ShareLink(item: url) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    .help("Export Take \(take.number)")
                                }
                                Button(role: .destructive) {
                                    Task { await model.deleteReplacementTake(take) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Delete Take \(take.number)")
                            }
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                }

                HStack(spacing: 9) {
                    Button("Cancel") { Task { await model.cancelReplacement() } }
                    Button("Change Region…") { showingChangeRegionConfirm = true }
                        .disabled(session.takes.isEmpty)
                    Spacer()
                    Button("Try Again") {
                        Task { await model.startReplacementTake(for: entry, selection: replacementSelection) }
                    }
                    Button("Bake Selected Take…") { showingBakeConfirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.selectedTakeCanBake)
                }
            } else {
                HStack(spacing: 12) {
                    Button("Cancel") { Task { await model.cancelReplacement() } }
                    Spacer()
                    Button("Record a Take") {
                        Task { await model.startReplacementTake(for: entry, selection: replacementSelection) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!replacementSelection.isValidReplacement(ofDuration: trimDuration))
                }
            }
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .padding(.top, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replacement-controls")
    }

    private var replacementTransport: some View {
        let isCapturing = model.recorder.currentEntryPath == entry.relativePath
            && model.recorder.sessionTarget != nil
        return HStack(spacing: 22 * controlScale) {
            AdaptiveSkipButton(
                player: player,
                direction: .backward,
                size: 17 * controlScale
            )

            TransportButton(
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                size: 24 * controlScale,
                help: player.isPlaying ? "Pause preview" : "Play preview"
            ) {
                player.togglePlayPause()
            }
            .accessibilityLabel(player.isPlaying ? "Pause replacement preview" : "Play replacement preview")

            AdaptiveSkipButton(
                player: player,
                direction: .forward,
                size: 17 * controlScale
            )
        }
        .padding(.horizontal, 22 * controlScale)
        .padding(.vertical, 6 * controlScale)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.7), lineWidth: 1))
        .fixedSize()
        .disabled(isCapturing)
        .help(isCapturing ? "Playback is unavailable while recording a replacement take." : "Audition and position the loaded audio")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replacement-playback-transport")
    }

    private var audioDragURL: URL? {
        model.audioURL(for: entry)
    }

    /// Drag-out of the audio file (EXP-3's "plus"): drop the chip on Finder,
    /// Mail, Messages, … to copy the file out of the vault.
    @ViewBuilder
    private var audioDragChip: some View {
        if let audioDragURL {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.tertiary)
                .onDrag { NSItemProvider(contentsOf: audioDragURL) ?? NSItemProvider() }
                .help("Drag out to copy the audio file — or use More → Share Audio…")
                .accessibilityLabel("Drag out audio file")
        }
    }

    /// Replaces the caption row while selecting a range to keep (AUD-3).
    private var trimControls: some View {
        VStack(spacing: 9) {
            Text("Keep \(EntryListView.formatDuration(trimStart)) – "
                + "\(EntryListView.formatDuration(trimEnd)) · "
                + EntryListView.formatDuration(trimSelection.length))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    isTrimming = false
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showingTrimConfirm = true
                } label: {
                    Label("Trim…", systemImage: "scissors")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(!trimSelection.isValidCrop(ofDuration: trimDuration))
                .help(trimSelection.isValidCrop(ofDuration: trimDuration)
                    ? "Crop the audio to the selected range"
                    : "Drag the yellow handles inward to choose what to keep")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.top, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trim-controls")
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let waveform = displayedWaveform {
            WaveformView(peaks: waveform.peaks, progress: player.progress) { fraction in
                player.seek(toFraction: fraction)
            }
            // In trim mode the drag handles own the waveform surface.
            .allowsHitTesting(!isTrimming && !isReplacing)
        } else if let waveformError {
            ContentUnavailableView {
                Label("No Waveform", systemImage: "waveform.slash")
                    .font(.caption)
            } description: {
                Text(waveformError).font(.caption2)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing waveform…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 23 * controlScale) {
            ExtendRecordingButton(
                size: 11 * controlScale,
                blockedReason: model.extensionBlockReason(for: entry)
            ) {
                Task { await model.startExtension(for: entry) }
            }

            speedControl

            AdaptiveSkipButton(
                player: player,
                direction: .backward,
                size: 19 * controlScale
            )

            TransportButton(
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                size: 27 * controlScale,
                help: player.isPlaying ? "Pause (Space)" : "Play (Space)"
            ) {
                player.togglePlayPause()
            }

            AdaptiveSkipButton(
                player: player,
                direction: .forward,
                size: 19 * controlScale
            )

            skipSilenceControl

            trimControl
        }
        .padding(.horizontal, 22 * controlScale)
        .padding(.vertical, 7 * controlScale)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.7), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback-transport")
    }

    /// Persistent rate control on the transport, podcast-app style: the label
    /// always shows the active speed; the menu lists the full ladder.
    private var speedControl: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(
                get: { player.speed },
                set: { player.speed = $0 }
            )) {
                ForEach(PlayerService.speeds, id: \.self) { speed in
                    Text(Self.speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Self.speedLabel(player.speed))
                .font(.system(size: 13 * controlScale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 40 * controlScale, minHeight: 30 * controlScale)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed — press [ for slower, ] for faster, \\ for 1×")
        .accessibilityLabel("Playback speed, \(Self.speedLabel(player.speed))")
        .accessibilityIdentifier("playback-speed-menu")
    }

    private var trimControl: some View {
        TransportButton(
            systemImage: "scissors",
            size: 15 * controlScale,
            help: trimBlockedReason
                ?? (isTrimming ? "Trimming — drag the yellow handles, then press Trim… (T to cancel)"
                               : "Trim — crop the audio to a selected range (T)"),
            tint: isTrimming
                ? AnyShapeStyle(Color.yellow)
                : AnyShapeStyle(trimBlockedReason == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        ) {
            if isTrimming {
                isTrimming = false
            } else if trimBlockedReason == nil {
                isTrimming = true
            }
        }
        .accessibilityLabel("Trim")
        .accessibilityIdentifier("trim-toggle")
    }

    private var skipSilenceControl: some View {
        let selectedSourceUnavailable = player.silenceDetectionMode == .speech
            && !player.silenceDetectionSourceIsReady
        return TransportButton(
            systemImage: player.skipSilence ? "waveform.badge.minus" : "waveform",
            size: 15 * controlScale,
            help: selectedSourceUnavailable
                ? (model.speechTranscriptAvailability(for: entry).explanation
                    ?? "Preparing Speech Transcript silence detection…")
                : player.skipSilence
                ? "Skip Silence: On — skipping pauses longer than "
                    + String(format: "%.1f", SilenceGap.defaultThreshold)
                    + " seconds. Click or press S to turn off."
                : "Skip Silence: Off — click or press S to skip pauses longer than "
                    + String(format: "%.1f", SilenceGap.defaultThreshold)
                    + " seconds.",
            tint: selectedSourceUnavailable
                ? AnyShapeStyle(.tertiary)
                : (player.skipSilence ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        ) {
            if !selectedSourceUnavailable { player.skipSilence.toggle() }
        }
        .disabled(selectedSourceUnavailable)
        .accessibilityLabel("Skip Silence")
        .accessibilityIdentifier("skip-silence-toggle")
    }

    static func speedLabel(_ speed: Float) -> String {
        // Float description is the shortest exact form: "0.75", "1.5", "2.0".
        let text = speed == speed.rounded() ? String(format: "%.0f", speed) : "\(speed)"
        return text + "×"
    }

    static func playheadLabel(_ seconds: Double) -> String {
        let totalCentiseconds = max(0, Int((seconds * 100).rounded(.down)))
        let centiseconds = totalCentiseconds % 100
        let totalSeconds = totalCentiseconds / 100
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let wholeSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%02d", hours, minutes, wholeSeconds, centiseconds)
        }
        return String(format: "%02d:%02d.%02d", minutes, wholeSeconds, centiseconds)
    }
}

/// The extension control is intentionally quiet at rest: a grayscale record
/// dot at the leading edge of the pill, becoming red only when hovered.
private struct ExtendRecordingButton: View {
    let size: CGFloat
    let blockedReason: RecordingExtensionBlockReason?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "circle.fill")
                .font(.system(size: size))
                .foregroundStyle(
                    blockedReason == nil && hovering ? Color.red : Color.secondary
                )
                .frame(width: size + 16, height: size + 14)
                .background(
                    Circle()
                        .fill(.primary.opacity(hovering ? 0.08 : 0))
                        .frame(width: size + 14, height: size + 14)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blockedReason != nil)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(blockedReason?.explanation ?? "Extend Recording")
        .accessibilityLabel("Extend Recording")
        .accessibilityIdentifier("extend-recording-button")
    }
}

/// Transport icon button: clickable area extends well past the glyph, with a
/// soft circular highlight on hover so the target reads as a button.
private struct TransportButton: View {
    let systemImage: String
    let size: CGFloat
    let help: String
    var tint = AnyShapeStyle(.primary)
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 14)
                .background(
                    Circle()
                        .fill(.primary.opacity(hovering ? 0.08 : 0))
                        .frame(width: size + 14, height: size + 14)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}
