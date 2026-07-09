import Foundation

/// Pure, frontmatter-preserving editing primitive for the editable markdown
/// layer. UI code owns debounce timing; this type owns fork semantics and the
/// atomic disk round-trip.
struct TranscriptEditDocument: Equatable, Sendable {
    private(set) var document: FrontmatterDocument

    init(document: FrontmatterDocument) {
        self.document = document
    }

    var body: String { document.body }
    var isHandEdited: Bool { document.handEdited }

    static func load(from url: URL) throws -> TranscriptEditDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return TranscriptEditDocument(document: FrontmatterDocument.parse(text))
    }

    /// Replaces only the markdown body. A no-op assignment does not fork the
    /// layer; the first real edit records `hand_edited: true`.
    mutating func replaceBody(_ newBody: String, markHandEdited: Bool = true) {
        guard newBody != document.body else { return }
        document.body = newBody
        if markHandEdited { document.handEdited = true }
    }

    mutating func markHandEdited() {
        document.handEdited = true
    }

    func save(to url: URL) throws {
        try AtomicFile.write(document.serialized(), to: url)
    }

    /// Explicit M4 state wins. Comparison remains the backstop for edits made
    /// externally by Obsidian or another editor that does not know our flag.
    static func isForked(
        _ document: FrontmatterDocument,
        comparedTo original: TranscriptOriginal?
    ) -> Bool {
        if document.handEdited { return true }
        if TranscriptMarkdown.isStubBody(document.body) { return false }
        guard let original else { return true }
        return !TranscriptMarkdown.isGeneratedBody(document.body, from: original)
    }
}
