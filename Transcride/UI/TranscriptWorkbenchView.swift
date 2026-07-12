import AppKit
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
    @State private var searchNavigationRange: NSRange?
    @State private var handledNavigationRequestID: UUID?
    @State private var showingSpeakerRename = false
    @FocusState private var findFieldFocused: Bool

    /// User-chosen display names for machine speaker ids (TRN-6), from the
    /// entry's frontmatter.
    private var speakerNames: [String: String] {
        document.map { SpeakerNames.names(in: $0) } ?? [:]
    }

    private var wordMap: TranscriptWordMap? {
        original.map {
            TranscriptWordMap(
                transcript: $0,
                duration: extensionState?.knownTranscriptDuration
                    ?? entry.duration ?? positivePlayerDuration,
                speakerNames: speakerNames
            )
        }
    }

    /// Frontmatter normally carries duration. Fall back to the loaded asset
    /// so legacy entries missing that field still receive timing repair.
    private var positivePlayerDuration: TimeInterval? {
        model.player.duration > 0 ? model.player.duration : nil
    }

    private var hasSpeakers: Bool {
        original?.segments.contains { $0.speaker != nil } == true
    }

    private var isForked: Bool {
        guard let document else { return false }
        return TranscriptEditDocument.isForked(document, comparedTo: original)
    }

    /// The menu-bar Edit Note command remains available even though editing a
    /// forked note is normally re-entered by clicking its text directly.
    private var canEditNote: Bool {
        document != nil && !isEditing && (viewedLayer == .edited || !isForked)
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
            viewedLayerIsOriginal: viewedLayer == .original
        )
    }

    private var viewedLayer: Layer {
        if original == nil { return .edited }
        if isEditing { return .edited }
        if !isForked { return .original }
        return activeLayer
    }

    private var currentWordIndex: Int? {
        guard entry.hasAudio, model.player.url != nil else { return nil }
        if let knownDuration = extensionState?.knownTranscriptDuration,
           model.player.currentTime > knownDuration {
            return nil
        }
        return wordMap?.wordIndex(atTime: model.player.currentTime)
    }

    private var activeNavigationRange: NSRange? {
        if showingFind, findMatches.indices.contains(findMatchIndex) {
            return findMatches[findMatchIndex]
        }
        return searchNavigationRange
    }

    private var editedPlaybackMap: EditedTranscriptPlaybackMap? {
        guard let wordMap, let body = document?.body else { return nil }
        return EditedTranscriptPlaybackMap(original: wordMap, editedBody: body)
    }

    /// The exact unchanged prefix remains safe for karaoke. The pure map
    /// excludes a partly edited word and every word after the first change.
    private var editedHighlightRange: NSRange? {
        guard let wordIndex = currentWordIndex,
              let range = editedPlaybackMap?.range(forWordAt: wordIndex) else { return nil }
        return NSRange(range)
    }

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

            VStack(spacing: 0) {
                if showingFind {
                    findBar
                        .frame(height: 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                ZStack(alignment: .topTrailing) {
                    layerContent

                    if followingPaused, viewedLayer == .original, model.player.isPlaying {
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
        .onChange(of: viewedLayer) { _, _ in updateFindMatches() }
        .onChange(of: findQuery) { _, _ in updateFindMatches(resetSelection: true) }
        .onChange(of: document?.body) { _, _ in updateFindMatches() }
        .onChange(of: model.inNoteFindRequestRevision) { _, _ in
            showingFind = true
            searchNavigationRange = nil
            updateFindMatches(resetSelection: true)
            findFieldFocused = true
        }
        .task(id: model.transcriptNavigationRequest?.id) {
            handleNavigationRequestIfNeeded()
        }
        .onChange(of: model.player.url) { _, _ in
            cueSearchNavigationIfPossible()
        }
        .onAppear {
            if isForked { activeLayer = .edited }
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

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            if viewedLayer == .original {
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

            if hasSpeakers {
                Button {
                    showingSpeakerRename = true
                } label: {
                    Label("Rename Speakers", systemImage: "person.2")
                }
                .disabled(isEditing || isSaving)
                .help("Rename Speaker 1, Speaker 2, … — or click a label in the transcript")
            }

            Button {
                copyCurrentLayer()
            } label: {
                Label(copyConfirmed ? "Copied" : "Copy as Markdown",
                      systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
            }
            .help("Copy this layer without frontmatter")

            if original != nil, isForked || isEditing {
                TranscriptLayerControl(
                    layer: activeLayer,
                    isEditing: isEditing,
                    isSaving: isSaving,
                    onSelectOriginal: { activeLayer = .original },
                    onSelectEdited: { activeLayer = .edited },
                    onSave: { Task { await saveAndFinishEditing() } }
                )
                .fixedSize()
                .help(isEditing
                      ? "Save changes and finish editing"
                      : "Switch between the immutable engine output and your edited note")
            } else if isEditing {
                Button("Save") {
                    Task { await saveAndFinishEditing() }
                }
                .disabled(isSaving)
                .help("Save changes and finish editing")
            }
        }
    }

    private var findBar: some View {
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
            Button {
                showingFind = false
                findQuery = ""
                findMatches = []
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("Close Find")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var layerContent: some View {
        switch viewedLayer {
        case .original:
            if let wordMap {
                SyncedOriginalTextView(
                    map: wordMap,
                    currentWordIndex: currentWordIndex,
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
                MarkdownBodyEditor(
                    text: body,
                    isEditable: isEditing && !isSaving,
                    highlightRange: editedHighlightRange,
                    navigationHighlightRange: activeNavigationRange,
                    boundaryStartTime: editedPlaybackMap?.boundaryStartTime,
                    boundaryCueRange: editedPlaybackMap?.cueRange.map { NSRange($0) },
                    playbackTime: model.player.currentTime,
                    isPlaying: model.player.isPlaying,
                    seekRevision: model.player.seekRevision,
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

    private func beginEditing() {
        guard let document else { return }
        editingStartedForked = isForked
        editingDidChange = false
        editStartBody = document.body
        activeLayer = .edited
        isEditing = true
    }

    @MainActor
    private func saveAndFinishEditing() async {
        guard isEditing, !isSaving, let document else { return }
        isSaving = true

        let pendingSave = pendingSave
        pendingSave?.cancel()
        self.pendingSave = nil
        await pendingSave?.value

        let hasActualChange = document.body != editStartBody
        let restoreUnforkedState = !editingStartedForked && !hasActualChange
        var savedDocument = document

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
            savedDocument = saved
            self.document = saved
        }

        NSApp.keyWindow?.makeFirstResponder(nil)
        needsSave = false
        isEditing = false
        isSaving = false
        editStartBody = nil
        editingDidChange = false
        editingStartedForked = false

        if original != nil, !TranscriptEditDocument.isForked(savedDocument, comparedTo: original) {
            activeLayer = .original
        } else {
            activeLayer = .edited
        }
    }

    private func applyUserEdit(_ newBody: String) {
        guard isEditing, var document, newBody != document.body else { return }
        searchNavigationRange = nil
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(newBody)
        document = editable.document
        self.document = document
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
        let source = findSource as NSString
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
        findMatches = matches
        if resetSelection || !matches.indices.contains(findMatchIndex) { findMatchIndex = 0 }
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
        findQuery = ""
        findMatches = []
        searchNavigationRange = NSRange(request.hit.matchRange)
        switch request.hit.layer {
        case .original:
            activeLayer = .original
            isEditing = false
        case .edited:
            activeLayer = .edited
            isEditing = false
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

/// A two-segment layer control whose Edited segment becomes the commit action
/// while the Markdown surface owns text focus. A custom control is used because
/// a segmented Picker does not reliably invoke an already-selected segment.
private struct TranscriptLayerControl: View {
    let layer: TranscriptWorkbenchView.Layer
    let isEditing: Bool
    let isSaving: Bool
    let onSelectOriginal: () -> Void
    let onSelectEdited: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment("Original", selected: !isEditing && layer == .original) {
                onSelectOriginal()
            }
            .disabled(isEditing || isSaving)

            segment(isEditing ? "Save" : "Edited", selected: isEditing || layer == .edited) {
                if isEditing { onSave() } else { onSelectEdited() }
            }
            .disabled(isSaving)
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript Layer")
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
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            TranscriptPlaybackWordStyle.clearPlaybackAttributes(
                from: textView.layoutManager,
                in: fullRange
            )
            textView.layoutManager?.removeTemporaryAttribute(
                .backgroundColor, forCharacterRange: fullRange
            )
            TranscriptPlaybackWordStyle.subdueTranscript(
                in: textView.layoutManager,
                range: fullRange
            )
            styleSpeakerLabels()

            let wordChanged = highlightedWordIndex != playbackWordIndex
            highlightedWordIndex = playbackWordIndex
            if let playbackWordIndex,
               let range = parent.map.range(forWordAt: playbackWordIndex) {
                TranscriptPlaybackWordStyle.illuminateWord(
                    in: textView.layoutManager,
                    range: NSRange(range)
                )
                if wordChanged, !parent.followingPaused { scrollToWord(playbackWordIndex) }
            }

            let navigationChanged = self.navigationRange != navigationRange
            self.navigationRange = navigationRange
            if let navigationRange,
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
            layoutManager.ensureLayout(for: textContainer)
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
            layoutManager.ensureLayout(for: textContainer)
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
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length), length: 0
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
        var appliedHighlightRange: NSRange?
        var appliedNavigationRange: NSRange?
        var boundaryFadeTask: Task<Void, Never>?
        var wasBeforeBoundary = false
        var lastSeekRevision: Int
        /// Hosted NSTextViews otherwise resolve `undoManager` through the
        /// SwiftUI window, whose manager doesn't track the text view's edits.
        let editUndoManager = UndoManager()

        init(parent: MarkdownBodyEditor) {
            self.parent = parent
            lastSeekRevision = parent.seekRevision
            if let boundary = parent.boundaryStartTime {
                wasBeforeBoundary = parent.playbackTime < boundary
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.layoutManager?.removeTemporaryAttribute(
                .backgroundColor, forCharacterRange: fullRange
            )
            appliedHighlightRange = nil
            appliedNavigationRange = nil
            parent.onUserEdit(textView.string)
        }

        func updateHighlights() {
            guard let textView else { return }
            let stringLength = (textView.string as NSString).length
            let fullRange = NSRange(location: 0, length: stringLength)
            let seekChanged = lastSeekRevision != parent.seekRevision
            lastSeekRevision = parent.seekRevision

            if parent.isEditable {
                cancelBoundaryFade()
                clearPlaybackAttributes(in: fullRange)
                appliedHighlightRange = nil
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
                } else if boundaryFadeTask != nil {
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                } else if parent.isPlaying, wasBeforeBoundary {
                    let previousActiveRange = appliedHighlightRange
                    wasBeforeBoundary = false
                    startBoundaryFade(
                        in: fullRange,
                        previousActiveRange: previousActiveRange,
                        cueRange: parent.boundaryCueRange
                    )
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                } else if parent.playbackTime >= boundary {
                    clearPlaybackAttributes(in: fullRange)
                    appliedHighlightRange = nil
                    wasBeforeBoundary = false
                    applyNavigationHighlight(to: textView, stringLength: stringLength)
                    return
                }
            } else {
                cancelBoundaryFade()
            }

            clearPlaybackAttributes(in: fullRange)
            appliedHighlightRange = nil
            if let range = parent.highlightRange, NSMaxRange(range) <= stringLength {
                TranscriptPlaybackWordStyle.subdueTranscript(
                    in: textView.layoutManager,
                    range: fullRange
                )
                TranscriptPlaybackWordStyle.illuminateWord(
                    in: textView.layoutManager,
                    range: range
                )
                appliedHighlightRange = range
            }
            applyNavigationHighlight(to: textView, stringLength: stringLength)
        }

        func cancelBoundaryFade() {
            boundaryFadeTask?.cancel()
            boundaryFadeTask = nil
        }

        private func clearPlaybackAttributes(in range: NSRange) {
            TranscriptPlaybackWordStyle.clearPlaybackAttributes(
                from: textView?.layoutManager,
                in: range
            )
        }

        private func startBoundaryFade(
            in fullRange: NSRange,
            previousActiveRange: NSRange?,
            cueRange: NSRange?
        ) {
            cancelBoundaryFade()
            appliedHighlightRange = nil
            boundaryFadeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let frameCount = 45
                for frame in 0...frameCount {
                    guard !Task.isCancelled else { return }
                    let progress = CGFloat(frame) / CGFloat(frameCount)
                    self.applyBoundaryFadeFrame(
                        progress: progress,
                        fullRange: fullRange,
                        previousActiveRange: previousActiveRange,
                        cueRange: cueRange
                    )
                    if frame < frameCount {
                        try? await Task.sleep(for: .milliseconds(33))
                    }
                }
                guard !Task.isCancelled else { return }
                self.clearPlaybackAttributes(in: fullRange)
                self.boundaryFadeTask = nil
            }
        }

        private func applyBoundaryFadeFrame(
            progress: CGFloat,
            fullRange: NSRange,
            previousActiveRange: NSRange?,
            cueRange: NSRange?
        ) {
            guard let layoutManager = textView?.layoutManager else { return }
            clearPlaybackAttributes(in: fullRange)
            let normal = NSColor.labelColor
            let subdued = NSColor.secondaryLabelColor
                .blended(withFraction: progress, of: normal) ?? normal
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: subdued, forCharacterRange: fullRange
            )

            if let previousActiveRange, NSMaxRange(previousActiveRange) <= fullRange.length {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: normal, forCharacterRange: previousActiveRange
                )
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

            if let cueRange, NSMaxRange(cueRange) <= fullRange.length {
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
