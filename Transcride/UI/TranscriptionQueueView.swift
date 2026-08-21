import SwiftUI

/// Always-discoverable toolbar button + popover for AI activity (TRN-3 +
/// PRD-9): queued transcriptions and running summary generations share the
/// one ring. Active work appears as a filling progress ring around the item
/// count; the idle popover explains that nothing is waiting. Each row shows
/// the entry, model, and state, with retry and remove/cancel actions.
struct TranscriptionQueueButton: View {
    @Environment(AppModel.self) private var model
    let queue: TranscriptionQueue
    var onOpen: () -> Void = {}

    @State private var showingQueue = false

    /// Summary jobs with visible state (generating or failed), stable order.
    private var summaryJobs: [(path: RelativePath, phase: SummaryGenerationController.Phase)] {
        model.summaryController.phases
            .filter { $0.value != .idle }
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, phase: $0.value) }
    }

    /// The running item's progress; nil while everything is still waiting.
    /// Transcription wins the ring when both kinds of work are active — it's
    /// the longer job; a summary's fraction fills in otherwise.
    private var runningFraction: Double? {
        if let running = queue.items.first(where: { $0.state == .running }) {
            return queue.progressByItemID[running.id] ?? 0
        }
        return summaryJobs.lazy.compactMap { $0.phase.fraction }.first
    }

    private var hasFailure: Bool {
        queue.items.contains { $0.state == .failed }
            || summaryJobs.contains { $0.phase.isFailed }
    }

    private var itemCount: Int {
        queue.items.count + summaryJobs.count
    }

    var body: some View {
        Button {
            onOpen()
            showingQueue.toggle()
        } label: {
            if hasFailure {
                Label("AI Queue", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                QueueProgressRing(fraction: runningFraction, count: itemCount)
            }
        }
        .accessibilityLabel("Transcription and summary queue")
        .help("Transcription and summary queue")
        .onChange(of: model.queuePopoverRequestRevision) { _, _ in
            // View → Transcription Queue opens the same toolbar popover.
            onOpen()
            showingQueue = true
        }
        .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
            TranscriptionQueuePopover(queue: queue)
        }
    }
}

/// Xcode/Safari-style toolbar activity ring: the accent arc fills with the
/// running item's progress (a sliver while waiting, so it always reads as
/// pending work) around the number of queued items.
private struct QueueProgressRing: View {
    /// Running item's 0…1 progress; nil when no item is running yet.
    var fraction: Double?
    var count: Int

    var body: some View {
        let visibleFraction = count == 0 ? 0 : max(0.04, fraction ?? 0.04)
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: visibleFraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            Text("\(count)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(width: 16, height: 16)
        .padding(2)
    }
}

private struct TranscriptionQueuePopover: View {
    @Environment(AppModel.self) private var model
    let queue: TranscriptionQueue

    /// Summary jobs with visible state (generating or failed), stable order.
    private var summaryJobs: [(path: RelativePath, phase: SummaryGenerationController.Phase)] {
        model.summaryController.phases
            .filter { $0.value != .idle }
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, phase: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AI Queue")
                .font(.headline)
                .padding(.bottom, 8)
            if queue.items.isEmpty, summaryJobs.isEmpty {
                Text("Nothing waiting for transcription or summarizing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(queue.items) { item in
                    itemRow(item)
                    if item.id != queue.items.last?.id || !summaryJobs.isEmpty {
                        Divider().padding(.vertical, 8)
                    }
                }
                ForEach(summaryJobs, id: \.path) { job in
                    summaryRow(job.path, phase: job.phase)
                    if job.path != summaryJobs.last?.path {
                        Divider().padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private func summaryRow(_ path: RelativePath, phase: SummaryGenerationController.Phase) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snapshot?.entry(withID: path)?.displayTitle ?? path.lastComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(SummaryModelCatalog.preferredModel().displayName) · summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch phase {
                case .generating(let part, let total, let fraction):
                    HStack(spacing: 6) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                        if total > 1 {
                            Text("Part \(part) of \(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await model.retrySummary(forEntryAt: path) }
                    }
                    .controlSize(.small)
                case .idle:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if phase.isGenerating {
                    model.summaryController.cancel(for: path)
                } else {
                    model.summaryController.clearFailure(for: path)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(phase.isGenerating ? "Cancel summary" : "Dismiss")
        }
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
                    if queue.speakerPhaseItemIDs.contains(item.id) {
                        HStack(spacing: 6) {
                            ProgressView(value: queue.progressByItemID[item.id] ?? 0)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                            Text("Detecting speakers…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    } else if (queue.progressByItemID[item.id] ?? 0) <= 0.001 {
                        // No engine progress yet means the model is still
                        // loading (first load compiles for the Neural
                        // Engine — minutes).
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Preparing model…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(value: queue.progressByItemID[item.id] ?? 0)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                case .failed:
                    Text(item.errorMessage ?? "Transcription failed.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") { queue.retry(itemID: item.id) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                queue.remove(itemID: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(item.state == .running ? "Cancel transcription" : "Remove from queue")
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
