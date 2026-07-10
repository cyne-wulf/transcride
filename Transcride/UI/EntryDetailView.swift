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

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                entryDetail(entry)
                    .task(id: taskKey(for: entry)) {
                        if loadedEntryPath != entry.relativePath {
                            document = nil
                            original = nil
                            loadedEntryPath = nil
                            model.player.setTranscriptForSilenceSkipping(nil)
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

            if entry.hasAudio {
                PlaybackSection(entry: entry)
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show Info") { showingInfo = true }
            Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
        }
        .toolbar {
            if entry.hasAudio {
                ToolbarItem {
                    PlaybackOptionsButton()
                }
                ToolbarItem {
                    Button {
                        showingRetranscribe = true
                    } label: {
                        Label("Retranscribe", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Retranscribe with a different model")
                }
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
                // No engine progress yet means the model is still loading
                // (first load compiles for the Neural Engine — minutes).
                if (queue.progressByItemID[item.id] ?? 0) <= 0.001 {
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

    @State private var waveform: WaveformData?
    @State private var waveformError: String?
    @State private var sectionWidth: CGFloat = 420

    private var player: PlayerService { model.player }

    /// Controls grow modestly with the detail column while preserving the
    /// compact proportions of Voice Memos' lower playback shelf.
    private var controlScale: CGFloat {
        min(max(sectionWidth / 620, 0.9), 1.15)
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
        .task(id: "\(entry.relativePath)|\(entry.audioFileName ?? "")") {
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
    }

    private var waveformShelf: some View {
        VStack(spacing: 5) {
            waveformArea
                .frame(height: 56 * controlScale)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack {
                Text("0:00")
                Spacer()
                Text(EntryListView.formatDuration(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let waveform {
            WaveformView(peaks: waveform.peaks, progress: player.progress) { fraction in
                player.seek(toFraction: fraction)
            }
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
        }
        .padding(.horizontal, 22 * controlScale)
        .padding(.vertical, 7 * controlScale)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.7), lineWidth: 1))
        .fixedSize()
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
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.primary)
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

/// Voice Memos-style playback panel in the detail toolbar. Playback rate and
/// Skip Silence live together here instead of competing with the transport.
private struct PlaybackOptionsButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions.toggle()
        } label: {
            Label("Playback Controls", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("Playback Controls")
        .accessibilityIdentifier("playback-controls-menu")
        .help("Playback speed and Skip Silence")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Playback Controls")
                    .font(.headline)

                HStack(spacing: 12) {
                    Label("Playback Speed", systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Picker("Playback Speed", selection: Binding(
                        get: { model.player.speed },
                        set: { model.player.speed = $0 }
                    )) {
                        ForEach(PlayerService.speeds, id: \.self) { speed in
                            Text(PlaybackSection.speedLabel(speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 92)
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { model.player.skipSilence },
                    set: { model.player.skipSilence = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip Silence")
                        Text("Jump pauses longer than \(SilenceGap.defaultThreshold, specifier: "%.1f") seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
