import AppKit
import SwiftUI

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
    @Binding var document: FrontmatterDocument?

    @State private var activeLayer: Layer = .original
    @State private var editingUnforked = false
    @State private var followingPaused = false
    @State private var pendingSave: Task<Void, Never>?
    @State private var needsSave = false
    @State private var copyConfirmed = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    private var wordMap: TranscriptWordMap? {
        original.map(TranscriptWordMap.init)
    }

    private var isForked: Bool {
        guard let document else { return false }
        return TranscriptEditDocument.isForked(document, comparedTo: original)
    }

    private var viewedLayer: Layer {
        if original == nil { return .edited }
        if !isForked { return editingUnforked ? .edited : .original }
        return activeLayer
    }

    private var currentWordIndex: Int? {
        wordMap?.wordIndex(atTime: model.player.currentTime)
    }

    /// Edited highlighting is enabled only when the entire body is still the
    /// original projection plus surrounding whitespace. Any real edit turns
    /// it off instead of risking a highlight on the wrong words.
    private var editedHighlightRange: NSRange? {
        guard let map = wordMap,
              let wordIndex = currentWordIndex,
              let wordRange = map.range(forWordAt: wordIndex),
              let body = document?.body else { return nil }
        let nsBody = body as NSString
        let rendered = map.renderedText as NSString
        let projectionRange = nsBody.range(of: rendered as String)
        guard projectionRange.location != NSNotFound else { return nil }
        let prefix = nsBody.substring(to: projectionRange.location)
        let suffix = nsBody.substring(from: NSMaxRange(projectionRange))
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NSRange(
            location: projectionRange.location + wordRange.lowerBound,
            length: wordRange.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            noteToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            ZStack(alignment: .topTrailing) {
                layerContent

                if followingPaused, viewedLayer == .original {
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
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        .onChange(of: model.player.seekRevision) { _, _ in
            // Word clicks, waveform scrubs and transport skips all restore
            // follow. Silence skipping intentionally does not increment this.
            followingPaused = false
        }
        .onChange(of: isForked) { wasForked, nowForked in
            if !wasForked, nowForked { activeLayer = .edited }
        }
        .onAppear {
            if isForked { activeLayer = .edited }
        }
        .onDisappear {
            pendingSave?.cancel()
            copyConfirmationTask?.cancel()
            if needsSave, let document {
                Task {
                    _ = await model.saveTranscriptBody(
                        document.body,
                        markHandEdited: document.handEdited,
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

            Button {
                copyCurrentLayer()
            } label: {
                Label(copyConfirmed ? "Copied" : "Copy as Markdown",
                      systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
            }
            .help("Copy this layer without frontmatter")

            if isForked, original != nil {
                Picker("Transcript Layer", selection: $activeLayer) {
                    ForEach(Layer.allCases) { layer in
                        Text(layer.rawValue).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Switch between the immutable engine output and your edited note")
            } else if original != nil, !editingUnforked {
                Button("Edit") {
                    editingUnforked = true
                }
                .help("Create an editable layer; Original remains untouched")
            }
        }
    }

    @ViewBuilder
    private var layerContent: some View {
        switch viewedLayer {
        case .original:
            if let wordMap {
                SyncedOriginalTextView(
                    map: wordMap,
                    currentWordIndex: currentWordIndex,
                    followingPaused: $followingPaused
                ) { wordIndex in
                    guard let time = wordMap.startTime(forWordAt: wordIndex) else { return }
                    model.player.seek(to: time)
                }
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
                MarkdownBodyEditor(text: body, highlightRange: editedHighlightRange) { newBody in
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

    private func applyUserEdit(_ newBody: String) {
        guard var document, newBody != document.body else { return }
        var editable = TranscriptEditDocument(document: document)
        editable.replaceBody(newBody)
        document = editable.document
        self.document = document
        activeLayer = .edited
        needsSave = true

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

// MARK: - Immutable synced original

private struct SyncedOriginalTextView: NSViewRepresentable {
    let map: TranscriptWordMap
    let currentWordIndex: Int?
    @Binding var followingPaused: Bool
    let onWordClick: (Int) -> Void

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
            guard let wordIndex = context.coordinator.parent.map.wordIndex(containingUTF16Offset: offset) else {
                return
            }
            context.coordinator.parent.onWordClick(wordIndex)
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
            guard let wordIndex = context.coordinator.parent.map.wordIndex(containingUTF16Offset: offset) else {
                return
            }
            context.coordinator.parent.onWordClick(wordIndex)
        }
        if context.coordinator.renderedText != map.renderedText {
            context.coordinator.renderBaseText()
        }
        context.coordinator.updateHighlight(to: currentWordIndex)
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
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 8
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: renderedText, attributes: attributes)
            )
        }

        func updateHighlight(to wordIndex: Int?) {
            guard let textView, highlightedWordIndex != wordIndex else {
                if wordIndex != nil, !parent.followingPaused { scrollToWord(wordIndex!) }
                return
            }
            if let old = highlightedWordIndex,
               let range = parent.map.range(forWordAt: old) {
                textView.textStorage?.removeAttribute(.backgroundColor, range: NSRange(range))
            }
            highlightedWordIndex = wordIndex
            if let wordIndex, let range = parent.map.range(forWordAt: wordIndex) {
                textView.textStorage?.addAttributes([
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.30),
                    .foregroundColor: NSColor.labelColor,
                ], range: NSRange(range))
                if !parent.followingPaused { scrollToWord(wordIndex) }
            }
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

private struct MarkdownBodyEditor: NSViewRepresentable {
    let text: String
    let highlightRange: NSRange?
    let onUserEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
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
        context.coordinator.updateHighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalText = true
            context.coordinator.removeHighlight()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length), length: 0
            ))
            context.coordinator.isApplyingExternalText = false
        }
        context.coordinator.updateHighlight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownBodyEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false
        var appliedHighlightRange: NSRange?

        init(parent: MarkdownBodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            textView.textStorage?.removeAttribute(
                .backgroundColor,
                range: NSRange(location: 0, length: (textView.string as NSString).length)
            )
            appliedHighlightRange = nil
            parent.onUserEdit(textView.string)
        }

        func removeHighlight() {
            guard let textView, let appliedHighlightRange,
                  NSMaxRange(appliedHighlightRange) <= (textView.string as NSString).length else {
                self.appliedHighlightRange = nil
                return
            }
            textView.textStorage?.removeAttribute(.backgroundColor, range: appliedHighlightRange)
            self.appliedHighlightRange = nil
        }

        func updateHighlight() {
            guard let textView else { return }
            if appliedHighlightRange != parent.highlightRange { removeHighlight() }
            guard textView.window?.firstResponder !== textView,
                  let range = parent.highlightRange,
                  NSMaxRange(range) <= (textView.string as NSString).length,
                  appliedHighlightRange == nil else { return }
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.24),
                range: range
            )
            appliedHighlightRange = range
        }
    }
}
