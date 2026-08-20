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

    // MARK: - Reconcile

    /// A filesystem modification date is nanosecond-precise and does not
    /// survive a `Date` round trip, so identity-preserving edits pin both
    /// writes to the same coarse instant instead of restoring the old one.
    private static let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func pinModificationDate(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Self.pinnedDate], ofItemAtPath: url.path
        )
    }

    /// Rewrites a file's bytes while preserving the size and modification date
    /// the index fingerprinted, so skipping it and re-reading it give visibly
    /// different answers. The file must have been pinned before indexing.
    private func corruptPreservingIdentity(at url: URL) throws {
        let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try Data(repeating: 0x7A, count: size).write(to: url)
        try pinModificationDate(at: url)
    }

    @Test func reconcileRereadsOnlyChangedEntries() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let stable = try createEntry(
            in: f.vault, suffix: "10", title: "Stable",
            edited: "stable edited marker", original: "stable original marker"
        )
        let edited = try createEntry(
            in: f.vault, suffix: "11", title: "Edited",
            edited: "before marker", original: "before original"
        )
        let removed = try createEntry(
            in: f.vault, suffix: "12", title: "Removed",
            edited: "doomed marker", original: "doomed original"
        )
        try pinModificationDate(at: TranscriptOriginal.url(
            inEntry: f.vault.appendingRelativePath(stable)
        ))
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        #expect(try index.recordCount() == 6)

        // The untouched entry must not be re-parsed, proven by corrupting its
        // transcript in a way only a re-read could notice.
        try corruptPreservingIdentity(at: TranscriptOriginal.url(
            inEntry: f.vault.appendingRelativePath(stable)
        ))

        let editedURL = f.vault.appendingRelativePath(edited)
        let markdownURL = try #require(TranscriptFile.url(inEntry: editedURL))
        var document = FrontmatterDocument.parse(try String(contentsOf: markdownURL, encoding: .utf8))
        document.body = "\nafter marker\n"
        try AtomicFile.write(document.serialized(), to: markdownURL)
        try FileManager.default.removeItem(at: f.vault.appendingRelativePath(removed))
        let added = try createEntry(
            in: f.vault, suffix: "13", title: "Added",
            edited: "fresh marker", original: "fresh original"
        )

        try index.reconcile()

        #expect(try index.search("stable original marker").first?.entryPath == stable)
        #expect(try index.search("before marker").isEmpty)
        #expect(try index.search("after marker").first?.entryPath == edited)
        #expect(try index.search("doomed").isEmpty)
        #expect(try index.search("fresh marker").first?.entryPath == added)
    }

    @Test func reconcileIsANoOpWhenTheVaultDidNotChange() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try createEntry(
            in: f.vault, suffix: "14", title: "Untouched",
            edited: "untouched edited", original: "untouched original"
        )
        try pinModificationDate(at: TranscriptOriginal.url(
            inEntry: f.vault.appendingRelativePath(path)
        ))
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)
        let before = try index.recordCount()

        try corruptPreservingIdentity(at: TranscriptOriginal.url(
            inEntry: f.vault.appendingRelativePath(path)
        ))
        try index.reconcile()
        try index.reconcile()

        #expect(try index.recordCount() == before)
        #expect(try index.search("untouched original").first?.layer == .original)
    }

    @Test func reconcileRebuildsADatabaseThatHasNoFingerprints() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try createEntry(
            in: f.vault, suffix: "15", title: "Legacy",
            edited: "legacy edited", original: "legacy original"
        )
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)

        // `upsert` deliberately drops fingerprints, which is exactly the state
        // a database written before fingerprints existed is in.
        try index.upsert([
            SearchRecord(entryPath: path, layer: .edited, title: "Legacy", content: "stale content"),
        ])
        #expect(try index.search("stale content").isEmpty == false)

        try index.reconcile()
        #expect(try index.search("stale content").isEmpty)
        #expect(try index.search("legacy original").first?.layer == .original)
    }

    @Test func incrementalUpdatesLeaveReconcileWithNothingToDo() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let path = try createEntry(
            in: f.vault, suffix: "16", title: "Coherent",
            edited: "first marker", original: "coherent original"
        )
        try pinModificationDate(at: TranscriptOriginal.url(
            inEntry: f.vault.appendingRelativePath(path)
        ))
        let index = try VaultSearchIndex(vaultRoot: f.vault, databaseURL: f.database)

        let entryURL = f.vault.appendingRelativePath(path)
        let markdownURL = try #require(TranscriptFile.url(inEntry: entryURL))
        var document = FrontmatterDocument.parse(try String(contentsOf: markdownURL, encoding: .utf8))
        document.body = "\nsecond marker\n"
        try AtomicFile.write(document.serialized(), to: markdownURL)
        try index.upsertEntry(at: path)
        #expect(try index.search("second marker").first?.layer == .edited)

        // The incremental write recorded what it read, so a following
        // reconcile must neither re-read nor drop anything.
        try corruptPreservingIdentity(at: TranscriptOriginal.url(inEntry: entryURL))
        try index.reconcile()
        #expect(try index.search("second marker").first?.layer == .edited)
        #expect(try index.search("coherent original").first?.layer == .original)

        // The same must hold after the path-aware reconciler runs.
        try index.synchronize(changedAbsolutePaths: [markdownURL.path])
        try index.reconcile()
        #expect(try index.search("second marker").first?.layer == .edited)

        try index.removeEntry(path)
        #expect(try index.recordCount() == 0)
        try index.reconcile()
        // The entry is still on disk, so reconcile must notice its records are
        // gone and rebuild them rather than trust a leftover fingerprint.
        #expect(try index.search("second marker").first?.layer == .edited)
    }

    // MARK: - Cancellation

    @Test func aCancelledFuzzySearchAbortsInsteadOfRunningToCompletion() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        let filler = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 4_000)
        try index.upsert((0..<40).map {
            SearchRecord(entryPath: "entry-\($0)", layer: .original, title: "Entry \($0)", content: filler)
        })

        let task = Task.detached { try index.search("jumpz ovar thn lazi", fuzzy: true) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // Cancelling one search must leave the index perfectly usable.
        #expect(try index.search("quick brown").isEmpty == false)
    }

    // MARK: - Matching equivalence

    /// Every (content, query) pair whose matching behaviour must survive the
    /// fuzzy-scan rewrite. Expectations were captured from the pre-rewrite
    /// implementation; a change in any recorded field is a relevance change.
    private struct MatchCase {
        var name: String
        var title: String
        var content: String
        var query: String
        var fuzzy: Bool
    }

    private static let matchCases: [MatchCase] = [
        .init(name: "exact-substring", title: "Notes", content: "Welcome to Transcride today", query: "transcride", fuzzy: false),
        .init(name: "exact-infix", title: "Notes", content: "Welcome to Transcride today", query: "scride", fuzzy: false),
        .init(name: "exact-miss", title: "Notes", content: "Welcome to Transcride today", query: "transcirde", fuzzy: false),
        .init(name: "fuzzy-transposition-1word", title: "Notes", content: "Welcome to Transcride today", query: "transcirde", fuzzy: true),
        .init(name: "fuzzy-substitution-1word", title: "Notes", content: "Welcome to Transcride today", query: "transcrude", fuzzy: true),
        .init(name: "fuzzy-deletion-1word", title: "Notes", content: "Welcome to Transcride today", query: "transcrid", fuzzy: true),
        .init(name: "fuzzy-insertion-1word", title: "Notes", content: "Welcome to Transcride today", query: "transcrides", fuzzy: true),
        .init(name: "fuzzy-short-query-threshold1", title: "Notes", content: "the quick brown fox", query: "quikc", fuzzy: true),
        .init(name: "fuzzy-short-query-toofar", title: "Notes", content: "the quick brown fox", query: "qixck", fuzzy: true),
        .init(name: "fuzzy-multiword-threshold2", title: "Notes", content: "the quick brown fox jumps", query: "quikc brown fox", fuzzy: true),
        .init(name: "fuzzy-multiword-boundary-transposition", title: "Notes", content: "alpha beta gamma delta", query: "alpha betag amma", fuzzy: true),
        .init(name: "fuzzy-multiword-miss", title: "Notes", content: "alpha beta gamma delta", query: "zzzzz yyyyy xxxxx", fuzzy: true),
        .init(name: "fuzzy-window-picks-earliest", title: "Notes", content: "quikc brown quick brown", query: "quick brown", fuzzy: true),
        .init(name: "fuzzy-punctuation-between-words", title: "Notes", content: "hello, world and more", query: "helo world", fuzzy: true),
        .init(name: "fuzzy-newline-between-words", title: "Notes", content: "hello\nworld and more", query: "helo world", fuzzy: true),
        .init(name: "fuzzy-case-insensitive", title: "Notes", content: "The QUICK Brown Fox", query: "quikc brown", fuzzy: true),
        .init(name: "title-exact", title: "Quarterly Planning", content: "the transcript body uses unrelated words", query: "planning", fuzzy: false),
        .init(name: "title-fuzzy", title: "Quarterly Planning", content: "the transcript body uses unrelated words", query: "planing", fuzzy: true),
        .init(name: "title-loses-to-content", title: "Quarterly Planning", content: "planning happens in the body too", query: "planning", fuzzy: false),
        .init(name: "content-shorter-than-query", title: "Notes", content: "one", query: "one two three", fuzzy: true),
        .init(name: "empty-content", title: "Notes", content: "", query: "anything", fuzzy: true),
        .init(name: "nonascii-curly-apostrophe", title: "Notes", content: "don’t stop believing now", query: "belieivng", fuzzy: true),
        .init(name: "nonascii-accents", title: "Notes", content: "café crème brûlée today", query: "creme", fuzzy: true),
        .init(name: "nonascii-accent-exact", title: "Notes", content: "café crème brûlée today", query: "crème", fuzzy: true),
        .init(name: "nonascii-emoji-near-match", title: "Notes", content: "party 🎉🎊 tonight everyone", query: "tonigth", fuzzy: true),
        .init(name: "nonascii-emoji-in-window", title: "Notes", content: "party 🎉 tonight everyone", query: "party tonigth", fuzzy: true),
        .init(name: "fuzzy-long-content-late-match", title: "Notes", content: String(repeating: "filler words here ", count: 200) + "needle phrase appears", query: "needel phrase", fuzzy: true),
        .init(name: "fuzzy-repeated-words", title: "Notes", content: "aaa aaa aaa aaa aaa", query: "aab aaa", fuzzy: true),
        .init(name: "snippet-truncation-left-and-right", title: "Notes", content: String(repeating: "padding text ", count: 40) + "distinct marker here " + String(repeating: "trailing text ", count: 40), query: "distinct marker", fuzzy: false),
        .init(name: "fuzzy-threshold-boundary-exactly8", title: "Notes", content: "absolutely fantastic result", query: "fantstic", fuzzy: true),
        .init(name: "fuzzy-threshold-boundary-7chars", title: "Notes", content: "absolutely fantastic result", query: "reuslts", fuzzy: true),
    ]

    private func describe(_ hits: [SearchHit]) -> String {
        hits.map {
            "\($0.entryPath)/\($0.layer.rawValue) kind=\($0.matchKind) score=\($0.score) "
                + "range=\($0.matchRange.lowerBound)..<\($0.matchRange.upperBound) "
                + "snippetRange=\($0.snippetMatchRange.lowerBound)..<\($0.snippetMatchRange.upperBound) "
                + "snippet=\($0.snippet.debugDescription)"
        }.joined(separator: " ;; ")
    }

    /// Captured from the implementation that preceded the fuzzy-scan rewrite
    /// (flat-buffer windows, bag/length prefilter, cancellation). Keyed by case
    /// name; an empty string means "no hit".
    private static let expectedMatches: [String: String] = [
        "exact-substring": #"exact-substring/original kind=content score=0 range=11..<21 snippetRange=11..<21 snippet="Welcome to Transcride today""#,
        "exact-infix": #"exact-infix/original kind=content score=0 range=15..<21 snippetRange=15..<21 snippet="Welcome to Transcride today""#,
        "exact-miss": "",
        "fuzzy-transposition-1word": #"fuzzy-transposition-1word/original kind=content score=1 range=11..<21 snippetRange=11..<21 snippet="Welcome to Transcride today""#,
        "fuzzy-substitution-1word": #"fuzzy-substitution-1word/original kind=content score=1 range=11..<21 snippetRange=11..<21 snippet="Welcome to Transcride today""#,
        "fuzzy-deletion-1word": #"fuzzy-deletion-1word/original kind=content score=0 range=11..<20 snippetRange=11..<20 snippet="Welcome to Transcride today""#,
        "fuzzy-insertion-1word": #"fuzzy-insertion-1word/original kind=content score=1 range=11..<21 snippetRange=11..<21 snippet="Welcome to Transcride today""#,
        "fuzzy-short-query-threshold1": #"fuzzy-short-query-threshold1/original kind=content score=1 range=4..<9 snippetRange=4..<9 snippet="the quick brown fox""#,
        "fuzzy-short-query-toofar": "",
        "fuzzy-multiword-threshold2": #"fuzzy-multiword-threshold2/original kind=content score=1 range=4..<19 snippetRange=4..<19 snippet="the quick brown fox jumps""#,
        "fuzzy-multiword-boundary-transposition": #"fuzzy-multiword-boundary-transposition/original kind=content score=1 range=0..<16 snippetRange=0..<16 snippet="alpha beta gamma delta""#,
        "fuzzy-multiword-miss": "",
        "fuzzy-window-picks-earliest": #"fuzzy-window-picks-earliest/original kind=content score=0 range=12..<23 snippetRange=12..<23 snippet="quikc brown quick brown""#,
        "fuzzy-punctuation-between-words": #"fuzzy-punctuation-between-words/original kind=content score=1 range=0..<12 snippetRange=0..<12 snippet="hello, world and more""#,
        "fuzzy-newline-between-words": #"fuzzy-newline-between-words/original kind=content score=1 range=0..<11 snippetRange=0..<11 snippet="hello\nworld and more""#,
        "fuzzy-case-insensitive": #"fuzzy-case-insensitive/original kind=content score=1 range=4..<15 snippetRange=4..<15 snippet="The QUICK Brown Fox""#,
        "title-exact": #"title-exact/original kind=title score=0 range=10..<18 snippetRange=10..<18 snippet="Quarterly Planning""#,
        "title-fuzzy": #"title-fuzzy/original kind=title score=1 range=10..<18 snippetRange=10..<18 snippet="Quarterly Planning""#,
        "title-loses-to-content": #"title-loses-to-content/original kind=content score=0 range=0..<8 snippetRange=0..<8 snippet="planning happens in the body too""#,
        "content-shorter-than-query": "",
        "empty-content": "",
        "nonascii-curly-apostrophe": #"nonascii-curly-apostrophe/original kind=content score=1 range=11..<20 snippetRange=11..<20 snippet="don’t stop believing now""#,
        "nonascii-accents": #"nonascii-accents/original kind=content score=1 range=5..<10 snippetRange=5..<10 snippet="café crème brûlée today""#,
        "nonascii-accent-exact": #"nonascii-accent-exact/original kind=content score=0 range=5..<10 snippetRange=5..<10 snippet="café crème brûlée today""#,
        "nonascii-emoji-near-match": #"nonascii-emoji-near-match/original kind=content score=1 range=11..<18 snippetRange=11..<18 snippet="party 🎉🎊 tonight everyone""#,
        "nonascii-emoji-in-window": #"nonascii-emoji-in-window/original kind=content score=1 range=0..<16 snippetRange=0..<16 snippet="party 🎉 tonight everyone""#,
        "fuzzy-long-content-late-match": #"fuzzy-long-content-late-match/original kind=content score=1 range=3600..<3613 snippetRange=61..<74 snippet="… here filler words here filler words here filler words here needle phrase appears""#,
        "fuzzy-repeated-words": #"fuzzy-repeated-words/original kind=content score=1 range=0..<7 snippetRange=0..<7 snippet="aaa aaa aaa aaa aaa""#,
        "snippet-truncation-left-and-right": #"snippet-truncation-left-and-right/original kind=content score=0 range=520..<535 snippetRange=61..<76 snippet="…ng text padding text padding text padding text padding text distinct marker here trailing text trailing text trailing text trailing text trailing text trailing …""#,
        "fuzzy-threshold-boundary-exactly8": #"fuzzy-threshold-boundary-exactly8/original kind=content score=1 range=11..<20 snippetRange=11..<20 snippet="absolutely fantastic result""#,
        "fuzzy-threshold-boundary-7chars": "",
    ]

    @Test func fuzzyAndExactMatchingBehaviourIsUnchanged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try VaultSearchIndex(databaseURL: f.database)
        for matchCase in Self.matchCases {
            try index.upsert([
                SearchRecord(
                    entryPath: matchCase.name, layer: .original,
                    title: matchCase.title, content: matchCase.content
                ),
            ])
            let hits = try index.search(matchCase.query, fuzzy: matchCase.fuzzy)
                .filter { $0.entryPath == matchCase.name }
            let expected = try #require(
                Self.expectedMatches[matchCase.name],
                "no recorded expectation for \(matchCase.name)"
            )
            #expect(describe(hits) == expected, "case \(matchCase.name)")
        }
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
