import SwiftUI

/// Read-only detail surface for Recently Deleted. It deliberately receives no
/// live `Entry`, so editing and entry mutation controls cannot target `.trash`.
struct TrashPreviewView: View {
    @Environment(AppModel.self) private var model
    var onPlaybackWidthRequirementChange: (PlaybackWidthRequirement) -> Void = { _ in }

    @State private var preview: TrashPreview?
    @State private var loadingItemID: String?
    @State private var transcriptLayer = TranscriptLayer.edited

    private enum TranscriptLayer: String, CaseIterable, Identifiable {
        case edited = "Note"
        case original = "Original"

        var id: Self { self }
    }

    var body: some View {
        Group {
            if let item = model.selectedTrashItem {
                if let preview, preview.item.id == item.id {
                    previewBody(preview)
                } else {
                    ProgressView("Loading deleted item…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No Deleted Item Selected",
                    systemImage: "trash",
                    description: Text("Select an item to preview what is recoverable.")
                )
            }
        }
        .task(id: model.selectedTrashItemID) {
            await loadSelectedPreview()
        }
    }

    private func loadSelectedPreview() async {
        guard let item = model.selectedTrashItem else {
            preview = nil
            loadingItemID = nil
            return
        }
        loadingItemID = item.id
        preview = nil
        let loaded = await model.trashPreview(for: item)
        guard !Task.isCancelled,
              loadingItemID == item.id,
              model.selectedTrashItemID == item.id else { return }
        transcriptLayer = loaded?.document != nil ? .edited : .original
        preview = loaded
    }

    @ViewBuilder
    private func previewBody(_ preview: TrashPreview) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header(preview)

                switch preview.kind {
                case .entry:
                    entryContent(preview)
                case .audio:
                    audioVersionContent(preview)
                case .folder:
                    unavailableContent(
                        title: "Deleted Folder",
                        systemImage: "folder",
                        description: preview.summary
                    )
                case .file:
                    unavailableContent(
                        title: "Preview Unavailable",
                        systemImage: "doc",
                        description: preview.summary
                    )
                case .unavailable:
                    unavailableContent(
                        title: "Item Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: preview.summary
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if preview.audioURL != nil {
                    TrashAudioPreview(
                        preview: preview,
                        availableHeight: proxy.size.height,
                        availablePlayerWidth: max(0, proxy.size.width - 56),
                        onWidthRequirementChange: onPlaybackWidthRequirementChange
                    )
                }
            }
        }
    }

    private func header(_ preview: TrashPreview) -> some View {
        VStack(spacing: 5) {
            Text(preview.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Text("Deleted \(preview.item.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("·").foregroundStyle(.tertiary)
                Text("was in \(locationDescription(preview.item))")
                if let duration = preview.duration {
                    Text("·").foregroundStyle(.tertiary)
                    Text(EntryListView.formatDuration(duration))
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func entryContent(_ preview: TrashPreview) -> some View {
        if preview.document != nil || preview.original != nil {
            VStack(spacing: 0) {
                if preview.document != nil, preview.original != nil {
                    Picker("Transcript Layer", selection: $transcriptLayer) {
                        ForEach(TranscriptLayer.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .padding(.bottom, 8)
                }

                ScrollView {
                    Text(transcriptText(preview))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableContent(
                title: "No Transcript Preview",
                systemImage: "text.badge.xmark",
                description: preview.transcriptUnavailableReason
            )
        }
    }

    private func audioVersionContent(_ preview: TrashPreview) -> some View {
        unavailableContent(
            title: "Audio Version",
            systemImage: "waveform",
            description: preview.summary
        )
    }

    private func unavailableContent(
        title: String, systemImage: String, description: String?
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description { Text(description) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptText(_ preview: TrashPreview) -> String {
        if transcriptLayer == .edited, let document = preview.document {
            return document.body
        }
        if let original = preview.original {
            return original.segments.map { segment in
                let text = TranscriptOriginal.text(of: segment)
                return segment.speaker.map { "\($0): \(text)" } ?? text
            }.joined(separator: "\n\n")
        }
        return preview.document?.body ?? ""
    }

    private func locationDescription(_ item: TrashItem) -> String {
        let parent = item.originalPath.parentRelativePath
        return parent.isEmpty ? "Vault Root" : parent
    }
}

private struct TrashAudioPreview: View {
    @Environment(AppModel.self) private var model
    let preview: TrashPreview
    let availableHeight: CGFloat
    let availablePlayerWidth: CGFloat
    let onWidthRequirementChange: (PlaybackWidthRequirement) -> Void

    @State private var width: CGFloat = 420
    @State private var transportWidth: CGFloat = 0

    private var player: PlayerService { model.player }
    private var scale: CGFloat {
        min(max(width / 620, 0.9), 1.15) * (availableHeight < 520 ? 0.84 : 1)
    }
    private var widthRequirement: PlaybackWidthRequirement {
        PlaybackWidthRequirement(
            availableWidth: availablePlayerWidth,
            requiredWidth: transportWidth,
            detailHorizontalInsets: 56
        )
    }

    var body: some View {
        VStack(spacing: 8 * scale) {
            waveform
                .frame(height: 56 * scale)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack {
                Text("0:00")
                Spacer()
                Text(Self.timeLabel(player.duration > 0 ? player.duration : preview.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(Self.playheadLabel(player.currentTime))
                .font(.system(size: 36 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            transport
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    transportWidth = width
                }
        }
        .onChange(of: widthRequirement, initial: true) { _, requirement in
            onWidthRequirementChange(requirement)
        }
        .onDisappear {
            onWidthRequirementChange(PlaybackWidthRequirement())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            self.width = width
        }
        .task(id: preview.item.id) {
            guard preview.audioUnavailableReason == nil, let audioURL = preview.audioURL else {
                return
            }
            player.load(url: audioURL, knownDuration: preview.duration)
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if let data = preview.waveform {
            WaveformView(peaks: data.peaks, progress: player.progress) { fraction in
                player.seek(toFraction: fraction)
            }
        } else if let reason = preview.audioUnavailableReason {
            ContentUnavailableView {
                Label("Audio Unavailable", systemImage: "waveform.slash")
                    .font(.caption)
            } description: {
                Text(reason).font(.caption2)
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
        HStack(spacing: 23 * scale) {
            Menu {
                Picker("Playback Speed", selection: Binding(
                    get: { player.speed }, set: { player.speed = $0 }
                )) {
                    ForEach(PlayerService.speeds, id: \.self) { speed in
                        Text(Self.speedLabel(speed)).tag(speed)
                    }
                }
            } label: {
                Text(Self.speedLabel(player.speed))
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            AdaptiveSkipButton(
                player: player,
                direction: .backward,
                size: 19 * scale
            )

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27 * scale))
            }
            .buttonStyle(.plain)
            .disabled(preview.audioUnavailableReason != nil)
            .help(player.isPlaying ? "Pause" : "Play")

            AdaptiveSkipButton(
                player: player,
                direction: .forward,
                size: 19 * scale
            )
        }
        .padding(.horizontal, 22 * scale)
        .padding(.vertical, 7 * scale)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.7), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trash-preview-transport")
    }

    private static func speedLabel(_ speed: Float) -> String {
        speed == speed.rounded()
            ? String(format: "%.0f×", speed)
            : String(format: speed == 0.75 ? "%.2f×" : "%.1f×", speed)
    }

    private static func playheadLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
