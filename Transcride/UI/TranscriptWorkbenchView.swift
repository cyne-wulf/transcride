import AppKit
import MarkdownUI
import SwiftUI

/// AppKit styling shared by the immutable and safely mapped edited transcript
/// surfaces. Voice Memos distinguishes the spoken word with luminance rather
/// than a selection-shaped box: surrounding copy recedes, while the active
/// run returns to the primary label color with a small zero-offset glow.
private enum TranscriptPlaybackWordStyle {
    static let temporaryKeys: [NSAttributedString.Key] = [
        .foregroundColor,
        .shadow,
    ]

    static func clearPlaybackAttributes(
        from layoutManager: NSLayoutManager?,
        in range: NSRange
    ) {
        for key in temporaryKeys {
            layoutManager?.removeTemporaryAttribute(key, forCharacterRange: range)
        }
    }

    static func subdueTranscript(
        in layoutManager: NSLayoutManager?,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        layoutManager?.addTemporaryAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            forCharacterRange: range
        )
    }

    static func illuminateWord(
        in layoutManager: NSLayoutManager?,
        range: NSRange
    ) {
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 4
        // `labelColor` is appearance-aware: this becomes a pale glow in dark
        // mode and a restrained dark halo in light mode, retaining contrast in
        // both without introducing an accent-colored selection rectangle.
        glow.shadowColor = NSColor.labelColor.withAlphaComponent(0.42)

        layoutManager?.addTemporaryAttributes(
            [
                .foregroundColor: NSColor.labelColor,
                .shadow: glow,
            ],
            forCharacterRange: range
        )
    }
}

/// The layered note surface for Milestone 4. The immutable original and the
/// editable Markdown document deliberately use separate AppKit text views so
/// there is no UI path that can mutate engine output.
struct TranscriptWorkbenchView: View {
    enum Layer: String, CaseIterable, Identifiable {
        case original = "Original"
        case edited = "Edited"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model

    let entry: Entry
    let original: TranscriptOriginal?
    let wordMap: TranscriptWordMap?
    let loadedIsForked: Bool
    let loadedContentRevision: Int
    let extensionState: ExtensionTranscriptState?
    @Binding var document: FrontmatterDocument?

    @State private var activeLayer: Layer = .original
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var editStartBody: String?
    @State private var editingStartedForked = false
    @State private var editingDidChange = false
    @State private var followingPaused = false
    @State private var pendingSave: Task<Void, Never>?
    @State private var needsSave = false
    @State private var copyConfirmed = false
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var showingFind = false
    @State private var findQuery = ""
    @State private var findMatches: [NSRange] = []
    @State private var findMatchIndex = 0
    @State private var showingReplace = false
    @State private var replaceQuery = ""
    @State private var searchNavigationRange: NSRange?
    @State private var handledNavigationRequestID: UUID?
    @State private var showingSpeakerRename = false
    @State private var forkOverride: Bool?
    @State private var editedPlaybackMap: EditedTranscriptPlaybackMap?
    @State private var showingSummary = false
    @State private var summaryDocument: SummaryDocument?
    @State private var isEditingSummary = false
    @State private var summaryNeedsSave = false
    @State private var pendingSummarySave: Task<Void, Never>?
    @State private var showingRegenerateConfirm = false
    @State private var showingDiscardEditsConfirm = false
    @State private var showingDeleteSummaryConfirm = false
    @State private var currentSourceFingerprint: String?
    @FocusState private var findFieldFocused: Bool

    /// User-chosen display names for machine speaker ids (TRN-6), from the
    /// entry's frontmatter.
    private var speakerNames: [String: String] {
        document.map { SpeakerNames.names(in: $0) } ?? [:]
    }

    private var hasSpeakers: Bool {
        original?.segments.contains { $0.speaker != nil } == true
    }

    private var isForked: Bool {
        forkOverride ?? loadedIsForked
    }

    /// The menu-bar Edit Note command remains available even though editing a
    /// forked note is normally re-entered by clicking its text directly.
    private var canEditNote: Bool {
        document != nil && !isEditing && !showingSummary
            && (viewedLayer == .edited || !isForked)
    }

    private var summaryPhase: SummaryGenerationController.Phase {
        model.summaryController.phase(for: entry.relativePath)
    }

    /// The stored fingerprint no longer matching the current source text
    /// means the transcript changed since generation: keep the summary
    /// readable, mark it out of date, never regenerate automatically.
    private var summaryIsStale: Bool {
        guard let stored = summaryDocument?.sourceFingerprint,
              let current = currentSourceFingerprint else { return false }
        return stored != current
    }

    /// Snapshot of what this workbench can do, mirrored into AppModel for the
    /// menu bar (see the onChange in `body`).
    private var currentUIState: AppModel.WorkbenchUIState {
        AppModel.WorkbenchUIState(
            hasContent: document != nil || original != nil,
            canEditNote: canEditNote,
            isEditing: isEditing,
            isForked: isForked && original != nil,
            hasSpeakers: hasSpeakers,
            viewedLayerIsOriginal: viewedLayer == .original,
            showingSummary: showingSummary
        )
    }

    /// The transcript layer on screen. Since the three-segment selector,
    /// the Edited segment is selectable on an unedited entry too: it shows
    /// the generated Markdown projection (click-to-edit), and only a saved
    /// change actually forks the note.
    private var viewedLayer: Layer {
        if original == nil { return .edited }
        if isEditing { return .edited }
        return activeLayer
    }

    private var activeNavigationRange: NSRange? {
        if showingFind, findMatches.indices.contains(findMatchIndex) {
            return findMatches[findMatchIndex]
        }
        return searchNavigationRange
    }

    var body: some View {
        // Two separately type-checked halves: the pre-existing workbench
        // chain and the summary lifecycle. One combined expression exceeds
        // the compiler's type-check budget.
        workbenchCore
            .task(id: summaryReloadKey) {
                await reloadSummary()
            }
            .task(id: showingSummary) {
                if showingSummary {
                    await model.modelManager.refreshModel(preferredSummaryModel.id)
                }
            }
            .onChange(of: entry.relativePath) { oldPath, newPath in
                // A title rename keeps the entry (and the visible summary);
                // only a genuine selection change resets the summary UI.
                if !EntryIdentity.sameEntry(oldPath, newPath) {
                    resetSummaryUI()
                    applyRememberedLayerSelection()
                }
            }
            .onDisappear {
                flushSummarySaveOnDisappear()
            }
            // VoiceOver progress announcements (PRD-9): generation start and
            // failure for this entry; completion is announced where the
            // per-entry reveal is consumed (`reloadSummary`), so another
            // entry's generation never announces here.
            .onChange(of: summaryPhase.isGenerating) { _, generating in
                if generating {
                    AccessibilityNotification.Announcement("Generating summary").post()
                } else if case .failed = summaryPhase {
                    AccessibilityNotification.Announcement("Summary generation failed").post()
                }
            }
            .confirmationDialog(
                "Replace your edited summary?",
                isPresented: $showingRegenerateConfirm
            ) {
                Button("Regenerate", role: .destructive) { regenerateSummary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You edited this summary by hand. Regenerating replaces your edits with a fresh AI summary.")
            }
            .confirmationDialog(
                "Discard your edits?",
                isPresented: $showingDiscardEditsConfirm
            ) {
                Button("Discard Edits", role: .destructive) {
                    Task { await discardEdits() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the edited copy of this note and returns to the original transcript. This can't be undone.")
            }
            .confirmationDialog(
                "Delete this summary?",
                isPresented: $showingDeleteSummaryConfirm
            ) {
                Button("Delete Summary", role: .destructive) {
                    Task { await deleteSummary() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the AI summary for this entry. You can generate a new one at any time.")
            }
    }

    private var summaryReloadKey: String {
        "\(String(describing: entry.relativePath))|\(model.summaryController.summaryRevision)|\(loadedContentRevision)"
    }

    private func flushSummarySaveOnDisappear() {
        let pendingSummarySave = pendingSummarySave
        pendingSummarySave?.cancel()
        if summaryNeedsSave, let body = summaryDocument?.body {
            let entry = entry
            Task {
                await pendingSummarySave?.value
                _ = await model.saveSummaryBody(body, for: entry)
            }
        }
    }

    private var workbenchCore: some View {
        VStack(spacing: 0) {
            // The action row spans the whole pane so its trailing controls sit
            // in the window's top-right corner (master PRD §7); the note
            // content below keeps its own centered max-width column.
            noteToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            if let extensionState {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.exclamationmark")
                    Text("Transcript belongs to the previous audio version (timing available through "
                        + EntryListView.formatDuration(extensionState.knownTranscriptDuration)
                        + "). Full retranscription is in progress; timing is intentionally disabled in the appended portion.")
                    if extensionState.normalizedToM4A {
                        Text("Combined audio was normalized to M4A.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcript belongs to the previous audio version. Full retranscription is in progress.")
            }

            VStack(spacing: 0) {
                if showingFind {
                    findBar
                        .frame(height: showingReplace ? 76 : 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                ZStack(alignment: .topTrailing) {
                    layerContent

                    if followingPaused, viewedLayer == .original, !showingSummary,
                       model.player.isPlaying {
                        Button {
                            followingPaused = false
                        } label: {
                            Label("Resume Following", systemImage: "location.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .frame(maxWidth: 900, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 36)
        }
        .background(.clear)
        .onChange(of: model.player.seekRevision) { _, _ in
            // Word clicks, waveform scrubs and transport skips all restore
            // follow. Silence skipping intentionally does not increment this.
            followingPaused = false
        }
        .onChange(of: isForked) { wasForked, nowForked in
            if !wasForked, nowForked { activeLayer = .edited }
        }
        .onChange(of: loadedContentRevision) { _, _ in
            forkOverride = nil
        }
        .task(id: loadedContentRevision) {
            await rebuildEditedPlaybackMap()
        }
        .onChange(of: viewedLayer) { _, _ in updateFindMatches() }
        .onChange(of: findQuery) { _, _ in updateFindMatches(resetSelection: true) }
        .onChange(of: document?.body) { _, _ in updateFindMatches() }
        .onChange(of: model.inNoteFindRequestRevision) { _, _ in
            toggleFindBar(withReplace: model.inNoteFindRequestWantsReplace)
        }
        .task(id: model.transcriptNavigationRequest?.id) {
            handleNavigationRequestIfNeeded()
        }
        .onChange(of: model.player.url) { _, _ in
            cueSearchNavigationIfPossible()
        }
        .onAppear {
            applyRememberedLayerSelection()
        }
        // Mirror this view's capabilities up so menu-bar items enable and
        // retitle truthfully; the state itself stays view-local.
        .onChange(of: currentUIState, initial: true) { _, newState in
            model.workbenchUIState = newState
        }
        .onChange(of: model.workbenchActionRevision) { _, _ in
            switch model.workbenchActionRequest {
            case .editOrSave:
                if isEditing {
                    if !isSaving { Task { await saveAndFinishEditing() } }
                } else if canEditNote {
                    beginEditing()
                }
            case .copyAsMarkdown:
                copyCurrentLayer()
            case .toggleLayer:
                if isForked, !isEditing, original != nil {
                    activeLayer = activeLayer == .original ? .edited : .original
                }
            case .renameSpeakers:
                if hasSpeakers, !isEditing, !isSaving { showingSpeakerRename = true }
            case .showSummary:
                if !isSaving { toggleSummary() }
            case .generateSummary:
                if !isSaving { handleGenerateSummaryCommand() }
            case .finishEditing(let completion):
                if !isEditing {
                    completion(true)
                } else if isSaving {
                    completion(false)
                } else {
                    Task {
                        await saveAndFinishEditing()
                        completion(!isEditing)
                    }
                }
            case nil:
                break
            }
        }
        .onDisappear {
            model.workbenchUIState = AppModel.WorkbenchUIState()
        }
        .sheet(isPresented: $showingSpeakerRename) {
            if let original {
                SpeakerRenameSheet(
                    entry: entry,
                    speakerIDs: SpeakerNames.speakerIDs(in: original),
                    currentNames: speakerNames
                )
            }
        }
        .onDisappear {
            let pendingSave = pendingSave
            pendingSave?.cancel()
            copyConfirmationTask?.cancel()
            if (needsSave || editingDidChange), let document {
                let clearHandEdited = !editingStartedForked && document.body == editStartBody
                Task {
                    await pendingSave?.value
                    _ = await model.saveTranscriptBody(
                        document.body,
                        markHandEdited: !clearHandEdited && document.handEdited,
                        clearHandEdited: clearHandEdited,
                        for: entry
                    )
                }
            }
        }
    }

    /// Tooltip for the visible Edit button, reflecting the live (remappable)
    /// Edit / Save Note shortcut instead of a hardcoded ⌘E.
    private var editButtonHelp: String {
        for slot in AppShortcutSlot.allCases {
            guard let chord = model.appShortcutPreferences.chord(for: .editOrSaveNote, slot: slot),
                  model.appShortcutPreferences.status(
                      for: .editOrSaveNote, slot: slot,
                      globalChords: model.configuredGlobalChords
                  ) == .active
            else { continue }
            return "Edit the note (\(chord.glyphDescription))"
        }
        return "Edit the note"
    }

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            if showingSummary {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if summaryIsStale {
                    Label("Out of date", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("The transcript changed since this summary was generated")
                }
            } else if viewedLayer == .original {
                Label("Synced to audio", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Markdown", systemImage: "text.document")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Type plain Markdown: # headings, - lists, **bold**, and _italic_")
            }

            Spacer()

            if showingSummary, summaryDocument != nil, !summaryPhase.isGenerating {
                if isEditingSummary {
                    Button("Save") {
                        finishSummaryEditing()
                    }
                    .help("Save the summary and finish editing")
                } else {
                    Button {
                        isEditingSummary = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit the summary — edits save independently of the transcript")

                    Button {
                        if summaryDocument?.handEdited == true {
                            showingRegenerateConfirm = true
                        } else {
                            regenerateSummary()
                        }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .help("Generate a fresh summary, replacing this one")

                    Button {
                        showingDeleteSummaryConfirm = true
                    } label: {
                        Label("Delete Summary", systemImage: "trash")
                    }
                    .help("Delete this summary")
                }
            }

            if !showingSummary, hasSpeakers {
                Button {
                    showingSpeakerRename = true
                } label: {
                    Label("Rename Speakers", systemImage: "person.2")
                }
                .disabled(isEditing || isSaving)
                .help("Rename Speaker 1, Speaker 2, … — or click a label in the transcript")
            }

            if !showingSummary {
                Button {
                    model.requestInNoteFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .accessibilityLabel(showingFind ? "Close Find" : "Find in Note")
                .help(showingFind ? "Close Find (⌘F)" : "Find in Note (⌘F)")
            }

            Button {
                copyCurrentLayer()
            } label: {
                Label(copyConfirmed ? "Copied" : "Copy as Markdown",
                      systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
            }
            .help("Copy this layer without frontmatter")

            if canEditNote {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help(editButtonHelp)
            }

            if !showingSummary, original != nil, isForked {
                Button {
                    showingDiscardEditsConfirm = true
                } label: {
                    Label("Discard Edits", systemImage: "trash")
                }
                .disabled(isSaving)
                .help("Delete the edited copy and return to the original transcript")
            }

            if document != nil || original != nil {
                TranscriptLayerControl(
                    layer: activeLayer,
                    isEditing: isEditing,
                    isSaving: isSaving,
                    summarySelected: showingSummary,
                    onSelectOriginal: { selectTranscriptLayer(.original) },
                    onSelectEdited: { selectTranscriptLayer(.edited) },
                    onSave: { Task { await saveAndFinishEditing() } },
                    onSelectSummary: { selectSummaryLayer() }
                )
                .fixedSize()
                .help(isEditing
                      ? "Save to finish editing — or click Original to finish and view the original"
                      : "Switch between the engine output, your edited note, and the AI summary")
            }
        }
    }

    /// Selector action for the two transcript segments. Leaving the Summary
    /// layer flushes any pending summary edit first; selecting Original while
    /// editing keeps the long-standing save-and-land-on-original behavior.
    private func selectTranscriptLayer(_ layer: Layer) {
        leaveSummaryLayer()
        if isEditing {
            if layer == .original {
                Task { await saveAndFinishEditing(returningTo: .original) }
            }
            // Selecting Edited while editing is the Save segment's job.
        } else {
            activeLayer = layer
        }
        rememberLayerSelection(layer == .original ? .original : .edited)
    }

    private func selectSummaryLayer() {
        guard !showingSummary else { return }
        if isEditing {
            Task {
                await saveAndFinishEditing()
                guard !isEditing else { return }
                showingSummary = true
                rememberLayerSelection(.summary)
            }
            return
        }
        showingSummary = true
        rememberLayerSelection(.summary)
    }

    private func leaveSummaryLayer() {
        guard showingSummary else { return }
        finishSummaryEditing()
        showingSummary = false
    }

    /// Session-scoped, per-entry layer memory (PRD-9): reopening an entry
    /// restores the layer it was last viewed on, without persisting anything.
    private func rememberLayerSelection(_ selection: AppModel.NoteLayerSelection) {
        model.sessionNoteLayers[entry.relativePath] = selection
    }

    private func applyRememberedLayerSelection() {
        switch model.sessionNoteLayers[entry.relativePath] {
        case .summary:
            showingSummary = true
        case .edited:
            activeLayer = .edited
        case .original:
            activeLayer = .original
        case nil:
            if isForked { activeLayer = .edited }
        }
    }

    private var findBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in \(viewedLayer.rawValue)", text: $findQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFieldFocused)
                    .onSubmit { cycleFind(forward: true) }
                Text(findQuery.isEmpty ? "" : findMatches.isEmpty
                     ? "No matches"
                     : "\(findMatchIndex + 1) of \(findMatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                Button { cycleFind(forward: false) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(findMatches.isEmpty)
                .help("Previous Match")
                Button { cycleFind(forward: true) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(findMatches.isEmpty)
                .help("Next Match")
                Toggle("Replace", isOn: $showingReplace)
                    .toggleStyle(.button)
                    .disabled(!canReplace)
                    .help(canReplace
                          ? "Show the replace field"
                          : "Replace needs an editable note")
                Button {
                    closeFindBar()
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .help("Close Find")
            }
            if showingReplace {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                    TextField("Replace in Edited", text: $replaceQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { replaceCurrentMatch() }
                    Button("Replace") { replaceCurrentMatch() }
                        .disabled(!canReplace || findMatches.isEmpty)
                        .help("Replace the current match and move to the next")
                    Button("All") { replaceAllMatches() }
                        .disabled(!canReplace || findMatches.isEmpty)
                        .help("Replace every match in the edited note")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
    }

    /// Replace mutates the note body, so it is only offered where editing is:
    /// never for the AI summary and never without a Markdown document. The
    /// original layer stays immutable — replacing from there drops into the
    /// normal editing flow on the edited layer first.
    private var canReplace: Bool {
        document != nil && !showingSummary && !isSaving
    }

    /// Trim, Compress and Replace mark the entry's alignment stale: the word
    /// timings still describe the audio timeline that was edited away, so the
    /// passive highlight is switched off until an authoritative transcription
    /// lands. Clicks, speaker labels and search cues deliberately stay live.
    ///
    /// Two deliberate details. The raw scanned availability is read instead of
    /// `AppModel.speechTranscriptAvailability(for:)`, whose `.regenerating`
    /// answer masks staleness for queued entries — which is precisely the
    /// post-edit window this has to catch. And a pending extension transcript
    /// also reports `.stale` even though the original portion's timings are
    /// still true, so those entries keep highlighting (already bounded by
    /// `knownTranscriptDuration`).
    private var karaokeTimingIsStale: Bool {
        entry.speechTranscriptAvailability == .stale && extensionState == nil
    }

    @ViewBuilder
    private var layerContent: some View {
        if showingSummary {
            summaryContent
        } else {
            transcriptLayerContent
        }
    }

    @ViewBuilder
    private var transcriptLayerContent: some View {
        switch viewedLayer {
        case .original:
            if let wordMap {
                OriginalTranscriptPlaybackView(
                    entryHasAudio: entry.hasAudio,
                    map: wordMap,
                    knownTranscriptDuration: extensionState?.knownTranscriptDuration,
                    timingIsStale: karaokeTimingIsStale,
                    navigationHighlightRange: activeNavigationRange,
                    followingPaused: $followingPaused,
                    onWordClick: { wordIndex in
                        searchNavigationRange = nil
                        guard let time = wordMap.startTime(forWordAt: wordIndex) else { return }
                        model.player.seek(to: time)
                    },
                    onSpeakerLabelClick: { _ in
                        showingSpeakerRename = true
                    }
                )
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
            } else {
                ContentUnavailableView(
                    "Original Unavailable",
                    systemImage: "text.badge.xmark",
                    description: Text("The timed engine transcript has not been created yet.")
                )
            }

        case .edited:
            if let body = document?.body {
                EditedTranscriptPlaybackView(
                    entryHasAudio: entry.hasAudio,
                    wordMap: wordMap,
                    timingIsStale: karaokeTimingIsStale,
                    playbackMap: editedPlaybackMap,
                    text: body,
                    isEditable: isEditing && !isSaving,
                    navigationHighlightRange: activeNavigationRange,
                    onBeginEditing: beginEditing
                ) { newBody in
                    applyUserEdit(newBody)
                }
            } else {
                ContentUnavailableView(
                    "No Editable Note",
                    systemImage: "doc",
                    description: Text("The transcript Markdown file has not been created yet.")
                )
            }
        }
    }

    // MARK: - AI summary (PRD-9 MVP)

    @ViewBuilder
    private var summaryContent: some View {
        switch summaryPhase {
        case .generating(let part, let total, let fraction):
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Summary generation progress")
                Text(total > 1 ? "Summarizing… (part \(part) of \(total))" : "Summarizing…")
                Button("Cancel") {
                    model.summaryController.cancel(for: entry.relativePath)
                }
                .accessibilityLabel("Cancel summary generation")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Summary Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    model.summaryController.clearFailure(for: entry.relativePath)
                    startSummaryGeneration()
                }
            }

        case .idle:
            if summaryDocument != nil {
                if isEditingSummary {
                    MarkdownBodyEditor(
                        text: summaryDocument?.body ?? "",
                        isEditable: true,
                        highlightRange: nil,
                        navigationHighlightRange: nil,
                        boundaryStartTime: nil,
                        boundaryCueRange: nil,
                        playbackTime: 0,
                        isPlaying: false,
                        seekRevision: 0,
                        onBeginEditing: {},
                        onUserEdit: { applySummaryEdit($0) }
                    )
                } else {
                    renderedSummary
                }
            } else {
                summaryEmptyState
            }
        }
    }

    /// Read mode: rendered markdown via MarkdownUI. Clicking the text
    /// drops into the raw editor, matching the note's click-to-edit feel;
    /// the toolbar Edit button is the discoverable path.
    private var renderedSummary: some View {
        ScrollView {
            Markdown(summaryDocument?.body ?? "")
                .markdownTheme(.transcride)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { isEditingSummary = true }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private var preferredSummaryModel: TranscriptionModelInfo {
        SummaryModelCatalog.preferredModel()
    }

    /// The pre-generation states mirror the Settings model row so the first
    /// summary can be produced without leaving the workbench.
    @ViewBuilder
    private var summaryEmptyState: some View {
        let modelInfo = preferredSummaryModel
        switch model.modelManager.state(forModelInfoID: modelInfo.id) {
        case .checking:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .notDownloaded:
            ContentUnavailableView {
                Label("Summary Model Needed", systemImage: "sparkles")
            } description: {
                Text("\(modelInfo.displayName) (\(modelInfo.downloadSizeDescription)) runs entirely on this Mac. Download it once to generate summaries.")
            } actions: {
                Button("Download Model") {
                    model.modelManager.download(modelInfo.id)
                }
                .buttonStyle(.borderedProminent)
            }

        case .downloading(let fraction):
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 240)
                Text("Downloading \(modelInfo.displayName)… \(Int(fraction * 100))%")
                Button("Cancel") {
                    model.modelManager.cancelDownload(modelInfo.id)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .preparing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing model… (first-time setup, can take a few minutes)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .downloaded:
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text("Generate a local AI summary of this recording. Nothing leaves this Mac.")
            } actions: {
                Button("Generate Summary") {
                    startSummaryGeneration()
                }
                .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Model Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry Download") {
                    model.modelManager.download(modelInfo.id)
                }
            }
        }
    }

    /// Menu "Show Summary" / "Show Transcript". Unlike the MVP toolbar
    /// button, selecting Summary never auto-generates: the layer is
    /// selectable before generation and shows the empty state with an
    /// explicit Generate Summary action (PRD-9).
    private func toggleSummary() {
        if showingSummary {
            leaveSummaryLayer()
            rememberLayerSelection(viewedLayer == .original ? .original : .edited)
        } else {
            selectSummaryLayer()
        }
    }

    /// Menu "Generate Summary…": shows the Summary layer and starts (or
    /// restarts) generation, honoring the hand-edit confirmation. With no
    /// model downloaded it lands on the empty state, which owns download.
    private func handleGenerateSummaryCommand() {
        guard document != nil || original != nil else { return }
        if isEditing {
            Task {
                await saveAndFinishEditing()
                guard !isEditing else { return }
                handleGenerateSummaryCommand()
            }
            return
        }
        if !showingSummary {
            showingSummary = true
            rememberLayerSelection(.summary)
        }
        switch summaryPhase {
        case .generating:
            return
        case .failed:
            model.summaryController.clearFailure(for: entry.relativePath)
            startSummaryGeneration()
        case .idle:
            guard model.modelManager.state(
                forModelInfoID: preferredSummaryModel.id
            ).isDownloaded else { return }
            if summaryDocument?.handEdited == true {
                showingRegenerateConfirm = true
            } else if summaryDocument != nil {
                regenerateSummary()
            } else {
                startSummaryGeneration()
            }
        }
    }

    private func startSummaryGeneration() {
        isEditingSummary = false
        model.generateSummary(for: entry, document: document, original: original)
    }

    private func regenerateSummary() {
        pendingSummarySave?.cancel()
        summaryNeedsSave = false
        startSummaryGeneration()
    }

    private func applySummaryEdit(_ newBody: String) {
        guard isEditingSummary, var summary = summaryDocument, newBody != summary.body
        else { return }
        summary.replaceBody(newBody, markHandEdited: true)
        summaryDocument = summary
        summaryNeedsSave = true

        pendingSummarySave?.cancel()
        let entry = entry
        pendingSummarySave = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                if let saved = await model.saveSummaryBody(newBody, for: entry),
                   summaryDocument?.body == newBody {
                    summaryDocument = saved
                    summaryNeedsSave = false
                }
            } catch is CancellationError {
                // A newer keystroke replaced this pending write.
            } catch {
                // `saveSummaryBody` presents file-system errors centrally.
            }
        }
    }

    private func finishSummaryEditing() {
        guard isEditingSummary else { return }
        pendingSummarySave?.cancel()
        pendingSummarySave = nil
        if summaryNeedsSave, let body = summaryDocument?.body {
            summaryNeedsSave = false
            let entry = entry
            Task {
                // Same guard as applySummaryEdit: never clobber an edit the
                // user made (by re-entering editing) while this save flew.
                if let saved = await model.saveSummaryBody(body, for: entry),
                   summaryDocument?.body == body {
                    summaryDocument = saved
                }
            }
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
        isEditingSummary = false
    }

    @MainActor
    private func reloadSummary() async {
        guard !isEditingSummary else { return }
        let loaded = await model.loadSummary(for: entry)
        // The reload runs under `.task(id: summaryReloadKey)`, which cancels
        // it when the entry (or revision) changes; the awaits above and below
        // still resume, so honor the cancellation before every state write —
        // a stale reload must not repopulate the next entry's summary.
        guard !Task.isCancelled else { return }
        summaryDocument = loaded
        // A generation that just finished reveals its result — including
        // after the AI title rename tears down and recreates this view.
        if summaryDocument != nil,
           model.summaryController.consumeReveal(for: entry.relativePath) {
            showingSummary = true
            AccessibilityNotification.Announcement("Summary ready").post()
        }
        let doc = document
        let orig = original
        // SHA256 over the whole source text — off the main actor so a long
        // transcript never stutters the UI.
        let fingerprint = await Task.detached(priority: .utility) {
            SummarySourceSelector.source(document: doc, original: orig)
                .map { SummaryFingerprint.fingerprint(of: $0.text) }
        }.value
        guard !Task.isCancelled else { return }
        currentSourceFingerprint = fingerprint
    }

    private func resetSummaryUI() {
        pendingSummarySave?.cancel()
        pendingSummarySave = nil
        summaryNeedsSave = false
        isEditingSummary = false
        showingSummary = false
        showingRegenerateConfirm = false
        // A destructive confirmation opened for the previous entry must not
        // act on the newly selected one.
        showingDeleteSummaryConfirm = false
        showingDiscardEditsConfirm = false
        // The reload for the new entry is asynchronous; holding the previous
        // entry's summary here could render it as the new entry's content.
        summaryDocument = nil
        currentSourceFingerprint = nil
    }

    private func beginEditing() {
        guard let document else { return }
        editingStartedForked = isForked
        editingDidChange = false
        editStartBody = document.body
        activeLayer = .edited
        isEditing = true
    }

    /// `returningTo: .original` lands on the original layer even when the
    /// note stays forked — the layer control's Original segment doubles as
    /// "finish editing and show the original".
    @MainActor
    private func saveAndFinishEditing(returningTo: Layer? = nil) async {
        guard isEditing, !isSaving, let document else { return }
        isSaving = true

        let pendingSave = pendingSave
        pendingSave?.cancel()
        self.pendingSave = nil
        await pendingSave?.value

        let hasActualChange = document.body != editStartBody
        let restoreUnforkedState = !editingStartedForked && !hasActualChange
        let savedIsForked = !restoreUnforkedState && (document.handEdited || editingStartedForked)

        if editingDidChange || needsSave {
            guard let saved = await model.saveTranscriptBody(
                document.body,
                markHandEdited: !restoreUnforkedState && document.handEdited,
                clearHandEdited: restoreUnforkedState,
                for: entry
            ) else {
                isSaving = false
                return
            }
            self.document = saved
        }

        NSApp.keyWindow?.makeFirstResponder(nil)
        needsSave = false
        isEditing = false
        isSaving = false
        editStartBody = nil
        editingDidChange = false
        editingStartedForked = false

        if original != nil, !savedIsForked {
            activeLayer = .original
            forkOverride = false
            editedPlaybackMap = nil
        } else {
            await rebuildEditedPlaybackMap()
            activeLayer = (returningTo == .original && original != nil) ? .original : .edited
            forkOverride = true
        }
    }

    /// Deletes the edited layer: rewrites the note body to the regenerated
    /// original and clears `hand_edited`, un-forking the entry. Keystrokes
    /// autosave, so a true discard must rewrite the file — dropping view
    /// state alone would resurrect the edits on the next load.
    @MainActor
    private func discardEdits() async {
        guard let original, document != nil, !isSaving else { return }
        isSaving = true

        let pendingSave = pendingSave
        pendingSave?.cancel()
        self.pendingSave = nil
        await pendingSave?.value

        let regenerated = "\n" + TranscriptMarkdown.body(from: original, speakerNames: speakerNames) + "\n"
        if let saved = await model.saveTranscriptBody(
            regenerated,
            markHandEdited: false,
            clearHandEdited: true,
            for: entry
        ) {
            document = saved
            NSApp.keyWindow?.makeFirstResponder(nil)
            isEditing = false
            needsSave = false
            editStartBody = nil
            editingDidChange = false
            editingStartedForked = false
            activeLayer = .original
            forkOverride = false
            editedPlaybackMap = nil
        }
        isSaving = false
    }

    /// Deletes the summary sidecar and returns to the transcript. The pending
    /// debounced save must die first, or it fires after the delete and throws
    /// "summary not found".
    @MainActor
    private func deleteSummary() async {
        pendingSummarySave?.cancel()
        pendingSummarySave = nil
        summaryNeedsSave = false
        isEditingSummary = false
        if await model.deleteSummary(for: entry) {
            summaryDocument = nil
            showingSummary = false
        }
    }

    /// The edited/original prefix comparison is linear in note length. Build
    /// it only when loaded content changes or editing finishes, never from the
    /// 30 Hz playback-driven SwiftUI update path.
    @MainActor
    private func rebuildEditedPlaybackMap() async {
        guard let wordMap, let body = document?.body else {
            editedPlaybackMap = nil
            return
        }
        let rebuilt = await Task.detached(priority: .userInitiated) {
            EditedTranscriptPlaybackMap(original: wordMap, editedBody: body)
        }.value
        guard document?.body == body else { return }
        editedPlaybackMap = rebuilt
    }

    private func applyUserEdit(_ newBody: String) {
        guard isEditing, var document, newBody != document.body else { return }
        searchNavigationRange = nil
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(newBody)
        document = editable.document
        self.document = document
        forkOverride = true
        activeLayer = .edited
        needsSave = true
        editingDidChange = true

        pendingSave?.cancel()
        let entry = entry
        pendingSave = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                if let saved = await model.saveTranscriptBody(
                    newBody,
                    markHandEdited: document.handEdited,
                    for: entry
                ),
                   self.document?.body == newBody {
                    self.document = saved
                    needsSave = false
                }
            } catch is CancellationError {
                // A newer keystroke replaced this pending write.
            } catch {
                // `saveTranscriptBody` presents file-system errors centrally.
            }
        }
    }

    private var findSource: String {
        switch viewedLayer {
        case .original: wordMap?.renderedText ?? ""
        case .edited: document?.body ?? ""
        }
    }

    private func updateFindMatches(resetSelection: Bool = false) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showingFind, !query.isEmpty else {
            findMatches = []
            findMatchIndex = 0
            return
        }
        let matches = Self.matchRanges(of: query, in: findSource as NSString)
        findMatches = matches
        if resetSelection || !matches.indices.contains(findMatchIndex) { findMatchIndex = 0 }
    }

    private static func matchRanges(of query: String, in source: NSString) -> [NSRange] {
        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let next = NSMaxRange(found)
            guard next > found.location else { break }
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return matches
    }

    private func toggleFindBar(withReplace: Bool = false) {
        if showingFind {
            // ⌥⌘F on an open find-only bar expands it instead of closing.
            if withReplace, !showingReplace, canReplace {
                showingReplace = true
                findFieldFocused = true
                return
            }
            closeFindBar()
            return
        }
        showingFind = true
        showingReplace = withReplace && canReplace
        searchNavigationRange = nil
        updateFindMatches(resetSelection: true)
        findFieldFocused = true
    }

    private func closeFindBar() {
        showingFind = false
        showingReplace = false
        findQuery = ""
        replaceQuery = ""
        findMatches = []
        findMatchIndex = 0
        findFieldFocused = false
    }

    /// Both replace actions target `document.body` — the only mutable text.
    /// When invoked while viewing the immutable original, this first enters
    /// the standard editing flow (which shows the edited layer) and recomputes
    /// the matches against the edited body, so the ranges being replaced are
    /// exactly the ones on screen.
    private func replaceCurrentMatch() {
        guard canReplace else { return }
        if !isEditing { beginEditing() }
        updateFindMatches()
        guard isEditing, let body = document?.body,
              findMatches.indices.contains(findMatchIndex) else { return }
        let target = findMatches[findMatchIndex]
        let newBody = (body as NSString).replacingCharacters(in: target, with: replaceQuery)
        applyUserEdit(newBody)
        // Land on the match after the replacement, skipping any new hit the
        // replacement text itself introduced inside the replaced span (e.g.
        // replacing "cat" with "cats" must not select the same spot forever).
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let boundary = target.location + replaceQuery.utf16.count
        let updated = Self.matchRanges(of: query, in: newBody as NSString)
        findMatches = updated
        findMatchIndex = updated.firstIndex { $0.location >= boundary } ?? 0
    }

    private func replaceAllMatches() {
        guard canReplace else { return }
        if !isEditing { beginEditing() }
        updateFindMatches()
        guard isEditing, let body = document?.body, !findMatches.isEmpty else { return }
        let newBody = NSMutableString(string: body)
        for range in findMatches.reversed() {
            newBody.replaceCharacters(in: range, with: replaceQuery)
        }
        applyUserEdit(newBody as String)
    }

    private func cycleFind(forward: Bool) {
        guard !findMatches.isEmpty else { return }
        findMatchIndex = forward
            ? (findMatchIndex + 1) % findMatches.count
            : (findMatchIndex - 1 + findMatches.count) % findMatches.count
    }

    private func handleNavigationRequestIfNeeded() {
        guard let request = model.transcriptNavigationRequest,
              request.hit.entryPath == entry.relativePath,
              handledNavigationRequestID != request.id else { return }
        if isEditing {
            Task {
                await saveAndFinishEditing()
                guard !isEditing else { return }
                handleNavigationRequestIfNeeded()
            }
            return
        }
        handledNavigationRequestID = request.id
        showingFind = false
        showingReplace = false
        findQuery = ""
        replaceQuery = ""
        findMatches = []
        switch request.hit.layer {
        case .original:
            searchNavigationRange = NSRange(request.hit.matchRange)
            leaveSummaryLayer()
            activeLayer = .original
            isEditing = false
        case .edited:
            searchNavigationRange = NSRange(request.hit.matchRange)
            leaveSummaryLayer()
            activeLayer = .edited
            isEditing = false
        case .summary:
            // A summary hit opens the Summary layer and never cues audio —
            // its text has no time coordinates.
            searchNavigationRange = nil
            isEditingSummary = false
            showingSummary = true
        }
        cueSearchNavigationIfPossible()
    }

    private func cueSearchNavigationIfPossible() {
        guard let request = model.transcriptNavigationRequest,
              request.id == handledNavigationRequestID,
              request.hit.entryPath == entry.relativePath,
              model.player.url != nil,
              let map = wordMap else { return }

        let time: TimeInterval?
        switch request.hit.layer {
        case .original:
            time = map.startTime(atOrBeforeUTF16Offset: request.hit.matchRange.lowerBound)
        case .edited:
            guard let body = document?.body else { return }
            time = map.startTime(forMatch: request.hit.matchRange, inEditedBody: body)
        case .summary:
            return
        }
        guard let time else { return }
        model.player.pause()
        model.player.seek(to: time)
    }

    private func copyCurrentLayer() {
        let markdown: String
        if showingSummary {
            markdown = summaryDocument?.body.trimmingCharacters(in: .newlines) ?? ""
        } else {
            switch viewedLayer {
            case .original:
                markdown = wordMap?.renderedText ?? ""
            case .edited:
                markdown = document?.body.trimmingCharacters(in: .newlines) ?? ""
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)

        copyConfirmationTask?.cancel()
        copyConfirmed = true
        copyConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copyConfirmed = false
        }
    }
}

/// The three-segment Original / Edited / Summary layer control. The Edited
/// segment becomes the commit action while the Markdown surface owns text
/// focus; Original then commits too and lands on the original layer. A custom
/// control is used because a segmented Picker does not reliably invoke an
/// already-selected segment.
private struct TranscriptLayerControl: View {
    let layer: TranscriptWorkbenchView.Layer
    let isEditing: Bool
    let isSaving: Bool
    let summarySelected: Bool
    let onSelectOriginal: () -> Void
    let onSelectEdited: () -> Void
    let onSave: () -> Void
    let onSelectSummary: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment(
                "Original",
                selected: !summarySelected && !isEditing && layer == .original
            ) {
                onSelectOriginal()
            }
            .disabled(isSaving)

            segment(
                isEditing ? "Save" : "Edited",
                selected: !summarySelected && (isEditing || layer == .edited)
            ) {
                if isEditing { onSave() } else { onSelectEdited() }
            }
            .disabled(isSaving)

            segment("Summary", selected: summarySelected) {
                onSelectSummary()
            }
            .disabled(isSaving)
            .accessibilityLabel("AI Summary")
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note Layer")
    }

    private func segment(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(minWidth: 58)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Immutable synced original

/// Keeps the rapidly changing player clock below `TranscriptWorkbenchView`.
/// Only this small leaf is invalidated at playback cadence; the toolbar,
/// editor state, find results, and layer-selection logic stay untouched.
private struct OriginalTranscriptPlaybackView: View {
    @Environment(AppModel.self) private var model

    let entryHasAudio: Bool
    let map: TranscriptWordMap
    let knownTranscriptDuration: TimeInterval?
    let timingIsStale: Bool
    let navigationHighlightRange: NSRange?
    @Binding var followingPaused: Bool
    let onWordClick: (Int) -> Void
    let onSpeakerLabelClick: (String) -> Void

    private var currentWordIndex: Int? {
        guard entryHasAudio, !timingIsStale, model.player.url != nil else { return nil }
        let time = model.player.highlightTime
        if let knownTranscriptDuration, time > knownTranscriptDuration {
            return nil
        }
        return map.wordIndex(atTime: time)
    }

    var body: some View {
        SyncedOriginalTextView(
            map: map,
            currentWordIndex: currentWordIndex,
            navigationHighlightRange: navigationHighlightRange,
            followingPaused: $followingPaused,
            onWordClick: onWordClick,
            onSpeakerLabelClick: onSpeakerLabelClick
        )
    }
}

private struct SyncedOriginalTextView: NSViewRepresentable {
    let map: TranscriptWordMap
    let currentWordIndex: Int?
    let navigationHighlightRange: NSRange?
    @Binding var followingPaused: Bool
    let onWordClick: (Int) -> Void
    /// Clicking a rendered `**Speaker N:**` label opens rename (TRN-6).
    let onSpeakerLabelClick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = UserAwareTranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = ClickableTranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onCharacterClick = { offset in
            let parent = context.coordinator.parent
            if let label = parent.map.speakerLabel(containingUTF16Offset: offset) {
                parent.onSpeakerLabelClick(label.speakerID)
            } else if let wordIndex = parent.map.wordIndex(containingUTF16Offset: offset) {
                parent.onWordClick(wordIndex)
            }
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        scrollView.onUserScroll = { [weak coordinator = context.coordinator] in
            coordinator?.parent.followingPaused = true
        }
        context.coordinator.installBoundsObserver()
        context.coordinator.renderBaseText()
        context.coordinator.updateHighlights(
            playbackWordIndex: currentWordIndex,
            navigationRange: navigationHighlightRange
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView?.onCharacterClick = { offset in
            let parent = context.coordinator.parent
            if let label = parent.map.speakerLabel(containingUTF16Offset: offset) {
                parent.onSpeakerLabelClick(label.speakerID)
            } else if let wordIndex = parent.map.wordIndex(containingUTF16Offset: offset) {
                parent.onWordClick(wordIndex)
            }
        }
        if context.coordinator.renderedText != map.renderedText {
            context.coordinator.renderBaseText()
        }
        context.coordinator.updateHighlights(
            playbackWordIndex: currentWordIndex,
            navigationRange: navigationHighlightRange
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeBoundsObserver()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SyncedOriginalTextView
        weak var textView: ClickableTranscriptTextView?
        weak var scrollView: NSScrollView?
        var renderedText = ""
        var highlightedWordIndex: Int?
        var highlightedRange: NSRange?
        var navigationRange: NSRange?
        var boundsObserver: NSObjectProtocol?
        var isProgrammaticScroll = false

        init(parent: SyncedOriginalTextView) {
            self.parent = parent
        }

        func installBoundsObserver() {
            guard let contentView = scrollView?.contentView else { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.boundsChanged() }
            }
        }

        func removeBoundsObserver() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
        }

        private func boundsChanged() {
            guard !isProgrammaticScroll else { return }
            guard let eventType = NSApp.currentEvent?.type,
                  eventType == .scrollWheel || eventType == .leftMouseDragged else { return }
            parent.followingPaused = true
        }

        func renderBaseText() {
            guard let textView else { return }
            renderedText = parent.map.renderedText
            highlightedWordIndex = nil
            highlightedRange = nil
            navigationRange = nil
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 6
            paragraph.paragraphSpacing = 12
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: renderedText, attributes: attributes)
            )
            // Speaker labels render semibold. The font is a permanent
            // attribute (fonts affect layout, so they can't be temporary);
            // color treatment happens per-highlight-pass below.
            for label in parent.map.speakerLabels {
                textView.textStorage?.addAttributes(
                    [.font: NSFont.systemFont(ofSize: 17, weight: .semibold)],
                    range: NSRange(label.range)
                )
            }
            styleSpeakerLabels()
        }

        /// The rendered text keeps the markdown `**` so it stays byte-aligned
        /// with the generated body and search index; drawing the asterisks
        /// clear makes the label read as "Name:" with a little padding.
        private func styleSpeakerLabels() {
            guard let layoutManager = textView?.layoutManager else { return }
            for label in parent.map.speakerLabels {
                let range = NSRange(label.range)
                guard range.length > 4 else { continue }
                for asterisks in [
                    NSRange(location: range.location, length: 2),
                    NSRange(location: NSMaxRange(range) - 2, length: 2),
                ] {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor, value: NSColor.clear, forCharacterRange: asterisks
                    )
                }
            }
        }

        func updateHighlights(playbackWordIndex: Int?, navigationRange: NSRange?) {
            guard let textView else { return }
            let wordChanged = highlightedWordIndex != playbackWordIndex
            let nextHighlightRange = playbackWordIndex
                .flatMap(parent.map.range(forWordAt:))
                .map(NSRange.init)
            let highlightChanged = wordChanged || highlightedRange != nextHighlightRange
            if highlightChanged {
                if let highlightedRange {
                    TranscriptPlaybackWordStyle.clearPlaybackAttributes(
                        from: textView.layoutManager,
                        in: highlightedRange
                    )
                }
                highlightedWordIndex = playbackWordIndex
                highlightedRange = nextHighlightRange
            }
            if let playbackWordIndex, let nextHighlightRange,
               highlightChanged {
                TranscriptPlaybackWordStyle.illuminateWord(
                    in: textView.layoutManager,
                    range: nextHighlightRange
                )
                if wordChanged, !parent.followingPaused { scrollToWord(playbackWordIndex) }
            }

            let navigationChanged = self.navigationRange != navigationRange
            if navigationChanged, let oldRange = self.navigationRange {
                textView.layoutManager?.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: oldRange
                )
            }
            self.navigationRange = navigationRange
            if navigationChanged, let navigationRange,
               NSMaxRange(navigationRange) <= (textView.string as NSString).length {
                textView.layoutManager?.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    forCharacterRange: navigationRange
                )
                if navigationChanged { scrollToCharacterRange(navigationRange) }
            }
        }

        private func scrollToCharacterRange(_ range: NSRange) {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(forCharacterRange: range)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let viewport = scrollView.contentView.bounds
            let targetY = max(0, rect.midY - viewport.height * 0.42)
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { [weak self] in self?.isProgrammaticScroll = false }
        }

        private func scrollToWord(_ wordIndex: Int) {
            guard let textView, let scrollView,
                  let range = parent.map.range(forWordAt: wordIndex),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(forCharacterRange: NSRange(range))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(range), actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let viewport = scrollView.contentView.bounds
            let targetY = max(0, rect.midY - viewport.height * 0.42)
            guard abs(viewport.minY - targetY) > 2 else { return }
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { [weak self] in self?.isProgrammaticScroll = false }
        }
    }
}

private final class ClickableTranscriptTextView: NSTextView {
    var onCharacterClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let layoutManager, let textContainer else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: point, in: textContainer, fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -3).contains(point) else { return }
        onCharacterClick?(layoutManager.characterIndexForGlyph(at: glyphIndex))
    }
}

@MainActor
private final class UserAwareTranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

// MARK: - Editable Markdown layer

/// Edited playback also owns its clock dependency locally. The expensive
/// prefix projection arrives prebuilt and is reused until the note changes.
private struct EditedTranscriptPlaybackView: View {
    @Environment(AppModel.self) private var model

    let entryHasAudio: Bool
    let wordMap: TranscriptWordMap?
    let timingIsStale: Bool
    let playbackMap: EditedTranscriptPlaybackMap?
    let text: String
    let isEditable: Bool
    let navigationHighlightRange: NSRange?
    let onBeginEditing: () -> Void
    let onUserEdit: (String) -> Void

    private var currentWordIndex: Int? {
        guard entryHasAudio, !timingIsStale, model.player.url != nil else { return nil }
        return wordMap?.wordIndex(atTime: model.player.highlightTime)
    }

    private var highlightRange: NSRange? {
        guard let currentWordIndex,
              let range = playbackMap?.range(forWordAt: currentWordIndex) else { return nil }
        return NSRange(range)
    }

    var body: some View {
        MarkdownBodyEditor(
            text: text,
            isEditable: isEditable,
            highlightRange: highlightRange,
            navigationHighlightRange: navigationHighlightRange,
            boundaryStartTime: playbackMap?.boundaryStartTime,
            boundaryCueRange: playbackMap?.cueRange.map(NSRange.init),
            playbackTime: model.player.highlightTime,
            isPlaying: model.player.isPlaying,
            seekRevision: model.player.seekRevision,
            onBeginEditing: onBeginEditing,
            onUserEdit: onUserEdit
        )
    }
}

private final class ClickToEditTextView: NSTextView {
    var onRequestEditing: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let shouldBeginEditing = !isEditable
        super.mouseDown(with: event)
        if shouldBeginEditing { onRequestEditing?() }
    }
}

private struct MarkdownBodyEditor: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let highlightRange: NSRange?
    let navigationHighlightRange: NSRange?
    let boundaryStartTime: TimeInterval?
    let boundaryCueRange: NSRange?
    let playbackTime: TimeInterval
    let isPlaying: Bool
    let seekRevision: Int
    let onBeginEditing: () -> Void
    let onUserEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = ClickToEditTextView()
        textView.delegate = context.coordinator
        textView.onRequestEditing = onBeginEditing
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        context.coordinator.recordRenderedText(text)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateHighlights()
        if isEditable {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onRequestEditing = onBeginEditing
        if context.coordinator.renderedText != text {
            let selection = textView.selectedRange()
            context.coordinator.prepareForTextReplacement()
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            context.coordinator.recordRenderedText(text)
            textView.setSelectedRange(NSRange(
                location: min(selection.location, context.coordinator.renderedTextUTF16Length),
                length: 0
            ))
            context.coordinator.isApplyingExternalText = false
            // Registered undo actions reference ranges in the replaced text.
            context.coordinator.editUndoManager.removeAllActions()
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            if isEditable {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window != nil else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            } else if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }
        context.coordinator.updateHighlights()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelBoundaryFade()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownBodyEditor
        weak var textView: ClickToEditTextView?
        var isApplyingExternalText = false
        var renderedText: String
        var renderedTextUTF16Length: Int
        var appliedHighlightRange: NSRange?
        var appliedNavigationRange: NSRange?
        var boundaryFadeTask: Task<Void, Never>?
        var boundaryFadeRanges: [NSRange] = []
        var transcriptIsSubdued = false
        var wasBeforeBoundary = false
        var lastSeekRevision: Int
        /// Hosted NSTextViews otherwise resolve `undoManager` through the
        /// SwiftUI window, whose manager doesn't track the text view's edits.
        let editUndoManager = UndoManager()

        init(parent: MarkdownBodyEditor) {
            self.parent = parent
            renderedText = parent.text
            renderedTextUTF16Length = parent.text.utf16.count
            lastSeekRevision = parent.seekRevision
            if let boundary = parent.boundaryStartTime {
                wasBeforeBoundary = parent.playbackTime < boundary
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editUndoManager
        }

        func recordRenderedText(_ text: String) {
            renderedText = text
            renderedTextUTF16Length = text.utf16.count
        }

        func prepareForTextReplacement() {
            guard let textView else { return }
            cancelBoundaryFade()
            let fullRange = NSRange(location: 0, length: renderedTextUTF16Length)
            restoreNormalAppearance(in: fullRange)
            if let appliedNavigationRange,
               NSMaxRange(appliedNavigationRange) <= fullRange.length {
                textView.layoutManager?.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: appliedNavigationRange
                )
            }
            appliedNavigationRange = nil
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            let newText = textView.string
            recordRenderedText(newText)
            let stringLength = renderedTextUTF16Length
            if let appliedNavigationRange,
               NSMaxRange(appliedNavigationRange) <= stringLength {
                textView.layoutManager?.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: appliedNavigationRange
                )
            }
            appliedHighlightRange = nil
            appliedNavigationRange = nil
            parent.onUserEdit(newText)
        }

        func updateHighlights() {
            guard let textView else { return }
            let stringLength = renderedTextUTF16Length
            let fullRange = NSRange(location: 0, length: stringLength)
            let seekChanged = lastSeekRevision != parent.seekRevision
            lastSeekRevision = parent.seekRevision

            if parent.isEditable {
                cancelBoundaryFade()
                restoreNormalAppearance(in: fullRange)
                if let boundary = parent.boundaryStartTime {
                    wasBeforeBoundary = parent.playbackTime < boundary
                }
                applyNavigationHighlight(to: textView, stringLength: stringLength)
                return
            }

            if let boundary = parent.boundaryStartTime {
                if seekChanged {
                    cancelBoundaryFade()
                    wasBeforeBoundary = parent.playbackTime <= boundary
                }
                if boundary == 0, !parent.isPlaying, parent.playbackTime <= 0.001 {
                    wasBeforeBoundary = true
                }
                if parent.playbackTime < boundary {
                    cancelBoundaryFade()
                    wasBeforeBoundary = true
                    updateActiveHighlight(
                        parent.highlightRange,
                        fullRange: fullRange,
                        stringLength: stringLength
                    )
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                } else if boundaryFadeTask != nil {
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                } else if parent.isPlaying, wasBeforeBoundary {
                    let previousActiveRange = appliedHighlightRange
                    wasBeforeBoundary = false
                    restoreNormalAppearance(in: fullRange)
                    startBoundaryFade(
                        previousActiveRange: previousActiveRange,
                        cueRange: parent.boundaryCueRange,
                        stringLength: stringLength
                    )
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                } else if parent.playbackTime >= boundary {
                    restoreNormalAppearance(in: fullRange)
                    wasBeforeBoundary = false
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                }
            } else {
                cancelBoundaryFade()
            }

            updateActiveHighlight(
                parent.highlightRange,
                fullRange: fullRange,
                stringLength: stringLength
            )
            applyNavigationHighlight(to: textView, stringLength: stringLength)
        }

        func cancelBoundaryFade() {
            boundaryFadeTask?.cancel()
            boundaryFadeTask = nil
            for range in boundaryFadeRanges { clearPlaybackAttributes(in: range) }
            boundaryFadeRanges = []
        }

        private func clearPlaybackAttributes(in range: NSRange) {
            TranscriptPlaybackWordStyle.clearPlaybackAttributes(
                from: textView?.layoutManager,
                in: range
            )
        }

        private func updateActiveHighlight(
            _ nextRange: NSRange?,
            fullRange: NSRange,
            stringLength: Int
        ) {
            let validNextRange = nextRange.flatMap {
                NSMaxRange($0) <= stringLength ? $0 : nil
            }
            guard appliedHighlightRange != validNextRange else { return }

            if let appliedHighlightRange {
                clearPlaybackAttributes(in: appliedHighlightRange)
                if transcriptIsSubdued {
                    TranscriptPlaybackWordStyle.subdueTranscript(
                        in: textView?.layoutManager,
                        range: appliedHighlightRange
                    )
                }
            }
            appliedHighlightRange = validNextRange

            guard let validNextRange else {
                restoreNormalAppearance(in: fullRange)
                return
            }
            if !transcriptIsSubdued {
                TranscriptPlaybackWordStyle.subdueTranscript(
                    in: textView?.layoutManager,
                    range: fullRange
                )
                transcriptIsSubdued = true
            }
            TranscriptPlaybackWordStyle.illuminateWord(
                in: textView?.layoutManager,
                range: validNextRange
            )
        }

        /// Returning to the normal edited-note appearance is an O(document)
        /// operation, but now happens only when karaoke begins/ends or editing
        /// starts—not on every playback tick.
        private func restoreNormalAppearance(in fullRange: NSRange) {
            if let appliedHighlightRange {
                clearPlaybackAttributes(in: appliedHighlightRange)
                self.appliedHighlightRange = nil
            }
            if transcriptIsSubdued {
                textView?.layoutManager?.removeTemporaryAttribute(
                    .foregroundColor,
                    forCharacterRange: fullRange
                )
                transcriptIsSubdued = false
            }
        }

        private func startBoundaryFade(
            previousActiveRange: NSRange?,
            cueRange: NSRange?,
            stringLength: Int
        ) {
            cancelBoundaryFade()
            boundaryFadeRanges = [previousActiveRange, cueRange].compactMap { range in
                guard let range, NSMaxRange(range) <= stringLength else { return nil }
                return range
            }
            boundaryFadeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let frameCount = 45
                for frame in 0...frameCount {
                    guard !Task.isCancelled else { return }
                    let progress = CGFloat(frame) / CGFloat(frameCount)
                    self.applyBoundaryFadeFrame(
                        progress: progress,
                        previousActiveRange: previousActiveRange,
                        cueRange: cueRange,
                        stringLength: stringLength
                    )
                    if frame < frameCount {
                        try? await Task.sleep(for: .milliseconds(33))
                    }
                }
                guard !Task.isCancelled else { return }
                for range in self.boundaryFadeRanges {
                    self.clearPlaybackAttributes(in: range)
                }
                self.boundaryFadeRanges = []
                self.boundaryFadeTask = nil
            }
        }

        private func applyBoundaryFadeFrame(
            progress: CGFloat,
            previousActiveRange: NSRange?,
            cueRange: NSRange?,
            stringLength: Int
        ) {
            guard let layoutManager = textView?.layoutManager else { return }
            for range in boundaryFadeRanges { clearPlaybackAttributes(in: range) }
            let normal = NSColor.labelColor

            if let previousActiveRange, NSMaxRange(previousActiveRange) <= stringLength {
                if progress < 1 {
                    let glow = NSShadow()
                    glow.shadowOffset = .zero
                    glow.shadowBlurRadius = 4 * (1 - progress)
                    glow.shadowColor = normal.withAlphaComponent(0.42 * (1 - progress))
                    layoutManager.addTemporaryAttribute(
                        .shadow, value: glow, forCharacterRange: previousActiveRange
                    )
                }
            }

            if let cueRange, NSMaxRange(cueRange) <= stringLength {
                let red = NSColor.systemRed.blended(withFraction: progress, of: normal) ?? normal
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: red, forCharacterRange: cueRange
                )
                if progress < 1 {
                    let glow = NSShadow()
                    glow.shadowOffset = .zero
                    glow.shadowBlurRadius = 5 * (1 - progress)
                    glow.shadowColor = NSColor.systemRed.withAlphaComponent(0.55 * (1 - progress))
                    layoutManager.addTemporaryAttribute(
                        .shadow, value: glow, forCharacterRange: cueRange
                    )
                }
            }
        }

        private func applyNavigationHighlight(to textView: NSTextView, stringLength: Int) {
            let oldRange = appliedNavigationRange
            let changed = oldRange != parent.navigationHighlightRange
            if changed, let oldRange {
                textView.layoutManager?.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: oldRange
                )
            }
            appliedNavigationRange = parent.navigationHighlightRange
            guard let range = parent.navigationHighlightRange,
                  NSMaxRange(range) <= stringLength else { return }
            textView.layoutManager?.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.45),
                forCharacterRange: range
            )
            if changed { textView.scrollRangeToVisible(range) }
        }
    }
}
