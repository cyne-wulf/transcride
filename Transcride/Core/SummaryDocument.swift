import CryptoKit
import Foundation

/// Which transcript layer a summary was generated from.
enum SummarySourceLayer: String, Sendable {
    case original
    case edited
}

/// The `.summary.md` sidecar: an AI-generated, user-editable markdown summary
/// stored beside the note. It is a derived artifact — never injected into the
/// note body (fork detection compares the whole body) and dot-named so vault
/// entry scanning ignores it. Frontmatter records how it was produced.
struct SummaryDocument: Equatable, Sendable {
    static let fileName = ".summary.md"

    private(set) var document: FrontmatterDocument

    init(document: FrontmatterDocument) {
        self.document = document
    }

    static func url(inEntry entryURL: URL) -> URL {
        entryURL.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Loads the sidecar, or nil when the entry has no summary yet.
    static func load(from url: URL) throws -> SummaryDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return SummaryDocument(document: FrontmatterDocument.parse(text))
    }

    /// A freshly generated summary. `fingerprint` is of the exact source text
    /// summarized, so staleness can be detected without re-reading the model.
    static func make(
        body: String,
        modelID: String,
        sourceLayer: SummarySourceLayer,
        fingerprint: String,
        generated: Date,
        title: String? = nil
    ) -> SummaryDocument {
        var document = FrontmatterDocument(fields: [], body: "")
        document.setValue(modelID, for: "summary_model")
        document.setValue(sourceLayer.rawValue, for: "summary_source_layer")
        document.setValue(fingerprint, for: "summary_source_fingerprint")
        document.setValue(FrontmatterDate.format(generated), for: "summary_generated")
        if let title {
            document.setValue(title, for: "summary_title", quoted: true)
        }
        document.body = body
        return SummaryDocument(document: document)
    }

    var body: String { document.body }
    var handEdited: Bool { document.handEdited }
    var modelID: String? { document.value(for: "summary_model") }
    var sourceFingerprint: String? { document.value(for: "summary_source_fingerprint") }
    /// The AI-proposed entry title recorded at generation time — kept even
    /// when it was not applied, so regeneration can tell a prior AI title
    /// from a human rename.
    var summaryTitle: String? { document.value(for: "summary_title") }
    var generated: Date? {
        document.value(for: "summary_generated").flatMap(FrontmatterDate.parse)
    }
    var sourceLayer: SummarySourceLayer? {
        document.value(for: "summary_source_layer").flatMap(SummarySourceLayer.init)
    }

    /// Replaces only the markdown body. A no-op assignment does not mark the
    /// summary hand-edited.
    mutating func replaceBody(_ newBody: String, markHandEdited: Bool = true) {
        guard newBody != document.body else { return }
        document.body = newBody
        if markHandEdited { document.handEdited = true }
    }

    func serialized() -> String {
        document.serialized()
    }
}

enum SummaryFingerprint {
    /// SHA256 hex of the whitespace-normalized source text, so incidental
    /// trailing-newline or reflow differences never mark a summary stale.
    static func fingerprint(of text: String) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
