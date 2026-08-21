import Foundation
import Observation

/// Per-entry summary-generation state for the workbench. Generation is
/// user-initiated only, one job per entry; the finished summary is written
/// atomically by the vault service, so a failed or cancelled run never
/// touches a prior summary.
@MainActor
@Observable
final class SummaryGenerationController {
    enum Phase: Equatable {
        case idle
        case generating(part: Int, total: Int, fraction: Double)
        case failed(String)

        var isGenerating: Bool {
            if case .generating = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        /// Overall 0…1 progress while generating; nil otherwise.
        var fraction: Double? {
            if case .generating(_, _, let fraction) = self { return fraction }
            return nil
        }
    }

    /// A job's live pointer at its entry. Renames (user, transcription
    /// auto-title, summary title) update it via `repointItems`, so a running
    /// job always reads and writes state under the entry's current path.
    /// Main-actor isolation is what makes it safely capturable by the
    /// engine's `@Sendable` progress closure.
    @MainActor
    private final class JobToken {
        var path: RelativePath
        var task: Task<Void, Never>?

        init(path: RelativePath) {
            self.path = path
        }
    }

    private(set) var phases: [RelativePath: Phase] = [:]
    private var jobs: [RelativePath: JobToken] = [:]
    /// Entry whose generation just finished, pending reveal in the workbench.
    /// The AI title rename recreates the detail pane's workbench view (fresh
    /// @State), so "show the finished summary" must outlive the view — it
    /// lives here and is consumed once by whichever workbench loads next.
    private var pendingReveal: RelativePath?
    /// Bumped on every summary write; views reload the sidecar off this key.
    private(set) var summaryRevision = 0
    /// Set by AppModel: applies an AI-proposed entry title through the
    /// canonical rename bookkeeping (eligibility-checked there, best-effort).
    /// The third argument is the PREVIOUS generation's proposed title — read
    /// before the new sidecar overwrote it, so the eligibility policy can
    /// recognize an entry still carrying a prior AI title.
    var onTitleProposed: ((_ path: RelativePath, _ title: String, _ previousTitle: String?) async -> Void)?

    func phase(for path: RelativePath) -> Phase {
        phases[path] ?? .idle
    }

    func generate(
        entryPath: RelativePath,
        document: FrontmatterDocument?,
        original: TranscriptOriginal?,
        using service: VaultService
    ) {
        guard jobs[entryPath] == nil else { return }
        guard let source = SummarySourceSelector.source(document: document, original: original)
        else {
            phases[entryPath] = .failed("There is no transcript to summarize yet.")
            return
        }
        let model = SummaryModelCatalog.preferredModel()
        guard let engine = SummarizationEngine.engine(forModelInfoID: model.id) else {
            phases[entryPath] = .failed("Unknown summary model.")
            return
        }

        phases[entryPath] = .generating(part: 0, total: 1, fraction: 0)
        let token = JobToken(path: entryPath)
        // Strong capture is deliberate: the controller is app-lifetime and
        // the job must be able to record its own completion.
        let task = Task {
            var proposedTitle: String?
            var previousTitle: String?
            do {
                let output = try await engine.summarize(text: source.text) { progress in
                    Task { @MainActor in
                        guard self.phase(for: token.path).isGenerating else { return }
                        self.phases[token.path] = .generating(
                            part: progress.part, total: progress.total,
                            fraction: progress.fraction
                        )
                    }
                }
                let (title, body) = SummaryPrompt.extractTitle(from: output)
                previousTitle = ((try? await service.loadSummary(atEntryPath: token.path)) ?? nil)?
                    .summaryTitle
                let summary = SummaryDocument.make(
                    body: body,
                    modelID: model.id,
                    sourceLayer: source.layer,
                    fingerprint: SummaryFingerprint.fingerprint(of: source.text),
                    generated: Date(),
                    title: title
                )
                try await service.writeGeneratedSummary(summary, atEntryPath: token.path)
                self.phases[token.path] = .idle
                self.pendingReveal = token.path
                self.noteSaved()
                proposedTitle = title
            } catch is CancellationError {
                self.phases[token.path] = .idle
            } catch {
                self.phases[token.path] = .failed(error.localizedDescription)
            }
            self.jobs[token.path] = nil
            // The rename runs only after the job released its slot, so the
            // repoint it triggers cannot strand a finished job under a new
            // path and block future generations.
            // The cancellation check also fences a vault switch: `reset()`
            // cancels this task, and a write that slipped through between
            // checkpoints must not run the title callback against whatever
            // vault is current by then.
            if let proposedTitle, !Task.isCancelled {
                await self.onTitleProposed?(token.path, proposedTitle, previousTitle)
            }
        }
        token.task = task
        jobs[entryPath] = token
    }

    func cancel(for path: RelativePath) {
        jobs[path]?.task?.cancel()
    }

    func clearFailure(for path: RelativePath) {
        if case .failed = phase(for: path) { phases[path] = .idle }
    }

    /// Follows an entry rename or a folder rename/move so phase state and
    /// running jobs stay attached to entries under their new paths.
    /// Prefix-aware like `TranscriptionQueue.repointItems`: moving a folder
    /// repoints every descendant entry.
    func repointItems(from oldPath: RelativePath, to newPath: RelativePath) {
        guard oldPath != newPath else { return }
        func repointed(_ path: RelativePath) -> RelativePath? {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return nil
        }
        for (path, phase) in phases {
            guard let moved = repointed(path) else { continue }
            phases.removeValue(forKey: path)
            phases[moved] = phase
        }
        for (path, job) in jobs {
            guard let moved = repointed(path) else { continue }
            jobs.removeValue(forKey: path)
            job.path = moved
            jobs[moved] = job
        }
        if let pending = pendingReveal, let moved = repointed(pending) {
            pendingReveal = moved
        }
    }

    /// Cancels every job and clears all per-entry state. Called when the
    /// active vault changes: entry paths are only meaningful within one
    /// vault, and no completion from the old vault may reach the new one.
    func reset() {
        for job in jobs.values { job.task?.cancel() }
        jobs = [:]
        phases = [:]
        pendingReveal = nil
    }

    /// True exactly once when `path` names the entry whose generation just
    /// finished; the caller should then show the summary. Matched by entry
    /// identity so a reveal survives a rename that slipped past `repointItems`.
    func consumeReveal(for path: RelativePath) -> Bool {
        guard let pending = pendingReveal, EntryIdentity.sameEntry(pending, path)
        else { return false }
        pendingReveal = nil
        return true
    }

    func noteSaved() {
        summaryRevision += 1
    }
}
