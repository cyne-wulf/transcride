import SwiftUI

/// Toolbar button + popover for the transcription queue (TRN-3). The button
/// only appears while the queue has items; each row shows the entry, model,
/// and state, with retry on failures and remove on anything not running.
struct TranscriptionQueueButton: View {
    @Environment(AppModel.self) private var model
    let queue: TranscriptionQueue

    @State private var showingQueue = false

    private var hasRunning: Bool {
        queue.items.contains { $0.state == .running }
    }

    private var hasFailure: Bool {
        queue.items.contains { $0.state == .failed }
    }

    var body: some View {
        Button {
            showingQueue.toggle()
        } label: {
            Label(
                "Transcription Queue",
                systemImage: hasFailure ? "exclamationmark.arrow.triangle.2.circlepath"
                    : "arrow.triangle.2.circlepath"
            )
            .symbolEffect(.pulse, isActive: hasRunning)
            .foregroundStyle(hasFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
        .help("Transcription queue")
        .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
            TranscriptionQueuePopover(queue: queue)
        }
    }
}

private struct TranscriptionQueuePopover: View {
    @Environment(AppModel.self) private var model
    let queue: TranscriptionQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcription Queue")
                .font(.headline)
                .padding(.bottom, 8)
            if queue.items.isEmpty {
                Text("Nothing waiting for transcription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(queue.items) { item in
                    itemRow(item)
                    if item.id != queue.items.last?.id {
                        Divider().padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private func itemRow(_ item: TranscriptionQueueItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entryTitle(item))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(modelName(item) + (item.isRetranscribe ? " · retranscribe" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch item.state {
                case .waiting:
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: queue.progressByItemID[item.id] ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                case .failed:
                    Text(item.errorMessage ?? "Transcription failed.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") { queue.retry(itemID: item.id) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state != .running {
                Button {
                    queue.remove(itemID: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
    }

    /// Entries can be renamed (auto-title) while queued; resolve the current
    /// title from the snapshot, falling back to the folder name.
    private func entryTitle(_ item: TranscriptionQueueItem) -> String {
        model.snapshot?.entry(withID: item.entryRelativePath)?.displayTitle
            ?? item.entryRelativePath.lastComponent
    }

    private func modelName(_ item: TranscriptionQueueItem) -> String {
        ModelCatalog.info(forID: item.modelID)?.displayName ?? item.modelID
    }
}
