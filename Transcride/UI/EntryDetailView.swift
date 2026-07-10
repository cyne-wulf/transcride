import SwiftUI

/// Voice Memos-style detail workbench: transcript first, playback shelf below,
/// with entry metadata tucked behind Show Info.
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?
    @State private var original: TranscriptOriginal?
    @State private var loadedEntryPath: RelativePath?
    @State private var showingInfo = false
    @State private var showingRetranscribe = false
    // Payload separate from isPresented — SwiftUI clears the presentation
    // binding before running dialog button actions.
    @State private var showingDeleteAudio = false
    @State private var deleteAudioByteSize: Int64?
    @State private var isTrimming = false
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
                                loadedEntryPath = nil
                                isTrimming = false
                                model.player.setTranscriptForSilenceSkipping(nil)
                            }
                        }
                        guard let content = await model.readTranscriptContent(for: entry),
                              !Task.isCancelled,
                              model.selectedEntryID == entry.relativePath else { return }
                        document = content.edited
                        original = content.original
                        loadedEntryPath = entry.relativePath
                        model.player.setTranscriptForSilenceSkipping(content.original)
                    }
            } else {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "waveform",
                    description: Text("Select an entry to see its transcript.")
                )
            }
        }
    }

    /// Reload for entry/title changes, external vault writes, or a landed
    /// transcription. Deliberately exclude `entry.snippet`: autosave refreshes
    /// that list preview, and reloading the editor from an earlier debounced
    /// save could otherwise overwrite newer unsaved keystrokes.
    private func taskKey(for entry: Entry) -> String {
        "\(entry.relativePath)|\(entry.title ?? "")|external:\(model.externalVaultRevision)|transcription:\(model.transcriptRevision)"
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
                    TranscriptWorkbenchView(entry: entry, original: original, document: $document)
                        .frame(maxWidth: 900, maxHeight: .infinity)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 36)
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
        .contextMenu {
            Button(entry.favorite ? "Unfavorite" : "Favorite") {
                Task { await model.toggleFavorite(for: entry) }
            }
            Button("Duplicate Entry") { Task { await model.duplicateEntry(entry) } }
            Divider()
            Button("Show Info") { showingInfo = true }
            Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
            if entry.hasAudio || entry.audioDeleted {
                Divider()
                Button("Delete Audio…", role: .destructive) { promptDeleteAudio(entry) }
                    .disabled(!canDeleteAudio(entry))
            }
        }
        .toolbar {
            ToolbarItem {
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
            if entry.hasAudio || entry.audioDeleted {
                ToolbarItem {
                    Button {
                        showingRetranscribe = true
                    } label: {
                        Label("Retranscribe", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!entry.hasAudio)
                    .help(entry.audioUnavailableExplanation
                        ?? "Retranscribe with a different model")
                }
            }
            ToolbarItem {
                Menu {
                    if entry.hasAudio || entry.audioDeleted {
                        Button("Trim Audio…") { isTrimming = true }
                            .disabled(!canTrim(entry))
                            .help(entry.audioUnavailableExplanation
                                ?? "Select the range of audio to keep")
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
            ToolbarItem {
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
            ToolbarItem {
                Button {
                    model.revealInFinder(relativePath: entry.relativePath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
            }
        }
        .sheet(isPresented: $showingRetranscribe) {
            RetranscribeSheet(entry: entry)
        }
        .sheet(isPresented: $showingExport) {
            ExportMarkdownSheet(entry: entry, original: original, document: document)
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
        entry.hasAudio && model.recorder.currentEntryPath != entry.relativePath
    }

    // MARK: - Trim (AUD-3)

    /// Trimming needs stable audio: not mid-recording and not being read by a
    /// queued or running transcription.
    private func canTrim(_ entry: Entry) -> Bool {
        canDeleteAudio(entry)
            && model.transcriptionQueue?.items
                .contains(where: { $0.entryRelativePath == entry.relativePath }) != true
    }

    private func promptDeleteAudio(_ entry: Entry) {
        Task {
            deleteAudioByteSize = await model.audioFileByteSize(for: entry)
            showingDeleteAudio = true
        }
    }

    private var deleteAudioMessage: String {
        let size = deleteAudioByteSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "its disk space"
        return "This frees \(size). The transcript is kept, and the audio "
            + "can be restored from Recently Deleted for \(TrashStore.retentionDays) days."
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

    // MARK: - Info popover

    @ViewBuilder
    private func infoPopover(_ entry: Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            infoRow("Created", entry.created.formatted(date: .complete, time: .standard))
            if let duration = entry.duration {
                infoRow("Duration", EntryListView.formatDuration(duration))
            }
            infoRow("Audio", entry.hasAudio ? "Yes" : (entry.audioDeleted ? "Deleted" : "None"))
            if let source = document?.source {
                infoRow("Source", source)
            }
            if let engine = document?.engine {
                infoRow("Engine", engine)
            }
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

    private var player: PlayerService { model.player }

    /// Best-known audio length for trim math (the waveform cache carries the
    /// decoded duration; the player's may still be loading).
    private var trimDuration: Double {
        waveform?.duration ?? (player.duration > 0 ? player.duration : entry.duration ?? 0)
    }

    private var trimSelection: TrimSelection {
        TrimSelection(start: trimStart, end: trimEnd)
    }

    /// Why trim mode can't start right now; nil when it can.
    private var trimBlockedReason: String? {
        if model.recorder.currentEntryPath == entry.relativePath {
            return "Stop the recording before trimming."
        }
        if model.transcriptionQueue?.items
            .contains(where: { $0.entryRelativePath == entry.relativePath }) == true {
            return "Wait for the transcription to finish before trimming."
        }
        if trimDuration <= TrimSelection.minimumKeptSeconds {
            return "This audio is too short to trim."
        }
        return nil
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
            waveformShelf

            Text(Self.playheadLabel(player.currentTime))
                .font(.system(size: 36 * controlScale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            transport
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            sectionWidth = width
        }
        .task(id: "\(entry.relativePath)|\(entry.audioFileName ?? "")|audio:\(model.audioRevision)") {
            if let url = model.audioURL(for: entry) {
                player.load(url: url, knownDuration: entry.duration)
            }
            waveform = nil
            waveformError = nil
            do {
                waveform = try await model.waveform(for: entry)
            } catch is CancellationError {
                // switched away mid-generation; next open restarts it
            } catch {
                waveformError = error.localizedDescription
            }
        }
        .onChange(of: isTrimming) { _, trimming in
            guard trimming else { return }
            guard trimBlockedReason == nil else {
                isTrimming = false
                return
            }
            trimStart = 0
            trimEnd = trimDuration
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
    }

    private var trimConfirmMessage: String {
        "This keeps \(EntryListView.formatDuration(trimSelection.length)) of "
            + "\(EntryListView.formatDuration(trimDuration)) and re-transcribes the audio "
            + "(a hand-edited note is never overwritten). The original audio can be restored "
            + "from Recently Deleted for \(TrashStore.retentionDays) days."
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
                        TrimSelectionOverlay(start: $trimStart, end: $trimEnd, duration: trimDuration)
                            .padding(.horizontal, 8)
                    }
                }

            if isTrimming {
                trimControls
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
        HStack(spacing: 12) {
            Button("Cancel") { isTrimming = false }
            Spacer()
            Text("Keep \(EntryListView.formatDuration(trimStart)) – "
                + "\(EntryListView.formatDuration(trimEnd)) · "
                + EntryListView.formatDuration(trimSelection.length))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Trim…") { showingTrimConfirm = true }
                .disabled(!trimSelection.isValidCrop(ofDuration: trimDuration))
                .help(trimSelection.isValidCrop(ofDuration: trimDuration)
                    ? "Crop the audio to the selected range"
                    : "Drag the yellow handles inward to choose what to keep")
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trim-controls")
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let waveform {
            WaveformView(peaks: waveform.peaks, progress: player.progress) { fraction in
                player.seek(toFraction: fraction)
            }
            // In trim mode the drag handles own the waveform surface.
            .allowsHitTesting(!isTrimming)
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
            speedControl

            TransportButton(
                systemImage: "gobackward.15", size: 19 * controlScale, help: "Back 15 seconds"
            ) {
                player.skip(-15)
            }

            TransportButton(
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                size: 27 * controlScale,
                help: player.isPlaying ? "Pause (Space)" : "Play (Space)"
            ) {
                player.togglePlayPause()
            }

            TransportButton(
                systemImage: "goforward.15", size: 19 * controlScale, help: "Forward 15 seconds"
            ) {
                player.skip(15)
            }

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
                ?? (isTrimming ? "Trimming — drag the yellow handles, then press Trim…"
                               : "Trim — crop the audio to a selected range"),
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
        TransportButton(
            systemImage: player.skipSilence ? "waveform.badge.minus" : "waveform",
            size: 15 * controlScale,
            help: player.skipSilence
                ? "Skip Silence: On — skipping pauses longer than "
                    + String(format: "%.1f", SilenceGap.defaultThreshold)
                    + " seconds. Click to turn off."
                : "Skip Silence: Off — click to skip pauses longer than "
                    + String(format: "%.1f", SilenceGap.defaultThreshold)
                    + " seconds.",
            tint: player.skipSilence ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
        ) {
            player.skipSilence.toggle()
        }
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

