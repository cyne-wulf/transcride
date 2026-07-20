import AppKit
import SwiftUI

private struct EditorLinkDecorationResult: Sendable {
    var unresolved: [Range<Int>]
    var ambiguous: [(range: Range<Int>, tooltip: String)]
}

/// Production edit-session policy shared by the mounted Workbench and its
/// real-WebKit integration coverage. The first actual body mutation creates
/// the fork; undoing all the way back to an initially-unforked body removes
/// that marker so a no-change Save remains byte- and state-neutral.
struct TranscriptEditSessionCoordinator: Equatable, Sendable {
    struct Completion: Equatable, Sendable {
        var hasActualChange: Bool
        var restoresUnforkedState: Bool
        var isForkedAfterSave: Bool
    }

    let initialBody: String
    let startedForked: Bool
    private(set) var receivedBodyMutation = false

    mutating func apply(_ body: String, to document: inout FrontmatterDocument) -> Bool {
        guard body != document.body else { return false }
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(body)
        if !startedForked, body == initialBody {
            editable.clearHandEdited()
        }
        document = editable.document
        receivedBodyMutation = true
        return true
    }

    func completion(for document: FrontmatterDocument) -> Completion {
        let changed = document.body != initialBody
        let restoresUnforked = !startedForked && !changed
        return Completion(
            hasActualChange: changed,
            restoresUnforkedState: restoresUnforked,
            isForkedAfterSave: !restoresUnforked && (document.handEdited || startedForked)
        )
    }
}

/// One secured CodeMirror host presents the immutable Original, read-only
/// Edited, and editable Edited projections while native owns persistence,
/// playback, recovery, and layer lifecycle.
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
    let loadedBodyRevision: EditorBodyRevision?
    let loadedContentRevision: Int
    let extensionState: ExtensionTranscriptState?
    @Binding var document: FrontmatterDocument?

    @State private var activeLayer: Layer = .original
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var editStartBody: String?
    @State private var editingStartedForked = false
    @State private var editingDidChange = false
    @State private var editSession: TranscriptEditSessionCoordinator?
    @State private var followingPaused = false
    @State private var pendingSave: Task<Void, Never>?
    @State private var saveScheduler = EditorSaveScheduler()
    @State private var needsSave = false
    @State private var copyConfirmed = false
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var searchNavigationRange: NSRange?
    @State private var handledNavigationRequestID: UUID?
    @State private var showingSpeakerRename = false
    @State private var isUpdatingSpeakerDetection = false
    @State private var forkOverride: Bool?
    @State private var editedPlaybackMap: EditedTranscriptPlaybackMap?
    @State private var editorController = CodeMirrorEditorController()
    @State private var baseBody = ""
    @State private var baseRevision: EditorBodyRevision?
    @State private var editorReady = false
    @State private var pendingConflict: PendingEditorConflict?
    @State private var showingEditorPreferences = false
    @State private var pendingEditingPosition: Int?
    @State private var recoveryDraft: EditorRecoveryDraft?
    @State private var editGeneration = 0
    @State private var originalViewState: CodeMirrorEditorController.Snapshot?
    @State private var editedViewState: CodeMirrorEditorController.Snapshot?
    @State private var requestedLayer: Layer?
    @State private var layerTransitionTask: Task<Void, Never>?
    @State private var layerTransitionInProgress = false
    @State private var linkIndex = EditorWikiLinkIndex(candidates: [])
    @State private var linkDecorationTask: Task<Void, Never>?
    @State private var linkDecorationGeneration = 0

    /// User-chosen display names for machine speaker ids (TRN-6), from the
    /// entry's frontmatter.
    private var speakerNames: [String: String] {
        document.map { SpeakerNames.names(in: $0) } ?? [:]
    }

    private var hasDetectedSpeakers: Bool {
        original?.segments.contains { $0.speaker != nil } == true
    }

    private var speakerDetectionEnabled: Bool {
        hasDetectedSpeakers && (document?.speakerDetectionEnabled ?? true)
    }

    private var hasSpeakers: Bool {
        hasDetectedSpeakers && speakerDetectionEnabled
    }

    private var isForked: Bool {
        forkOverride ?? loadedIsForked
    }

    /// The menu-bar Edit Note command remains available even though editing a
    /// forked note is normally re-entered by clicking its text directly.
    private var canEditNote: Bool {
        document != nil && !isEditing && !isSaving
            && (!isForked || viewedLayer == .edited)
            && !layerTransitionInProgress && recoveryDraft == nil && editorReady
    }

    private var canSaveNote: Bool {
        document != nil && isEditing && !isSaving
            && !layerTransitionInProgress && recoveryDraft == nil && editorReady
    }

    /// Snapshot of what this workbench can do, mirrored into AppModel for the
    /// menu bar (see the onChange in `body`).
    private var currentUIState: AppModel.WorkbenchUIState {
        AppModel.WorkbenchUIState(
            hasContent: document != nil || original != nil,
            canEditNote: canEditNote,
            canSaveNote: canSaveNote,
            isEditing: isEditing,
            isForked: isForked && original != nil,
            canToggleLayer: document != nil && original != nil && isForked
                && !isEditing && !isSaving && !layerTransitionInProgress
                && recoveryDraft == nil && editorReady,
            hasSpeakers: hasSpeakers,
            hasDetectedSpeakers: hasDetectedSpeakers,
            speakerDetectionEnabled: speakerDetectionEnabled,
            canToggleSpeakerDetection: hasDetectedSpeakers
                && !isEditing && !isSaving && !isUpdatingSpeakerDetection,
            viewedLayerIsOriginal: viewedLayer == .original,
            editorReady: editorReady,
            editorInputOwnsInput: model.editorInputOwnsInput,
            editorCanReplace: isEditing
        )
    }

    private var viewedLayer: Layer {
        if original == nil { return .edited }
        if isEditing { return .edited }
        return activeLayer
    }

    private var activeNavigationRange: NSRange? { searchNavigationRange }

    var body: some View {
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

            ZStack(alignment: .topTrailing) {
                layerContent

                if followingPaused, model.player.isPlaying {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            rebindEditorContext()
            rebuildLinkIndex()
            forkOverride = nil
            baseBody = document?.body ?? ""
            baseRevision = loadedBodyRevision
            synchronizeEditor(resetHistory: true)
        }
        .onChange(of: entry.relativePath) { oldPath, newPath in
            if editorController.editorEntryPath == oldPath {
                _ = model.editorLifecycleCoordinator.remapActiveDocument(
                    expectedOldPath: oldPath,
                    to: newPath
                )
            }
            rebindEditorContext()
        }
        .task(id: loadedContentRevision) {
            await rebuildEditedPlaybackMap()
        }
        .onChange(of: isEditing) { _, _ in synchronizeEditorMode() }
        .onChange(of: model.editorPreferences) { _, preferences in
            editorController.configure(preferences: preferences)
        }
        .onChange(of: model.snapshot?.root) { _, _ in rebuildLinkIndex() }
        .onChange(of: model.inNoteFindRequestRevision) { _, _ in
            editorController.execute("openFind")
        }
        .task(id: model.transcriptNavigationRequest?.id) {
            handleNavigationRequestIfNeeded()
        }
        .onChange(of: model.player.url) { _, _ in
            cueSearchNavigationIfPossible()
        }
        .onAppear {
            if isForked { activeLayer = .edited }
            rebuildLinkIndex()
            baseBody = document?.body ?? ""
            baseRevision = loadedBodyRevision
            bindEditorController()
            synchronizeEditor(resetHistory: true)
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
                    if canSaveNote { Task { await saveAndFinishEditing() } }
                } else if canEditNote {
                    beginEditing()
                }
            case .copyAsMarkdown:
                copyCurrentLayer()
            case .toggleLayer:
                if document != nil, !isEditing, original != nil, isForked {
                    requestLayer(activeLayer == .original ? .edited : .original)
                }
            case .toggleSpeakerDetection:
                setSpeakerDetectionEnabled(!speakerDetectionEnabled)
            case .renameSpeakers:
                if hasSpeakers, !isEditing, !isSaving { showingSpeakerRename = true }
            case .finishEditingForQuickMove:
                let entryPath = entry.relativePath
                Task {
                    let saved = await saveAndFinishEditing()
                    model.completeQuickMovePreparation(for: entryPath, saved: saved)
                }
            case .editorCommand(let command):
                editorController.execute(editorCommandName(command))
            case nil:
                break
            }
        }
        .onDisappear {
            linkDecorationTask?.cancel()
            model.workbenchUIState = AppModel.WorkbenchUIState()
            model.setEditorInputOwnsInput(false)
            Task {
                let prepared = await model.editorLifecycleCoordinator.prepare(
                    for: .workbenchTeardown,
                    participant: editorController
                )
                let recovered = prepared ? true : await persistCrashRecoveryDraft()
                if prepared || recovered {
                    model.editorLifecycleCoordinator.unregister(editorController)
                } else {
                    model.errorMessage = "The note could not be saved or preserved for recovery. Transcride kept the editor participant alive instead of discarding the only dirty buffer."
                }
            }
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
        .sheet(item: $pendingConflict) { pending in
            EditorConflictResolutionSheet(pending: pending) { resolved in
                Task { await applyConflictResolution(resolved, pending: pending) }
            }
        }
    }

    private var noteToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                layerStatusLabel
                Spacer(minLength: 4)

                ViewThatFits(in: .horizontal) {
                    expandedToolbarActions
                    compactToolbarActions
                }
                trailingToolbarControls(compact: false)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                compactToolbarActions
                    .labelStyle(.iconOnly)
                trailingToolbarControls(compact: true)
            }
        }
        .popover(isPresented: $showingEditorPreferences, arrowEdge: .bottom) {
            EditorPreferencesPopover()
        }
    }

    @ViewBuilder
    private func trailingToolbarControls(compact: Bool) -> some View {
        if document != nil {
            TranscriptLayerControl(
                state: TranscriptLayerControlState(
                    hasEditableNote: true,
                    originalAvailable: original != nil,
                    isForked: isForked,
                    layer: viewedLayer,
                    isEditing: isEditing,
                    isSaving: isSaving,
                    isTransitioning: layerTransitionInProgress,
                    isRecoveryBlocked: recoveryDraft != nil,
                    isEditorReady: editorReady
                ),
                compact: compact,
                onSelectOriginal: { requestLayer(.original) },
                onSelectEdited: { requestLayer(.edited) }
            )
            .fixedSize()
            .layoutPriority(2)
            .help("Switch between the immutable engine output and your edited note")

            TranscriptEditSaveAction(
                state: TranscriptEditSaveActionState(
                    hasEditableNote: true,
                    isForked: isForked,
                    viewedLayer: viewedLayer,
                    isEditing: isEditing,
                    isSaving: isSaving,
                    isTransitioning: layerTransitionInProgress,
                    isRecoveryBlocked: recoveryDraft != nil,
                    isEditorReady: editorReady
                ),
                onEdit: { beginEditing() },
                onSave: { Task { await saveAndFinishEditing() } }
            )
            .fixedSize()
            .layoutPriority(3)
        }
    }

    private var layerStatusLabel: some View {
        Label(
            viewedLayer == .original ? "Synced to audio" : "Markdown",
            systemImage: viewedLayer == .original
                ? "waveform.badge.magnifyingglass"
                : "text.document"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(viewedLayer == .original
            ? "The immutable Original transcript is synchronized to audio"
            : "Type plain Markdown: # headings, - lists, **bold**, and _italic_")
    }

    private var expandedToolbarActions: some View {
        HStack(spacing: 8) {
            speakerDetectionToolbarToggle
            speakerRenameToolbarButton
            recoveryToolbarMenu
            findToolbarButton
            appearanceToolbarButton
            copyToolbarButton
        }
    }

    private var compactToolbarActions: some View {
        Menu {
            if hasDetectedSpeakers {
                Toggle("Detect Speakers", isOn: speakerDetectionBinding)
                    .disabled(isEditing || isSaving || isUpdatingSpeakerDetection)
            }
            if hasSpeakers {
                Button("Rename Speakers") { showingSpeakerRename = true }
                    .disabled(isEditing || isSaving)
            }
            if let recoveryDraft {
                Menu("Recovery") {
                    recoveryMenuContents(recoveryDraft)
                }
            }
            Button("Find in Note") { model.requestInNoteFind() }
            Button("Editor Appearance") { showingEditorPreferences = true }
            Button(copyConfirmed ? "Copied" : "Copy as Markdown") { copyCurrentLayer() }
        } label: {
            Label("More Note Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 28, minHeight: 28)
        .fixedSize()
        .accessibilityLabel("More Note Actions")
    }

    @ViewBuilder
    private var speakerDetectionToolbarToggle: some View {
        if hasDetectedSpeakers {
            Toggle(isOn: speakerDetectionBinding) {
                Label("Detect Speakers", systemImage: "person.2.fill")
            }
            .toggleStyle(.button)
            .disabled(isEditing || isSaving || isUpdatingSpeakerDetection)
            .help(speakerDetectionEnabled
                ? "Hide speaker labels and grouping without discarding detection"
                : "Restore the cached speaker labels and grouping")
        }
    }

    @ViewBuilder
    private var speakerRenameToolbarButton: some View {
        if hasSpeakers {
            Button {
                showingSpeakerRename = true
            } label: {
                Label("Rename Speakers", systemImage: "person.2")
            }
            .disabled(isEditing || isSaving)
            .help("Rename Speaker 1, Speaker 2, … — or click a label in the transcript")
        }
    }

    @ViewBuilder
    private var recoveryToolbarMenu: some View {
        if let recoveryDraft {
            Menu("Recovery…") { recoveryMenuContents(recoveryDraft) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func recoveryMenuContents(_ draft: EditorRecoveryDraft) -> some View {
        Button("Save Recovered Draft") { Task { await saveRecoveredDraft(draft) } }
        Button("Review Conflict…") { presentRecoveryConflict() }
        Divider()
        Button("Discard Recovered Draft", role: .destructive) { discardRecoveryDraft(draft) }
    }

    private var findToolbarButton: some View {
        Button {
            model.requestInNoteFind()
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .accessibilityLabel("Find in Note")
        .help("Find in Note (⌘F)")
    }

    private var appearanceToolbarButton: some View {
        Button {
            showingEditorPreferences.toggle()
        } label: {
            Text("Aa").font(.body.weight(.semibold))
        }
        .accessibilityLabel("Editor Appearance")
        .help("Editor appearance and focus settings")
    }

    private var copyToolbarButton: some View {
        Button {
            copyCurrentLayer()
        } label: {
            Label(copyConfirmed ? "Copied" : "Copy as Markdown",
                  systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
        }
        .help("Copy this layer without frontmatter")
    }

    private var speakerDetectionBinding: Binding<Bool> {
        Binding(
            get: { speakerDetectionEnabled },
            set: { setSpeakerDetectionEnabled($0) }
        )
    }

    @ViewBuilder
    private var layerContent: some View {
        if viewedLayer == .original, wordMap == nil {
            ContentUnavailableView(
                "Original Unavailable",
                systemImage: "text.badge.xmark",
                description: Text("The timed engine transcript has not been created yet.")
            )
        } else if viewedLayer == .edited, document == nil {
            ContentUnavailableView(
                "No Editable Note",
                systemImage: "doc",
                description: Text("The transcript Markdown file has not been created yet.")
            )
        } else {
            ZStack {
                CodeMirrorEditorHost(controller: editorController)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                    .accessibilityLabel(viewedLayer == .original
                        ? "Original transcript synchronized to audio"
                        : isEditing ? "Edited transcript editor" : "Edited transcript")
                CodeMirrorPlaybackDriver(
                    controller: editorController,
                    layer: viewedLayer,
                    wordMap: wordMap,
                    editedMap: editedPlaybackMap,
                    entryHasAudio: entry.hasAudio,
                    knownTranscriptDuration: extensionState?.knownTranscriptDuration,
                    navigationRange: activeNavigationRange.map {
                        $0.location..<(NSMaxRange($0))
                    },
                    followingPaused: followingPaused
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func bindEditorController() {
        rebindEditorContext()
        editorController.onReady = { ready in
            editorReady = ready
            if recoveryDraft != nil { editorController.setFrozen(true, reason: "Unresolved recovery draft") }
        }
        editorController.onBodyChange = { body in applyEditorBodyMutation(body) }
        editorController.onFocusOwnership = { ownsInput in
            model.setEditorInputOwnsInput(ownsInput)
        }
        editorController.onEnterEditing = { position in beginEditing(at: position) }
        editorController.onLink = { payload in openEditorLink(payload) }
        editorController.onWebProcessRecovery = {
            let identity = editorController.editorDocumentIdentity
            let dirtyEditedBuffer = viewedLayer == .edited
                && (needsSave || editingDidChange)
                && editorController.acknowledgedBody != baseBody
                && identity == editorController.editorDocumentIdentity
            guard dirtyEditedBuffer else {
                model.transcriptNoticeMessage = "The editor process restarted and restored the acknowledged note state."
                return
            }
            let preserved = await persistCrashRecoveryDraft()
            model.errorMessage = preserved
                ? "The editor process restarted. Transcride restored the last acknowledged text; the final unacknowledged keystroke may need to be re-entered."
                : "The editor process restarted, but its dirty buffer could not be preserved durably. The editor remains blocked so the acknowledged text is not discarded."
        }
        editorController.onUserScroll = {
            if model.player.isPlaying { followingPaused = true }
        }
        editorController.onFontSizePreference = { size in
            var preferences = model.editorPreferences
            preferences.fontSize = size
            model.updateEditorPreferences(preferences)
        }
        editorController.prepareTransition = { reason in
            guard let snapshot = await editorController.snapshot(reason: "transition") else {
                return await persistCrashRecoveryDraft()
            }
            if snapshot.mode == .original {
                originalViewState = snapshot
            } else {
                editedViewState = snapshot
                applyEditorBodyMutation(snapshot.text)
            }
            if reason == .externalReload {
                // A watcher reload may arrive inside the 600 ms debounce.
                // Promote the acknowledged dirty generation into the ordered
                // compare-save pipeline before EntryDetail is allowed to read
                // disk. A disjoint external body edit is mapped back into the
                // live editor; an overlap persists recovery and blocks reload.
                return await prepareLatestGenerationForExternalReload()
            }
            if isEditing, needsSave || editingDidChange {
                return await saveAndFinishEditing()
            }
            if needsSave, let document {
                return await saveThroughScheduler(
                    document.body,
                    document: document,
                    generation: editGeneration,
                    source: .transition
                )
            }
            return await flushPendingSaves()
        }
        model.editorLifecycleCoordinator.register(editorController)
        Task { await restoreRecoveryDraftIfNeeded() }
    }

    private func rebindEditorContext() {
        let current = editorController.editorDocumentIdentity
        let nextGeneration = current.path == entry.relativePath
            && current.documentID == entry.folderName.timestamp
            ? current.generation
            : current.generation &+ 1
        editorController.rebindEditorDocument(to: EditorDocumentIdentity(
            vaultID: recoveryStore?.vaultID ?? model.vaultURL?.standardizedFileURL.path ?? "",
            documentID: entry.folderName.timestamp,
            path: entry.relativePath,
            generation: nextGeneration
        ))
        editorController.onOriginalPosition = { position in
            searchNavigationRange = nil
            if wordMap?.speakerLabel(containingUTF16Offset: position) != nil {
                showingSpeakerRename = true
                return
            }
            guard let wordIndex = wordMap?.wordIndex(atOrBeforeUTF16Offset: position),
                  let time = wordMap?.startTime(forWordAt: wordIndex) else { return }
            model.player.seek(to: time)
        }
    }

    private func synchronizeEditor(resetHistory: Bool) {
        let mode: EditorMode = viewedLayer == .original
            ? .original
            : isEditing ? .editedEditing : .editedView
        let body = viewedLayer == .original ? (wordMap?.renderedText ?? "") : (document?.body ?? "")
        let savedState = viewedLayer == .original ? originalViewState : editedViewState
        let selection = pendingEditingPosition.map { [EditorSelectionState(anchor: $0, head: $0)] }
            ?? savedState?.selection
        editorController.replaceDocument(
            body,
            mode: mode,
            resetHistory: resetHistory,
            selection: selection,
            scrollTop: savedState?.scrollTop
        )
        pendingEditingPosition = nil
        editorController.configure(mode: mode, preferences: model.editorPreferences)
        updateLinkDecorations(for: body)
    }

    private func synchronizeEditorMode() {
        guard !isSaving else { return }
        let mode: EditorMode = viewedLayer == .original
            ? .original
            : isEditing ? .editedEditing : .editedView
        if let position = pendingEditingPosition {
            pendingEditingPosition = nil
            editorController.replaceDocument(
                document?.body ?? "",
                mode: mode,
                resetHistory: false,
                selection: [EditorSelectionState(anchor: position, head: position)]
            )
        } else {
            editorController.configure(mode: mode, preferences: model.editorPreferences)
        }
    }

    @discardableResult
    private func requestLayer(_ destination: Layer) -> Task<Void, Never>? {
        guard !isEditing, recoveryDraft == nil else { return nil }
        requestedLayer = destination
        if let layerTransitionTask { return layerTransitionTask }

        layerTransitionInProgress = true
        let task = Task { @MainActor in
            while let destination = requestedLayer {
                requestedLayer = nil
                guard await performLayerTransition(to: destination) else {
                    requestedLayer = nil
                    break
                }
            }
            layerTransitionInProgress = false
            layerTransitionTask = nil
        }
        layerTransitionTask = task
        return task
    }

    @MainActor
    private func performLayerTransition(to destination: Layer) async -> Bool {
        let source = viewedLayer
        guard destination != source else { return true }
        guard destination != .original || original != nil else { return false }
        guard let snapshot = await editorController.snapshot(reason: "layer-change") else {
            return false
        }

        if source == .original {
            originalViewState = snapshot
        } else {
            editedViewState = snapshot
            applyEditorBodyMutation(snapshot.text)
        }

        guard await flushPendingSaves() else { return false }
        if needsSave, let document {
            guard await saveThroughScheduler(
                document.body,
                document: document,
                generation: editGeneration,
                source: .transition
            ) else { return false }
            needsSave = false
        }

        let destinationBody = destination == .original
            ? (wordMap?.renderedText ?? "")
            : (document?.body ?? "")
        let destinationState = destination == .original ? originalViewState : editedViewState
        let destinationMode: EditorMode = destination == .original ? .original : .editedView
        guard await editorController.replaceDocumentAndWait(
            destinationBody,
            mode: destinationMode,
            resetHistory: false,
            selection: destinationState?.selection,
            scrollTop: destinationState?.scrollTop
        ) else { return false }

        activeLayer = destination
        editorController.configure(mode: destinationMode, preferences: model.editorPreferences)
        updateLinkDecorations(for: destinationBody)
        return true
    }

    private func editorCommandName(_ command: AppModel.EditorCommandAction) -> String {
        switch command {
        case .find: "openFind"
        case .replace: "openFind"
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        case .undo: "undo"
        case .redo: "redo"
        }
    }

    private func openEditorLink(_ payload: [String: Any]) {
        if payload["kind"] as? String == "markdownLink",
           let destination = payload["destination"] as? String,
           let url = EditorExternalLinkPolicy.allowedURL(destination) {
            NSWorkspace.shared.open(url)
            return
        }
        guard payload["kind"] as? String == "wikilink",
              let target = payload["target"] as? String else { return }
        guard let resolution = linkIndex.resolve(target: target) else { return }
        if resolution.isAmbiguous {
            model.errorMessage = "Multiple notes match “\(target)”. Opened the most recently modified match."
        }
        model.requestEntrySelection(resolution.candidate.relativePath)
    }

    private func rebuildLinkIndex() {
        let entries = model.snapshot?.allEntries ?? []
        linkIndex = EditorWikiLinkIndex(candidates: entries.map {
            EditorWikiLinkCandidate(
                relativePath: $0.relativePath,
                title: $0.title ?? $0.displayTitle,
                modified: $0.modified
            )
        })
        let body = viewedLayer == .original
            ? (wordMap?.renderedText ?? "") : (document?.body ?? "")
        updateLinkDecorations(for: body)
    }

    private func updateLinkDecorations(for body: String) {
        linkDecorationTask?.cancel()
        linkDecorationGeneration &+= 1
        let generation = linkDecorationGeneration
        let index = linkIndex
        linkDecorationTask = Task { @MainActor in
            // Body analysis is coalesced while typing and never blocks the
            // AppKit/SwiftUI input or 30 Hz playback paths.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                var unresolved: [Range<Int>] = []
                var ambiguous: [(range: Range<Int>, tooltip: String)] = []
                for link in EditorWikiLinkParser.links(in: body) {
                    guard let resolution = index.resolve(link) else {
                        unresolved.append(link.range.from..<link.range.to)
                        continue
                    }
                    if resolution.isAmbiguous {
                        let choices = resolution.titleMatches
                            .map(\.relativePath).joined(separator: ", ")
                        ambiguous.append((
                            link.range.from..<link.range.to,
                            "Ambiguous link: \(choices)"
                        ))
                    }
                }
                return EditorLinkDecorationResult(
                    unresolved: unresolved,
                    ambiguous: ambiguous
                )
            }.value
            guard !Task.isCancelled,
                  generation == linkDecorationGeneration,
                  (viewedLayer == .original
                    ? wordMap?.renderedText ?? ""
                    : document?.body ?? "") == body else { return }
            editorController.setLinkDecorations(
                unresolved: result.unresolved,
                ambiguous: result.ambiguous
            )
        }
    }

    private func beginEditing(at position: Int? = nil) {
        guard let document, !isSaving, !layerTransitionInProgress, recoveryDraft == nil,
              editorReady, !isForked || viewedLayer == .edited else { return }
        editingStartedForked = isForked
        editingDidChange = false
        editStartBody = document.body
        editSession = TranscriptEditSessionCoordinator(
            initialBody: document.body,
            startedForked: isForked
        )
        activeLayer = .edited
        pendingEditingPosition = position
        isEditing = true
    }

    private func setSpeakerDetectionEnabled(_ enabled: Bool) {
        guard hasDetectedSpeakers,
              enabled != speakerDetectionEnabled,
              !isEditing, !isSaving, !isUpdatingSpeakerDetection else { return }
        isUpdatingSpeakerDetection = true
        Task {
            await model.setSpeakerDetectionEnabled(enabled, for: entry)
            isUpdatingSpeakerDetection = false
        }
    }

    @MainActor
    @discardableResult
    private func saveAndFinishEditing() async -> Bool {
        if recoveryDraft != nil {
            presentRecoveryConflict()
            return false
        }
        guard isEditing else { return true }
        if isSaving {
            // A menu/shortcut may request Quick Move while an explicit Save is
            // already in flight. Await that exact edit session instead of
            // clearing the move request prematurely or starting a second save.
            while isSaving {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return !isEditing
        }
        isSaving = true
        guard await editorController.setFrozenAndWait(true, reason: "Saving note") else {
            isSaving = false
            return false
        }
        guard let snapshot = await editorController.snapshot(reason: "explicit-save") else {
            _ = await editorController.setFrozenAndWait(false)
            isSaving = false
            return false
        }
        applyEditorBodyMutation(snapshot.text)
        guard let document else {
            _ = await editorController.setFrozenAndWait(false)
            isSaving = false
            return false
        }

        guard await flushPendingSaves() else {
            _ = await editorController.setFrozenAndWait(false)
            isSaving = false
            return false
        }

        let completion = editSession?.completion(for: document)
        let hasActualChange = completion?.hasActualChange ?? (document.body != editStartBody)
        let restoreUnforkedState = completion?.restoresUnforkedState
            ?? (!editingStartedForked && !hasActualChange)
        let savedIsForked = completion?.isForkedAfterSave
            ?? (!restoreUnforkedState && (document.handEdited || editingStartedForked))

        if editingDidChange || needsSave {
            guard await saveThroughScheduler(
                document.body,
                document: document,
                clearHandEdited: restoreUnforkedState,
                generation: editGeneration,
                source: .explicitSave
            ) else {
                if recoveryDraft == nil, pendingConflict == nil {
                    _ = await editorController.setFrozenAndWait(false)
                }
                isSaving = false
                return false
            }
        }

        let destinationLayer: Layer = original != nil && !savedIsForked ? .original : .edited
        let finalMode: EditorMode = destinationLayer == .original ? .original : .editedView
        let finalBody = destinationLayer == .original
            ? (wordMap?.renderedText ?? "")
            : (self.document?.body ?? "")
        let finalState = destinationLayer == .original ? originalViewState : editedViewState
        guard await editorController.replaceDocumentAndWait(
            finalBody,
            mode: finalMode,
            resetHistory: false,
            selection: finalState?.selection,
            scrollTop: finalState?.scrollTop
        ) else {
            _ = await editorController.setFrozenAndWait(false)
            isSaving = false
            return false
        }

        guard await editorController.setFrozenAndWait(false) else {
            isSaving = false
            return false
        }

        NSApp.keyWindow?.makeFirstResponder(nil)
        needsSave = false
        isEditing = false
        editStartBody = nil
        editingDidChange = false
        editingStartedForked = false
        editSession = nil
        activeLayer = destinationLayer
        if destinationLayer == .original {
            forkOverride = false
            editedPlaybackMap = nil
        } else {
            await rebuildEditedPlaybackMap()
            forkOverride = true
        }
        isSaving = false
        return true
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

    private func applyEditorBodyMutation(_ newBody: String) {
        guard viewedLayer == .edited, var document, newBody != document.body else { return }
        searchNavigationRange = nil
        if isEditing, var session = editSession {
            guard session.apply(newBody, to: &document) else { return }
            editSession = session
        } else {
            var editable = TranscriptEditDocument(document: document)
            editable.replaceBody(newBody)
            document = editable.document
        }
        self.document = document
        updateLinkDecorations(for: newBody)
        forkOverride = document.handEdited || editingStartedForked
        activeLayer = .edited
        needsSave = true
        if isEditing { editingDidChange = true }
        editGeneration &+= 1
        let generation = editGeneration

        pendingSave?.cancel()
        let operation = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                if self.document?.body == newBody,
                   await saveThroughScheduler(
                    newBody,
                    document: document,
                    generation: generation,
                    cancelDebounce: false
                   ) {
                    if self.document?.body == newBody { needsSave = false }
                }
            } catch is CancellationError {
                // A newer keystroke replaced this pending write.
            } catch {
                // `saveTranscriptBody` presents file-system errors centrally.
            }
        }
        pendingSave = operation
    }

    @MainActor
    private func flushPendingSaves() async -> Bool {
        let debounce = pendingSave
        debounce?.cancel()
        pendingSave = nil
        await debounce?.value
        return await saveScheduler.drain()
    }

    @MainActor
    private func prepareLatestGenerationForExternalReload() async -> Bool {
        // First join any debounce/save that was already present when the
        // watcher fired. A new edit can arrive during this await; the
        // admission loop below observes and persists that newer generation.
        guard await flushPendingSaves() else {
            editorController.setFrozen(true, reason: "External reload save failed")
            _ = await persistCrashRecoveryDraft()
            return false
        }
        let identity = editorController.editorDocumentIdentity
        let admitted = await EditorExternalReloadAdmission.saveLatest(
            currentState: {
                guard editorController.editorDocumentIdentity == identity,
                      let document else { return nil }
                return EditorExternalReloadAdmissionState(
                    identity: identity,
                    generation: editGeneration,
                    body: document.body,
                    baselineBody: baseBody,
                    needsSave: needsSave
                )
            },
            save: { state in
                guard state.identity == editorController.editorDocumentIdentity,
                      let document else { return false }
                return await saveThroughScheduler(
                    document.body,
                    document: document,
                    generation: editGeneration,
                    source: .transition
                )
            }
        )
        guard admitted else {
            editorController.setFrozen(
                true,
                reason: "Latest edit could not be made durable before reload"
            )
            _ = await persistCrashRecoveryDraft()
            model.errorMessage = model.errorMessage
                ?? "The note changed while an external reload was being prepared. The reload was blocked and the editor was frozen so the latest text could not be discarded."
            return false
        }
        return true
    }

    @MainActor
    private func saveThroughScheduler(
        _ body: String,
        document: FrontmatterDocument,
        clearHandEdited: Bool = false,
        generation: Int,
        source: EditorSaveScheduler.Source = .autosave,
        cancelDebounce: Bool = true
    ) async -> Bool {
        if cancelDebounce {
            let debounce = pendingSave
            debounce?.cancel()
            pendingSave = nil
            await debounce?.value
        }
        let identity = editorController.editorDocumentIdentity
        let ticket = EditorSaveScheduler.Ticket(
            identity: identity,
            generation: generation,
            body: body,
            source: source
        )
        return await saveScheduler.enqueue(ticket) { ticket in
            guard editorController.editorDocumentIdentity == ticket.identity else { return false }
            let effectiveBody: String
            let effectiveDocument: FrontmatterDocument
            let effectiveGeneration: Int
            switch ticket.source {
            case .autosave, .transition:
                if let liveDocument = self.document,
                   ticket.generation <= self.editGeneration {
                    effectiveBody = liveDocument.body
                    effectiveDocument = liveDocument
                    effectiveGeneration = self.editGeneration
                } else {
                    effectiveBody = ticket.body
                    effectiveDocument = document
                    effectiveGeneration = ticket.generation
                }
            case .explicitSave, .conflictResolution, .recovery:
                effectiveBody = ticket.body
                effectiveDocument = document
                effectiveGeneration = ticket.generation
            }
            return await persistEditorBody(
                effectiveBody,
                document: effectiveDocument,
                clearHandEdited: clearHandEdited,
                generation: effectiveGeneration,
                identity: ticket.identity
            )
        }
    }

    @MainActor
    private func persistEditorBody(
        _ body: String,
        document: FrontmatterDocument,
        clearHandEdited: Bool = false,
        generation: Int,
        identity: EditorDocumentIdentity
    ) async -> Bool {
        guard editorController.editorDocumentIdentity == identity else { return false }
        var mergeBase = baseBody
        var expectedRevision = baseRevision ?? EditorBodyRevision(body: mergeBase)
        var candidate = body

        // An external editor may change the file again between any read and
        // compare-save. Continue from the newly acknowledged disk baseline
        // until one exact revision saves or a genuine overlap is durably
        // represented. A bounded guard prevents a hostile writer from keeping
        // the main-actor transaction alive forever.
        for _ in 0..<16 {
            guard editorController.editorDocumentIdentity == identity,
                  identity.path == editorController.editorEntryPath else { return false }
            guard let result = await model.compareAndSaveTranscriptBody(
                candidate,
                expectedRevision: expectedRevision,
                markHandEdited: !clearHandEdited && document.handEdited,
                clearHandEdited: clearHandEdited,
                atEntryPath: identity.path
            ) else { return false }
            guard editorController.editorDocumentIdentity == identity else { return false }

            switch result {
            case .saved(let saved, let revision):
                let completionIsCurrent = generation == editGeneration
                    && self.document?.body == body
                if completionIsCurrent {
                    baseBody = saved.body
                    baseRevision = revision
                    if saved.body != body {
                        let externalPatches = EditorBodyMerger.utf16Patches(
                            from: body,
                            to: saved.body
                        )
                        guard await editorController.applyExternalChangesAndWait(
                            externalPatches,
                            resultingBody: saved.body,
                            mode: isEditing ? .editedEditing : .editedView
                        ) else {
                            editorController.setFrozen(
                                true,
                                reason: "Could not reconcile the external edit"
                            )
                            model.errorMessage = "The merged note was saved, but the editor could not safely map its Undo history. Reopen the note before editing again."
                            self.document = saved
                            return false
                        }
                    }
                    self.document = saved
                    needsSave = false
                    finishRecoveryAfterDurableSave()
                    return true
                }

                // A newer local generation was derived from `body` while
                // this compare-save was awaiting disk. Rebase that live body
                // onto the exact bytes this operation actually saved before
                // advancing the authoritative baseline. Otherwise the queued
                // newer save could write its pre-external body over a
                // disjoint external hunk.
                guard let liveDocument = self.document else { return false }
                switch EditorSaveLineage.rebaseNewerBody(
                    savedInput: body,
                    newerBody: liveDocument.body,
                    savedDiskBody: saved.body
                ) {
                case .merged(let rebased):
                    if rebased.body != liveDocument.body {
                        let externalPatches = EditorBodyMerger.utf16Patches(
                            from: liveDocument.body,
                            to: rebased.body
                        )
                        guard await editorController.applyExternalChangesAndWait(
                            externalPatches,
                            resultingBody: rebased.body,
                            mode: isEditing ? .editedEditing : .editedView
                        ) else {
                            editorController.setFrozen(
                                true,
                                reason: "Could not rebase the newer local edit"
                            )
                            model.errorMessage = "A newer local edit could not be safely rebased after the disk changed. The editor was frozen without overwriting the external text."
                            return false
                        }
                    }
                    var rebasedDocument = saved
                    rebasedDocument.body = rebased.body
                    rebasedDocument.handEdited = liveDocument.handEdited
                    self.document = rebasedDocument
                    baseBody = saved.body
                    baseRevision = revision
                    needsSave = rebased.body != saved.body
                    return true

                case .conflict(let conflict):
                    guard let recoveryStore else {
                        editorController.setFrozen(true, reason: "Newer edit could not be rebased")
                        model.errorMessage = "A newer local edit overlapped an external change, and recovery storage was unavailable. The editor remains frozen."
                        return false
                    }
                    let draft = EditorRecoveryDraft(
                        id: recoveryDraftID(in: recoveryStore, identity: identity) ?? UUID(),
                        vaultID: recoveryStore.vaultID,
                        entryID: identity.documentID,
                        entryPath: identity.path,
                        base: body,
                        mine: liveDocument.body,
                        external: saved.body,
                        baseRevision: EditorBodyRevision(body: body),
                        externalRevision: revision
                    )
                    do { try recoveryStore.persist(draft) }
                    catch {
                        editorController.setFrozen(true, reason: "Conflict recovery failed")
                        model.errorMessage = "The newer overlapping edit could not be preserved for recovery: \(error.localizedDescription)"
                        return false
                    }
                    baseBody = saved.body
                    baseRevision = revision
                    recoveryDraft = draft
                    pendingSave = nil
                    editorController.setFrozen(true, reason: "Resolve the newer external edit conflict")
                    pendingConflict = PendingEditorConflict(
                        id: draft.id,
                        conflict: conflict,
                        externalRevision: revision
                    )
                    return false
                }

            case .conflict(let external, let externalRevision):
                switch EditorBodyMerger.merge(
                    base: mergeBase,
                    mine: candidate,
                    external: external.body
                ) {
                case .merged(let merged):
                    mergeBase = external.body
                    expectedRevision = externalRevision
                    candidate = merged.body
                    continue

                case .conflict(let conflict):
                    guard let recoveryStore else {
                        model.errorMessage = "Could not identify the active vault for conflict recovery. The note was not overwritten."
                        return false
                    }
                    let existingID = recoveryDraftID(
                        in: recoveryStore,
                        identity: identity
                    )
                    let draft = EditorRecoveryDraft(
                        id: existingID ?? UUID(),
                        vaultID: recoveryStore.vaultID,
                        entryID: identity.documentID,
                        entryPath: identity.path,
                        base: mergeBase,
                        mine: candidate,
                        external: external.body,
                        baseRevision: expectedRevision,
                        externalRevision: externalRevision
                    )
                    do { try recoveryStore.persist(draft) }
                    catch {
                        model.errorMessage = "Could not preserve the conflict recovery draft: \(error.localizedDescription)"
                        return false
                    }
                    recoveryDraft = draft
                    pendingSave = nil
                    editorController.setFrozen(true, reason: "Resolve the external edit conflict")
                    pendingConflict = PendingEditorConflict(
                        id: draft.id,
                        conflict: conflict,
                        externalRevision: externalRevision
                    )
                    return false
                }
            }
        }
        model.errorMessage = "The note kept changing on disk while Transcride was saving. The dirty editor remains open; pause the external writer and try again."
        return false
    }

    @MainActor
    private func applyConflictResolution(
        _ body: String,
        pending: PendingEditorConflict
    ) async {
        guard var document, let existingDraft = recoveryDraft else { return }
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(body)
        document = editable.document
        self.document = document
        baseBody = existingDraft.external
        baseRevision = pending.externalRevision
        editGeneration &+= 1
        let generation = editGeneration
        let saved = await saveThroughScheduler(
            body,
            document: document,
            generation: generation,
            source: .conflictResolution
        )
        guard saved, recoveryDraft == nil, let savedDocument = self.document else {
            model.errorMessage = model.errorMessage
                ?? "The note changed again while resolving the conflict. The recovery draft was retained."
            return
        }
        pendingConflict = nil
        needsSave = false
        _ = await editorController.replaceDocumentAndWait(
            savedDocument.body,
            mode: isEditing ? .editedEditing : .editedView,
            resetHistory: true
        )
    }

    private var recoveryStore: EditorRecoveryDraftStore? {
        guard let vaultURL = model.vaultURL else { return nil }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return EditorRecoveryDraftStore(
            rootDirectoryURL: base.appending(
                path: "Transcride/EditorRecovery",
                directoryHint: .isDirectory
            ),
            vaultID: EditorVaultIdentity.identifier(forRootURL: vaultURL)
        )
    }

    private func recoveryDraftID(
        in store: EditorRecoveryDraftStore,
        identity: EditorDocumentIdentity
    ) -> UUID? {
        if let recoveryDraft,
           recoveryDraft.vaultID == store.vaultID,
           recoveryDraft.entryID == identity.documentID {
            return recoveryDraft.id
        }
        return store.scanDrafts().drafts.last(where: {
            $0.vaultID == store.vaultID && $0.entryID == identity.documentID
        })?.id
    }

    private func finishRecoveryAfterDurableSave() {
        guard let draft = recoveryDraft, let recoveryStore else {
            if recoveryDraft != nil {
                model.errorMessage = "The note was saved, but the active vault identity is unavailable. Its recovery record was retained."
            }
            return
        }
        do {
            _ = try recoveryStore.deleteAfterResolution(id: draft.id, durablySaved: true)
            recoveryDraft = nil
            pendingConflict = nil
            editorController.setFrozen(false)
        } catch {
            model.errorMessage = "The note was saved, but its recovery record could not be removed. Transcride will retry later."
        }
    }

    private func presentRecoveryConflict() {
        guard let draft = recoveryDraft else { return }
        if case .conflict(let conflict) = EditorBodyMerger.merge(
            base: draft.base,
            mine: draft.mine,
            external: draft.external
        ) {
            pendingConflict = PendingEditorConflict(
                id: draft.id,
                conflict: conflict,
                externalRevision: draft.externalRevision
            )
        }
    }

    private func restoreRecoveryDraftIfNeeded() async {
        guard recoveryDraft == nil, let recoveryStore else { return }
        let scan = recoveryStore.scanDrafts()
        if !scan.failures.isEmpty {
            model.errorMessage = "Some editor recovery records are damaged and were isolated; valid drafts remain available."
        }
        let identity = editorController.editorDocumentIdentity
        guard let draft = scan.drafts.last(where: {
            $0.vaultID == recoveryStore.vaultID
                && $0.entryID == identity.documentID
        }),
              let currentDocument = await model.readTranscript(
                atEntryPath: identity.path
              ),
              editorController.editorDocumentIdentity == identity else { return }
        let currentExternal = currentDocument.body
        let currentRevision = EditorBodyRevision(body: currentExternal)
        let reconciled = EditorRecoveryDraft(
            id: draft.id,
            vaultID: recoveryStore.vaultID,
            entryID: draft.entryID,
            entryPath: identity.path,
            base: draft.base,
            mine: draft.mine,
            external: currentExternal,
            baseRevision: draft.baseRevision,
            externalRevision: currentRevision,
            timestamp: draft.timestamp
        )
        do { try recoveryStore.persist(reconciled) }
        catch {
            model.errorMessage = "The recovery record could not be reconciled with the current vault: \(error.localizedDescription)"
            return
        }
        recoveryDraft = reconciled
        if var document {
            var editable = TranscriptEditDocument(document: document)
            editable.replaceBody(reconciled.mine)
            self.document = editable.document
            forkOverride = true
            activeLayer = .edited
            needsSave = true
        }
        switch EditorBodyMerger.merge(base: reconciled.base, mine: reconciled.mine, external: reconciled.external) {
        case .conflict:
            isEditing = true
            editorController.setFrozen(true, reason: "Resolve the recovered conflict")
            presentRecoveryConflict()
        case .merged(let merged):
            if var document {
                var editable = TranscriptEditDocument(document: document)
                editable.replaceBody(merged.body)
                self.document = editable.document
            }
            var mergedDraft = reconciled
            mergedDraft.mine = merged.body
            do { try recoveryStore.persist(mergedDraft) }
            catch {
                model.errorMessage = "The reconciled recovery draft could not be retained: \(error.localizedDescription)"
                return
            }
            recoveryDraft = mergedDraft
            model.errorMessage = "Recovered an editor draft for this note. Save the note to finish recovery."
        }
    }

    @discardableResult
    private func persistCrashRecoveryDraft() async -> Bool {
        let identity = editorController.editorDocumentIdentity
        guard viewedLayer == .edited,
              needsSave || editingDidChange,
              editorController.acknowledgedBody != baseBody else { return true }
        func fail(_ message: String) -> Bool {
            editorController.setFrozen(true, reason: "Dirty note could not be preserved")
            model.errorMessage = message
            return false
        }
        guard let recoveryStore else {
            return fail("The dirty editor could not be preserved because the active vault identity is unavailable. The editor remains frozen.")
        }
        guard let external = await model.readTranscript(atEntryPath: identity.path) else {
            return fail("The dirty editor could not be preserved because its transcript is unavailable on disk. The editor remains frozen.")
        }
        guard editorController.editorDocumentIdentity == identity else {
            return fail("The note changed identity while recovery was being written. The editor remains frozen without discarding its acknowledged text.")
        }
        let draft = EditorRecoveryDraft(
            id: recoveryDraftID(in: recoveryStore, identity: identity) ?? UUID(),
            vaultID: recoveryStore.vaultID,
            entryID: identity.documentID,
            entryPath: identity.path,
            base: baseBody,
            mine: editorController.acknowledgedBody,
            external: external.body,
            baseRevision: baseRevision ?? EditorBodyRevision(body: baseBody),
            externalRevision: EditorBodyRevision(body: external.body)
        )
        do {
            try recoveryStore.persist(draft)
            recoveryDraft = draft
            return true
        } catch {
            return fail("The editor restarted and its recovery draft could not be written: \(error.localizedDescription)")
        }
    }

    private func saveRecoveredDraft(_ draft: EditorRecoveryDraft) async {
        guard var document else { return }
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(draft.mine)
        document = editable.document
        self.document = document
        editGeneration &+= 1
        let saved = await saveThroughScheduler(
            draft.mine,
            document: document,
            generation: editGeneration,
            source: .recovery
        )
        if saved, recoveryDraft == nil {
            needsSave = false
            _ = await editorController.setFrozenAndWait(false)
        }
    }

    private func discardRecoveryDraft(_ draft: EditorRecoveryDraft) {
        guard let recoveryStore else {
            model.errorMessage = "The active vault identity is unavailable, so the recovery record was retained."
            return
        }
        do {
            _ = try recoveryStore.deleteAfterResolution(id: draft.id, durablySaved: true)
            recoveryDraft = nil
            pendingConflict = nil
            needsSave = false
            if var document {
                document.body = draft.external
                self.document = document
                baseBody = draft.external
                baseRevision = draft.externalRevision
            }
            editorController.setFrozen(false)
            synchronizeEditor(resetHistory: true)
        } catch {
            model.errorMessage = "The recovery draft could not be discarded: \(error.localizedDescription)"
        }
    }

    private func handleNavigationRequestIfNeeded() {
        guard let request = model.transcriptNavigationRequest,
              request.hit.entryPath == entry.relativePath,
              handledNavigationRequestID != request.id else { return }
        handledNavigationRequestID = request.id
        Task { @MainActor in
            if isEditing {
                guard await saveAndFinishEditing() else {
                    handledNavigationRequestID = nil
                    return
                }
            }
            let destination: Layer = request.hit.layer == .original ? .original : .edited
            if let transition = requestLayer(destination) { await transition.value }
            guard viewedLayer == destination else {
                handledNavigationRequestID = nil
                return
            }
            searchNavigationRange = NSRange(request.hit.matchRange)
            cueSearchNavigationIfPossible()
        }
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
        }
        guard let time else { return }
        model.player.pause()
        model.player.seek(to: time)
    }

    private func copyCurrentLayer() {
        let markdown: String
        switch viewedLayer {
        case .original:
            markdown = wordMap?.renderedText ?? ""
        case .edited:
            markdown = document?.body.trimmingCharacters(in: .newlines) ?? ""
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

struct CodeMirrorPlaybackProjection: Equatable {
    var playback: Range<Int>?
    var navigation: [Range<Int>]
    var shouldFollow: Bool

    static func make(
        layer: TranscriptWorkbenchView.Layer,
        wordMap: TranscriptWordMap?,
        editedMap: EditedTranscriptPlaybackMap?,
        entryHasAudio: Bool,
        playerHasAudio: Bool,
        time: TimeInterval,
        isPlaying: Bool,
        knownTranscriptDuration: TimeInterval?,
        navigationRange: Range<Int>?,
        followingPaused: Bool
    ) -> Self {
        var playback: Range<Int>?
        if entryHasAudio, playerHasAudio,
           knownTranscriptDuration.map({ time <= $0 }) ?? true,
           let wordIndex = wordMap?.wordIndex(atTime: time) {
            playback = layer == .original
                ? wordMap?.range(forWordAt: wordIndex)
                : editedMap?.range(forWordAt: wordIndex)
        }
        var navigation = navigationRange.map { [$0] } ?? []
        if layer == .edited,
           let boundary = editedMap?.boundaryStartTime,
           let cue = editedMap?.cueRange,
           isPlaying, time >= boundary, time < boundary + 0.8 {
            navigation.append(cue)
        }
        return Self(
            playback: playback,
            navigation: navigation,
            shouldFollow: isPlaying && !followingPaused
        )
    }
}

private struct CodeMirrorPlaybackDriver: View {
    @Environment(AppModel.self) private var model
    let controller: CodeMirrorEditorController
    let layer: TranscriptWorkbenchView.Layer
    let wordMap: TranscriptWordMap?
    let editedMap: EditedTranscriptPlaybackMap?
    let entryHasAudio: Bool
    let knownTranscriptDuration: TimeInterval?
    let navigationRange: Range<Int>?
    let followingPaused: Bool

    private var projection: CodeMirrorPlaybackProjection {
        .make(
            layer: layer,
            wordMap: wordMap,
            editedMap: editedMap,
            entryHasAudio: entryHasAudio,
            playerHasAudio: model.player.url != nil,
            time: model.player.currentTime,
            isPlaying: model.player.isPlaying,
            knownTranscriptDuration: knownTranscriptDuration,
            navigationRange: navigationRange,
            followingPaused: followingPaused
        )
    }

    var body: some View {
        Color.clear
            .onChange(of: projection, initial: true) { _, value in
                controller.setDecorations(
                    playback: value.playback,
                    search: value.navigation,
                    followPlayback: value.shouldFollow
                )
            }
    }
}

private struct EditorPreferencesPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Text Size")
                Slider(value: fontSize, in: 12...28, step: 1)
                Text("\(model.editorPreferences.fontSize)")
                    .monospacedDigit().frame(width: 24)
            }
            Picker("Width", selection: width) {
                ForEach(EditorWidthPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Edited Alignment", selection: alignment) {
                ForEach(EditorAlignment.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Focus Mode", isOn: focusMode)
            Text("Original prose stays centered. Structured blocks stay left-aligned.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reset") { model.resetEditorPreferences() }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { Double(model.editorPreferences.fontSize) },
            set: { value in update { $0.fontSize = Int(value.rounded()) } }
        )
    }
    private var width: Binding<EditorWidthPreset> {
        Binding(get: { model.editorPreferences.width }, set: { value in update { $0.width = value } })
    }
    private var alignment: Binding<EditorAlignment> {
        Binding(get: { model.editorPreferences.editedAlignment }, set: { value in update { $0.editedAlignment = value } })
    }
    private var focusMode: Binding<Bool> {
        Binding(get: { model.editorPreferences.focusMode }, set: { value in update { $0.focusMode = value } })
    }
    private func update(_ mutation: (inout EditorPreferences) -> Void) {
        var preferences = model.editorPreferences
        mutation(&preferences)
        model.updateEditorPreferences(preferences)
    }
}

private struct PendingEditorConflict: Identifiable {
    var id: UUID
    var conflict: EditorMergeConflict
    var externalRevision: EditorBodyRevision
}

private struct EditorConflictResolutionSheet: View {
    let pending: PendingEditorConflict
    let onResolve: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [UUID: EditorConflictChoice] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resolve Note Conflict")
                .font(.title2.weight(.semibold))
            Text("The file changed outside Transcride. Choose the content to keep for each overlapping section. Your local text remains available until the resolved file is saved.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(pending.conflict.hunks.enumerated()), id: \.element.id) { index, hunk in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Conflict \(index + 1)").font(.headline)
                            Picker("Resolution", selection: Binding(
                                get: { choices[hunk.id] },
                                set: { choices[hunk.id] = $0 }
                            )) {
                                Text("Choose…").tag(EditorConflictChoice?.none)
                                Text("Keep Mine").tag(EditorConflictChoice?.some(.mine))
                                Text("Keep External").tag(EditorConflictChoice?.some(.external))
                                Text("Keep Both").tag(EditorConflictChoice?.some(.keepBoth))
                            }
                            .pickerStyle(.segmented)
                            HStack(alignment: .top, spacing: 12) {
                                conflictPreview("Mine", hunk.mine)
                                conflictPreview("External", hunk.external)
                            }
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Resolved Note") {
                    guard let body = pending.conflict.resolvedBody(choices: choices) else { return }
                    onResolve(body)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(choices.count != pending.conflict.hunks.count)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480)
    }

    private func conflictPreview(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(body.isEmpty ? "(deleted)" : body)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Layer selection remains separate from the stable Edit/Save action. A custom
/// control is used because a segmented Picker does not reliably invoke an
/// already-selected segment.
struct TranscriptLayerControlState: Equatable {
    var hasEditableNote: Bool
    var originalAvailable: Bool
    var isForked: Bool
    var layer: TranscriptWorkbenchView.Layer
    var isEditing: Bool
    var isSaving: Bool
    var isTransitioning = false
    var isRecoveryBlocked = false
    var isEditorReady = true

    var isVisible: Bool { hasEditableNote && originalAvailable && isForked }
    var originalSelected: Bool { layer == .original }
    var editedSelected: Bool { layer == .edited }
    var editedHighlighted: Bool { editedSelected }
    var editedTitle: String { "Edited" }
    private var interactionAvailable: Bool {
        isEditorReady && !isEditing && !isSaving && !isTransitioning && !isRecoveryBlocked
    }
    var originalEnabled: Bool { originalAvailable && interactionAvailable }
    var editedEnabled: Bool { interactionAvailable }
    var originalAccessibilityLabel: String { "Show Original Transcript" }
    var editedAccessibilityLabel: String { "Show Edited Note" }

    /// Both expanded and compact toolbar layouts keep this control last so it
    /// remains the stable top-right action while secondary controls collapse.
    var isPersistentCompactTrailingAction: Bool { isVisible }
}

struct TranscriptLayerControl: View {
    let state: TranscriptLayerControlState
    var compact = false
    let onSelectOriginal: () -> Void
    let onSelectEdited: () -> Void

    @ViewBuilder
    var body: some View {
        if state.isVisible {
            HStack(spacing: 1) {
                segment(
                    "Original",
                    highlighted: state.originalSelected,
                    selected: state.originalSelected,
                    accessibilityLabel: state.originalAccessibilityLabel
                ) {
                    onSelectOriginal()
                }
                .disabled(!state.originalEnabled)

                segment(
                    state.editedTitle,
                    highlighted: state.editedHighlighted,
                    selected: state.editedSelected,
                    accessibilityLabel: state.editedAccessibilityLabel
                ) {
                    onSelectEdited()
                }
                .disabled(!state.editedEnabled)
            }
            .padding(2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Transcript Layer")
            .accessibilityValue(state.originalSelected ? "Original" : "Edited")
            .accessibilityIdentifier("transcript-layer-control")
        }
    }

    private func segment(
        _ title: String,
        highlighted: Bool,
        selected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(minWidth: compact ? 44 : 58)
                .padding(.horizontal, compact ? 4 : 7)
                .padding(.vertical, 3)
                .foregroundStyle(Color.primary)
                .background(
                    highlighted ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(highlighted ? Color.accentColor : Color.clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TranscriptEditSaveActionState: Equatable {
    var hasEditableNote: Bool
    var isForked = false
    var viewedLayer: TranscriptWorkbenchView.Layer = .original
    var isEditing: Bool
    var isSaving: Bool
    var isTransitioning: Bool
    var isRecoveryBlocked: Bool
    var isEditorReady = true

    var isVisible: Bool {
        hasEditableNote && (isEditing || !isForked || viewedLayer == .edited)
    }
    var title: String { isEditing ? (isSaving ? "Saving…" : "Save") : "Edit" }
    var accessibilityLabel: String {
        if isSaving { return "Saving Edited Note" }
        return isEditing ? "Save Edited Note" : "Edit Note"
    }
    var accessibilityValue: String? { isSaving ? "Busy" : nil }
    var isEnabled: Bool {
        hasEditableNote && isEditorReady && !isSaving && !isTransitioning && !isRecoveryBlocked
    }
}

struct TranscriptEditSaveAction: View {
    let state: TranscriptEditSaveActionState
    let onEdit: () -> Void
    let onSave: () -> Void

    var body: some View {
        if state.isVisible {
            Button {
                if state.isEditing { onSave() } else { onEdit() }
            } label: {
                HStack(spacing: 5) {
                    if state.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.title)
                        .lineLimit(1)
                        .frame(minWidth: 44)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.isEnabled)
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityValue(state.accessibilityValue ?? "")
            .accessibilityIdentifier("transcript-edit-save-action")
            .help(state.isEditing
                  ? "Save changes and finish editing"
                  : "Edit the Markdown note; Original remains untouched")
        }
    }
}

#if DEBUG
/// Mounts the exact compact trailing controls used by the workbench so the
/// integration suite can validate real SwiftUI/AX geometry at narrow widths.
struct TranscriptToolbarGeometryFixture: View {
    let width: CGFloat
    let layerState: TranscriptLayerControlState
    let actionState: TranscriptEditSaveActionState
    var onFramesChange: (([String: CGRect]) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 4)
            Menu {
                Button("Find in Note") {}
                Button("Editor Appearance") {}
                Button("Copy as Markdown") {}
            } label: {
                Label("More Note Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.iconOnly)
            .frame(minWidth: 28, minHeight: 28)
            .fixedSize()
            .accessibilityLabel("More Note Actions")
            .accessibilityIdentifier("transcript-more-actions")
            .background(toolbarFrameReader("transcript-more-actions"))

            TranscriptLayerControl(
                state: layerState,
                compact: true,
                onSelectOriginal: {},
                onSelectEdited: {}
            )
            .fixedSize()
            .background(toolbarFrameReader("transcript-layer-control"))

            TranscriptEditSaveAction(
                state: actionState,
                onEdit: {},
                onSave: {}
            )
            .fixedSize()
            .background(toolbarFrameReader("transcript-edit-save-action"))
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: 44)
        .coordinateSpace(name: "TranscriptToolbarGeometryFixture")
        .onPreferenceChange(TranscriptToolbarFramePreferenceKey.self) { frames in
            onFramesChange?(frames)
        }
    }

    private func toolbarFrameReader(_ identifier: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TranscriptToolbarFramePreferenceKey.self,
                value: [identifier: proxy.frame(in: .named("TranscriptToolbarGeometryFixture"))]
            )
        }
    }
}

private struct TranscriptToolbarFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
#endif
