import Foundation
import Testing

@Suite("Editable transcript markdown")
struct TranscriptEditDocumentTests {
    private func temporaryFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcript-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "transcript.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func original(_ text: String = "Original words") -> TranscriptOriginal {
        let words = text.split(separator: " ").enumerated().map { index, word in
            TranscriptOriginal.Word(
                text: String(word), start: Double(index), end: Double(index) + 0.5
            )
        }
        return TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: 0, end: words.last?.end ?? 0, words: words)]
        )
    }

    @Test func editSaveReloadPreservesBodyExactlyAndUnknownFrontmatter() throws {
        let source = """
        ---
        title: "Test"
        custom_key: keep this exactly
        ---

        Original words
        """
        let url = try temporaryFile(contents: source)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var editable = try TranscriptEditDocument.load(from: url)
        let editedBody = "\n# Heading\n\n- **One**\n- _Two_ 👋🏽\n"
        editable.replaceBody(editedBody)
        try editable.save(to: url)
        let reloaded = try TranscriptEditDocument.load(from: url)

        #expect(reloaded.body == editedBody)
        #expect(reloaded.isHandEdited)
        #expect(reloaded.document.rawValue(for: "custom_key") == "keep this exactly")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("hand_edited: true"))
    }

    @Test func assigningIdenticalBodyDoesNotFork() throws {
        let url = try temporaryFile(contents: "---\ntitle: Test\n---\n\nOriginal words\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var editable = try TranscriptEditDocument.load(from: url)
        editable.replaceBody(editable.body)
        try editable.save(to: url)
        let savedText = try String(contentsOf: url, encoding: .utf8)
        #expect(!editable.isHandEdited)
        #expect(!savedText.contains("hand_edited"))
    }

    @Test func generatedBodyIsNotForkedButExternalTextChangeIs() {
        let transcript = original()
        var generated = FrontmatterDocument(
            fields: [.init(key: "title", rawValue: "Test", line: "title: Test")],
            body: "\nOriginal words\n"
        )
        #expect(!TranscriptEditDocument.isForked(generated, comparedTo: transcript))

        generated.body = "\nExternally rewritten summary\n"
        #expect(TranscriptEditDocument.isForked(generated, comparedTo: transcript))
    }

    @Test func explicitFlagWinsEvenWhenBodyMatchesOriginal() {
        let transcript = original()
        var doc = FrontmatterDocument(
            fields: [.init(key: "title", rawValue: "Test", line: "title: Test")],
            body: "\nOriginal words\n"
        )
        doc.handEdited = true
        #expect(TranscriptEditDocument.isForked(doc, comparedTo: transcript))
    }
}
