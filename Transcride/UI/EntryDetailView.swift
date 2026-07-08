import SwiftUI

/// Milestone-1 placeholder detail view. The transcript body is the first-class
/// content; entry metadata is tucked behind "Show Info" (right-click or the
/// toolbar ⓘ button).
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    @State private var document: FrontmatterDocument?
    @State private var showingInfo = false

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

    /// Reload when a different entry is selected or the file changes on disk.
    private func taskKey(for entry: Entry) -> String {
        "\(entry.relativePath)|\(entry.title ?? "")|\(entry.snippet)"
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
                    Text("This entry’s transcript has no text yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No transcript file in this entry yet — transcription arrives in a later milestone.")
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

    private var player: PlayerService { model.player }

    var body: some View {
        VStack(spacing: 10) {
            waveformArea
                .frame(height: 72)
                .frame(maxWidth: .infinity)
            transport
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
        HStack(spacing: 14) {
            Text(EntryListView.formatDuration(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            Spacer()

            Button {
                player.skip(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help("Back 15 seconds")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")

            Button {
                player.skip(15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help("Forward 15 seconds")

            Spacer()

            speedMenu

            Text(EntryListView.formatDuration(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var speedMenu: some View {
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
                .font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed (pitch preserved)")
    }

    static func speedLabel(_ speed: Float) -> String {
        // Float description is the shortest exact form: "0.75", "1.5", "2.0".
        let text = speed == speed.rounded() ? String(format: "%.0f", speed) : "\(speed)"
        return text + "×"
    }
}
