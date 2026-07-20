import Foundation
import Testing

@Suite("Vault search index")
struct VaultSearchIndexTests {
    private struct Fixture {
        var root: URL
        var vault: URL
        var database: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "search-index-\(UUID().uuidString)")
        let vault = root.appending(path: "Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return Fixture(root: root, vault: vault, database: root.appending(path: "Cache/search.sqlite"))
    }

    private func createEntry(
        in vault: URL,
        suffix: String,
        title: String,
        edited: String,
        original: String
    ) throws -> RelativePath {
        let relativePath = "transcride-2026-07-09T10-00-\(suffix)"
        let entryURL = vault.appendingRelativePath(relativePath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        var document = FrontmatterDocument(fields: [], body: "\n\(edited)\n")
        document.title = title
        try AtomicFile.write(document.serialized(), to: entryURL.appending(path: TranscriptFile.defaultName))

        let words = original.split(separator: " ").enumerated().map { index, text in
            TranscriptOriginal.Word(text: String(text), start: Double(index), end: Double(index) + 0.5)
        }
        let transcript = TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [.init(start: 0, end: words.last?.end ?? 0, words: words)]
        )
        try transcript.write(to: TranscriptOriginal.url(inEntry: entryURL))
        return relativePath
    }

    @Test func exactIsCaseInsensitiveSubstringAndFuzzyIsOptIn() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        try index.upsert([
            SearchRecord(entryPath: "a", layer: .original, title: "A", content: "Welcome to Transcride today"),
        ])

        #expect(try index.search("TRANSCRIDE").count == 1)
        #expect(try index.search("scride").count == 1) // Literal substring, not token-only FTS.
        #expect(try index.search("transcirde").isEmpty)
        let fuzzy = try index.search("transcirde", fuzzy: true)
        #expect(fuzzy.count == 1)
        #expect(fuzzy.first?.score == 1)
    }

    @Test func exactAndFuzzyQueriesMatchEntryTitles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        try index.upsert([
            SearchRecord(
                entryPath: "a",
                layer: .original,
                title: "Quarterly Planning",
                content: "The transcript body uses unrelated words."
            ),
        ])

        let exact = try #require(try index.search("planning").first)
        #expect(exact.matchKind == .title)
        #expect(exact.snippet == "Quarterly Planning")
        #expect(exact.snippetMatchRange == 10..<18)

        let fuzzy = try #require(try index.search("planing", fuzzy: true).first)
        #expect(fuzzy.matchKind == .title)
        #expect(fuzzy.score == 1)
    }

    @Test func bothLayersAreIndexedAndEditedHitsAlwaysRankFirst() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        try index.upsert([
            SearchRecord(entryPath: "one", layer: .original, title: "One", content: "distinct phrase"),
            SearchRecord(entryPath: "two", layer: .edited, title: "Two", content: "distinct phrase"),
            SearchRecord(entryPath: "one", layer: .edited, title: "One", content: "distinct phrase"),
        ])
        let hits = try index.search("distinct phrase")
        #expect(hits.count == 3)
        #expect(hits[0].layer == .edited)
        #expect(hits[1].layer == .edited)
        #expect(hits[2].layer == .original)
        #expect(hits.allSatisfy { $0.snippet[$0.snippet.index($0.snippet.startIndex, offsetBy: $0.snippetMatchRange.lowerBound)..<$0.snippet.index($0.snippet.startIndex, offsetBy: $0.snippetMatchRange.upperBound)].lowercased() == "distinct phrase" })
    }

    @Test func fileChangeUpsertReplacesEditedRecordAndRemoveIsIncremental() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try createEntry(
            in: f.vault, suffix: "01", title: "Standup",
            edited: "external alpha marker", original: "authoritative engine words"
        )
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index.recordCount() == 2)
        #expect(try index.search("external alpha").first?.layer == .edited)

        let entryURL = f.vault.appendingRelativePath(path)
        let markdownURL = try #require(TranscriptFile.url(inEntry: entryURL))
        var document = FrontmatterDocument.parse(try String(contentsOf: markdownURL, encoding: .utf8))
        document.body = "\nexternal beta marker\n"
        try AtomicFile.write(document.serialized(), to: markdownURL)
        try index.upsertEntry(at: path)

        #expect(try index.search("external alpha").isEmpty)
        #expect(try index.search("external beta").first?.layer == .edited)
        try index.removeEntry(path)
        #expect(try index.recordCount() == 0)
    }

    @Test func generatedMarkdownDoesNotCreateAConfusingDuplicateLayerHit() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try createEntry(
            in: f.vault, suffix: "04", title: "Generated",
            edited: "same generated words", original: "same generated words"
        )

        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index.recordCount() == 1)
        let hits = try index.search("generated words")
        #expect(hits.count == 1)
        #expect(hits.first?.layer == .original)
    }

    @Test func speakerVisibilityControlsOriginalIndexWithoutCreatingAnEditedDuplicate() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = "transcride-2026-07-09T10-00-00-speakers"
        let entryURL = f.vault.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        let original = TranscriptOriginal(
            engine: .init(
                engine: "test", model: "test", options: [:], created: "", appVersion: ""
            ),
            segments: [
                .init(
                    start: 0, end: 0.5, speaker: "S1",
                    words: [.init(text: "Opening", start: 0, end: 0.5)]
                ),
                .init(
                    start: 0.6, end: 1.1, speaker: "S2",
                    words: [.init(text: "response", start: 0.6, end: 1.1)]
                ),
            ]
        )
        try original.write(to: TranscriptOriginal.url(inEntry: entryURL))
        var document = FrontmatterDocument(fields: [], body: "")
        document.title = "Interview"
        SpeakerNames.set(name: "Alice", forID: "S1", in: &document)
        document.speakerDetectionEnabled = false
        document.body = "\n" + TranscriptMarkdown.body(
            from: original,
            speakerNames: SpeakerNames.names(in: document),
            speakerDetectionEnabled: false
        ) + "\n"
        let markdownURL = entryURL.appending(path: TranscriptFile.defaultName)
        try AtomicFile.write(document.serialized(), to: markdownURL)

        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index.recordCount() == 1)
        #expect(try index.search("Alice").isEmpty)
        #expect(try index.search("Opening response").first?.layer == .original)

        document.speakerDetectionEnabled = true
        document.body = "\n" + TranscriptMarkdown.body(
            from: original,
            speakerNames: SpeakerNames.names(in: document)
        ) + "\n"
        try AtomicFile.write(document.serialized(), to: markdownURL)
        try index.upsertEntry(at: path)
        #expect(try index.recordCount() == 1)
        #expect(try index.search("Alice").first?.layer == .original)
    }

    @Test func pathAwareSynchronizationHandlesExternalEditMoveAndDelete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let oldPath = try createEntry(
            in: f.vault, suffix: "05", title: "External",
            edited: "original projection", original: "original projection"
        )
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)

        let oldURL = f.vault.appendingRelativePath(oldPath)
        let markdownURL = try #require(TranscriptFile.url(inEntry: oldURL))
        var document = FrontmatterDocument.parse(try String(contentsOf: markdownURL, encoding: .utf8))
        document.body = "\nexternally added needle\n"
        try AtomicFile.write(document.serialized(), to: markdownURL)
        try index.synchronize(changedAbsolutePaths: [markdownURL.path])
        #expect(try index.search("externally added").first?.layer == .edited)

        let folder = f.vault.appending(path: "Moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let newPath = "Moved/\(oldPath)"
        let newURL = f.vault.appendingRelativePath(newPath)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        try index.synchronize(changedAbsolutePaths: [oldURL.path, newURL.path])
        #expect(try index.search("externally added").first?.entryPath == newPath)

        try FileManager.default.removeItem(at: newURL)
        try index.synchronize(changedAbsolutePaths: [newURL.path])
        #expect(try index.search("externally added").isEmpty)
        #expect(try index.recordCount() == 0)
    }

    @Test func rebuildFindsNestedEntriesAndUsesFTS5OutsideVault() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let folder = f.vault.appending(path: "Meetings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try createEntry(in: folder, suffix: "02", title: "Nested", edited: "edited layer", original: "original layer")

        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        try index.rebuild()
        #expect(try index.recordCount() == 2)
        #expect(try index.usesFTS5())
        #expect(!index.databaseURL.standardizedFileURL.path.hasPrefix(f.vault.standardizedFileURL.path + "/"))

        let defaultURL = VaultSearchIndex.defaultDatabaseURL(forVault: f.vault)
        #expect(!defaultURL.standardizedFileURL.path.hasPrefix(f.vault.standardizedFileURL.path + "/"))
    }

    @Test func deletedOrCorruptIndexRebuildsAutomaticallyOnOpen() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try createEntry(
            in: f.vault, suffix: "03", title: "Recovery",
            edited: "recover edited", original: "recover original"
        )

        var index: VaultSearchIndex? = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index?.recordCount() == 2)
        index = nil
        try FileManager.default.removeItem(at: f.database)

        index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index?.recordCount() == 2)
        index = nil
        try Data("not a sqlite database".utf8).write(to: f.database)

        index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index?.recordCount() == 2)
        #expect(try index?.search("recover edited").first?.layer == .edited)
    }

    @Test func exactSearchIsFastOnOneThousandEntries() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        let records = (0..<1_000).flatMap { number in
            [
                SearchRecord(entryPath: "entry-\(number)", layer: .edited, title: "Entry \(number)", content: "ordinary fixture words \(number)"),
                SearchRecord(entryPath: "entry-\(number)", layer: .original, title: "Entry \(number)", content: number == 777 ? "needle phrase appears here" : "engine fixture words \(number)"),
            ]
        }
        try index.upsert(records)
        let started = Date()
        let hits = try index.search("needle phrase")
        let elapsed = Date().timeIntervalSince(started)
        #expect(hits.count == 1)
        #expect(elapsed < 0.2)
    }
}
