import SwiftUI

/// Milestone-1 placeholder detail view. The transcript body is the first-class
/// content; entry metadata is tucked behind "Show Info" (right-click or the
/// toolbar ⓘ button).
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?
    @State private var showingInfo = false
    @State private var showingRetranscribe = false

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                entryDetail(entry)
                    .task(id: taskKey(for: entry)) {
                        document = await model.readTranscript(for: entry)
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

    /// Reload when a different entry is selected, the file changes on disk,
    /// or a transcription lands (transcriptRevision — our own writes are
    /// invisible to the FSEvents watcher).
    private func taskKey(for entry: Entry) -> String {
        "\(entry.relativePath)|\(entry.title ?? "")|\(entry.snippet)|\(model.transcriptRevision)"
    }

    @ViewBuilder
    private func entryDetail(_ entry: Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text(entry.created.formatted(date: .abbreviated, time: .shortened))
                        if let duration = entry.duration {
                            Text("·")
                            Text(EntryListView.formatDuration(duration))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if entry.hasAudio {
                    PlaybackSection(entry: entry)
                        .padding(.vertical, 8)
                }

                if let document, !document.body.isEmpty {
                    Text(document.body)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if entry.hasTranscript {
                    Text("This entry’s transcript has no text yet — check the transcription queue in the toolbar.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No transcript file in this entry yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Show Info") { showingInfo = true }
                Button("Reveal in Finder") { model.revealInFinder(relativePath: entry.relativePath) }
            }
        }
        .toolbar {
            if entry.hasAudio {
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

    /// Transport controls grow with the window (1× at 420pt up to 1.5×) so
    /// they stay comfortable to click in a large window.
    private var controlScale: CGFloat {
        min(max(sectionWidth / 420, 1.0), 1.5)
    }

    var body: some View {
        VStack(spacing: 10 * controlScale) {
            waveformArea
                .frame(height: 72 * controlScale)
                .frame(maxWidth: .infinity)
            transport
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
        HStack(spacing: 14 * controlScale) {
            Text(EntryListView.formatDuration(player.currentTime))
                .font(.system(size: 11 * controlScale).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44 * controlScale, alignment: .leading)

            Spacer()

            TransportButton(
                systemImage: "gobackward.15", size: 17 * controlScale, help: "Back 15 seconds"
            ) {
                player.skip(-15)
            }

            TransportButton(
                systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                size: 34 * controlScale,
                help: player.isPlaying ? "Pause (Space)" : "Play (Space)",
                isProminent: true
            ) {
                player.togglePlayPause()
            }

            TransportButton(
                systemImage: "goforward.15", size: 17 * controlScale, help: "Forward 15 seconds"
            ) {
                player.skip(15)
            }

            Spacer()

            speedMenu

            Text(EntryListView.formatDuration(player.duration))
                .font(.system(size: 11 * controlScale).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44 * controlScale, alignment: .trailing)
        }
    }

    private var speedMenu: some View {
        SpeedChip(scale: controlScale) {
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
        }
    }

    static func speedLabel(_ speed: Float) -> String {
        // Float description is the shortest exact form: "0.75", "1.5", "2.0".
        let text = speed == speed.rounded() ? String(format: "%.0f", speed) : "\(speed)"
        return text + "×"
    }
}

/// Transport icon button: clickable area extends well past the glyph, with a
/// soft circular highlight on hover so the target reads as a button.
private struct TransportButton: View {
    let systemImage: String
    let size: CGFloat
    let help: String
    var isProminent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(isProminent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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

/// Bordered capsule chip for the speed menu: looks like a button, so the
/// clickable area is obvious.
private struct SpeedChip<Content: View, Label: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6 * scale) {
                label
                    .font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16 * scale)
            .frame(minWidth: 64 * scale)
            .frame(height: 32 * scale)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            Capsule()
                .fill(.background.opacity(hovering ? 0.9 : 0.6))
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Playback speed (pitch preserved)")
    }
}
