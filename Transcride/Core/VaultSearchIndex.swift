import Foundation
import SQLite3

enum SearchLayer: String, Codable, Hashable, Sendable {
    case edited
    case original

    var rank: Int { self == .edited ? 0 : 1 }
}

struct SearchRecord: Equatable, Sendable {
    var entryPath: RelativePath
    var layer: SearchLayer
    var title: String
    var content: String
}

enum SearchMatchKind: Hashable, Sendable {
    case content
    case title
}

struct SearchHit: Hashable, Sendable {
    var entryPath: RelativePath
    var layer: SearchLayer
    var title: String
    var snippet: String
    /// Whether the match belongs to the transcript layer or entry title.
    var matchKind: SearchMatchKind
    /// UTF-16 range in the complete layer content, or in `title` for a title hit.
    var matchRange: Range<Int>
    /// UTF-16 range in `snippet` for direct highlighting.
    var snippetMatchRange: Range<Int>
    /// Zero for exact hits; edit distance for fuzzy hits.
    var score: Int
}

enum SearchIndexError: Error, LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Search index error: \(message)"
        }
    }
}

/// Rebuildable vault search cache. The authoritative markdown and JSON remain
/// in the vault; deleting this SQLite file loses no user data.
final class VaultSearchIndex: @unchecked Sendable {
    let databaseURL: URL
    let vaultRoot: URL?

    private var database: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(vaultRoot: URL? = nil, databaseURL: URL? = nil) throws {
        self.vaultRoot = vaultRoot
        if let databaseURL {
            self.databaseURL = databaseURL
        } else if let vaultRoot {
            self.databaseURL = Self.defaultDatabaseURL(forVault: vaultRoot)
        } else {
            throw SearchIndexError.sqlite("A vault root or database URL is required")
        }

        let existed = FileManager.default.fileExists(atPath: self.databaseURL.path)
        do {
            try openAndValidate()
            if !existed, vaultRoot != nil { try rebuildUnlocked() }
        } catch {
            sqlite3_close(database)
            database = nil
            try resetDatabaseFiles()
            try openAndValidate()
            if vaultRoot != nil { try rebuildUnlocked() }
        }
    }

    deinit { sqlite3_close(database) }

    /// Stable per-vault location outside the vault's visible files.
    static func defaultDatabaseURL(forVault vaultURL: URL) -> URL {
        let canonical = vaultURL.standardizedFileURL.path
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Transcride/Search", directoryHint: .isDirectory)
            .appending(path: String(hash, radix: 16) + ".sqlite")
    }

    func upsert(_ records: [SearchRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            for record in records { try upsertUnlocked(record) }
            // Records injected directly do not come from a known set of files,
            // so no fingerprint can describe them. Dropping the entry's
            // fingerprint keeps `reconcile()` from trusting a stale one.
            for path in Set(records.map(\.entryPath)) { try deleteFingerprintUnlocked(path) }
        }
    }

    /// Incremental file-change hook used by both in-app writes and FSEvents.
    func upsertEntry(at relativePath: RelativePath) throws {
        guard let vaultRoot else {
            throw SearchIndexError.sqlite("upsertEntry requires a vault root")
        }
        lock.lock(); defer { lock.unlock() }
        let entryURL = vaultRoot.appendingRelativePath(relativePath)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            try transaction {
                try removeEntryUnlocked(relativePath)
                try deleteFingerprintUnlocked(relativePath)
            }
            return
        }
        let fingerprint = Self.fingerprint(at: entryURL)
        let records = recordsForEntry(at: entryURL, relativePath: relativePath)
        try transaction {
            try removeEntryUnlocked(relativePath)
            for record in records { try upsertUnlocked(record) }
            try writeFingerprintUnlocked(relativePath, fingerprint: fingerprint)
        }
    }

    func removeEntry(_ relativePath: RelativePath) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try removeEntryUnlocked(relativePath)
            try deleteFingerprintUnlocked(relativePath)
        }
    }

    /// Reconciles the index after a coalesced filesystem event. Existing
    /// entries touched by the event are re-read; paths which vanished (or
    /// moved) are removed. A folder rename therefore updates every entry
    /// beneath the new path without rebuilding unaffected records.
    func synchronize(changedAbsolutePaths: [String]) throws {
        guard let vaultRoot else {
            throw SearchIndexError.sqlite("synchronize requires a vault root")
        }
        lock.lock(); defer { lock.unlock() }

        let currentPaths = Set(entryPaths(in: vaultRoot))
        let indexedPaths = try indexedEntryPathsUnlocked()
        let standardizedChanges = changedAbsolutePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let affectedPaths: Set<RelativePath>
        if standardizedChanges.isEmpty {
            affectedPaths = currentPaths
        } else {
            affectedPaths = Set(currentPaths.filter { relativePath in
                let entryPath = vaultRoot.appendingRelativePath(relativePath)
                    .standardizedFileURL.path
                return standardizedChanges.contains { changedPath in
                    changedPath == entryPath
                        || changedPath.hasPrefix(entryPath + "/")
                        || entryPath.hasPrefix(changedPath + "/")
                }
            })
        }

        let refreshed = affectedPaths.map { relativePath in
            let entryURL = vaultRoot.appendingRelativePath(relativePath)
            return (
                relativePath,
                Self.fingerprint(at: entryURL),
                recordsForEntry(at: entryURL, relativePath: relativePath)
            )
        }
        try transaction {
            for stalePath in indexedPaths.subtracting(currentPaths) {
                try removeEntryUnlocked(stalePath)
                try deleteFingerprintUnlocked(stalePath)
            }
            for (relativePath, fingerprint, records) in refreshed {
                try removeEntryUnlocked(relativePath)
                for record in records { try upsertUnlocked(record) }
                try writeFingerprintUnlocked(relativePath, fingerprint: fingerprint)
            }
        }
    }

    /// Brings an existing cache up to date without re-parsing the corpus.
    ///
    /// Every entry carries a fingerprint of the files its records were built
    /// from; entries whose fingerprint still matches are left untouched, so a
    /// vault that did not change between launches costs two `stat` calls per
    /// entry instead of a full decode-and-reindex of every transcript. A
    /// database written before fingerprints existed simply has none, which
    /// reconciles as "everything changed" once and is fast from then on.
    func reconcile() throws {
        guard let vaultRoot else {
            throw SearchIndexError.sqlite("reconcile requires a vault root")
        }
        lock.lock(); defer { lock.unlock() }

        let currentPaths = entryPaths(in: vaultRoot)
        let stored = try storedFingerprintsUnlocked()
        let stalePaths = Set(stored.keys).subtracting(currentPaths)
        // Reading the changed entries outside the transaction keeps the write
        // lock short even when a sync client rewrote a large part of the vault.
        let changed = currentPaths.compactMap { relativePath -> (RelativePath, String, [SearchRecord])? in
            let entryURL = vaultRoot.appendingRelativePath(relativePath)
            let fingerprint = Self.fingerprint(at: entryURL)
            guard stored[relativePath] != fingerprint else { return nil }
            return (
                relativePath,
                fingerprint,
                recordsForEntry(at: entryURL, relativePath: relativePath)
            )
        }
        guard !changed.isEmpty || !stalePaths.isEmpty else { return }

        try transaction {
            for stalePath in stalePaths {
                try removeEntryUnlocked(stalePath)
                try deleteFingerprintUnlocked(stalePath)
            }
            for (relativePath, fingerprint, records) in changed {
                try removeEntryUnlocked(relativePath)
                for record in records { try upsertUnlocked(record) }
                try writeFingerprintUnlocked(relativePath, fingerprint: fingerprint)
            }
        }
    }

    func rebuild() throws {
        lock.lock(); defer { lock.unlock() }
        try rebuildUnlocked()
    }

    /// Validates a live cache and reconstructs it from the vault if SQLite
    /// reports damage. Returns true when a recovery was performed.
    @discardableResult
    func recoverIfNeeded() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try quickCheck()
            return false
        } catch {
            sqlite3_close(database)
            database = nil
            try resetDatabaseFiles()
            try openAndValidate()
            if vaultRoot != nil { try rebuildUnlocked() }
            return true
        }
    }

    func search(_ query: String, fuzzy: Bool = false, limit: Int = 100) throws -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }

        var hits: [SearchHit] = []
        // Trigram FTS supplies exact-mode candidates for normal-length
        // queries; Swift then verifies the literal substring and computes its
        // precise UTF-16 range. Very short and fuzzy queries scan the cached
        // records because FTS trigrams cannot represent them.
        let fuzzyQuery = fuzzy ? FuzzyQuery(query: query) : nil
        let usesFTSCandidates = !fuzzy && query.count >= 3
        let statement = try prepare(usesFTSCandidates ? """
            SELECT r.entry_path, r.layer, r.title, r.content
            FROM search_records r JOIN search_fts f ON f.rowid = r.rowid
            WHERE search_fts MATCH ?
            """ : "SELECT entry_path, layer, title, content FROM search_records")
        defer { sqlite3_finalize(statement) }
        if usesFTSCandidates {
            let quoted = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try bind(quoted, to: statement, at: 1)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            // A superseded keystroke must be able to abandon its scan: the
            // caller's task is already cancelled by then, and without these
            // checks the stale scan runs to completion on the vault actor and
            // everything queued behind it — autosaves included — waits.
            try Task.checkCancellation()
            let record = SearchRecord(
                entryPath: columnText(statement, 0),
                layer: SearchLayer(rawValue: columnText(statement, 1)) ?? .original,
                title: columnText(statement, 2),
                content: columnText(statement, 3)
            )
            if let match = try Self.match(query, fuzzy: fuzzyQuery, in: record.content) {
                hits.append(Self.hit(for: record, match: match, kind: .content))
            } else if let match = try Self.match(query, fuzzy: fuzzyQuery, in: record.title) {
                hits.append(Self.hit(for: record, match: match, kind: .title))
            }
        }
        try checkStep(statement)

        hits.sort {
            if $0.layer.rank != $1.layer.rank { return $0.layer.rank < $1.layer.rank }
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.entryPath != $1.entryPath {
                return $0.entryPath.localizedStandardCompare($1.entryPath) == .orderedAscending
            }
            return $0.matchRange.lowerBound < $1.matchRange.lowerBound
        }
        return Array(hits.prefix(limit))
    }

    func recordCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT count(*) FROM search_records")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { try checkStep(statement); return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func usesFTS5() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='search_fts'"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { try checkStep(statement); return false }
        return columnText(statement, 0).lowercased().contains("fts5")
    }

    // MARK: - SQLite lifecycle

    private func openAndValidate() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try quickCheck()
        try createSchema()
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS search_records (
          entry_path TEXT NOT NULL,
          layer TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          PRIMARY KEY(entry_path, layer)
        );
        CREATE TABLE IF NOT EXISTS search_meta (
          entry_path TEXT PRIMARY KEY,
          fingerprint TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
          title, content, entry_path UNINDEXED, layer UNINDEXED, tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS search_records_ai AFTER INSERT ON search_records BEGIN
          INSERT INTO search_fts(rowid, title, content, entry_path, layer)
          VALUES (new.rowid, new.title, new.content, new.entry_path, new.layer);
        END;
        CREATE TRIGGER IF NOT EXISTS search_records_ad AFTER DELETE ON search_records BEGIN
          DELETE FROM search_fts WHERE rowid = old.rowid;
        END;
        CREATE TRIGGER IF NOT EXISTS search_records_au AFTER UPDATE ON search_records BEGIN
          DELETE FROM search_fts WHERE rowid = old.rowid;
          INSERT INTO search_fts(rowid, title, content, entry_path, layer)
          VALUES (new.rowid, new.title, new.content, new.entry_path, new.layer);
        END;
        """)
    }

    private func quickCheck() throws {
        let statement = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              columnText(statement, 0).lowercased() == "ok" else {
            throw sqliteError()
        }
    }

    private func resetDatabaseFiles() throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    // MARK: - Records

    private func upsertUnlocked(_ record: SearchRecord) throws {
        let statement = try prepare("""
        INSERT INTO search_records(entry_path, layer, title, content) VALUES (?, ?, ?, ?)
        ON CONFLICT(entry_path, layer) DO UPDATE SET title=excluded.title, content=excluded.content
        """)
        defer { sqlite3_finalize(statement) }
        try bind(record.entryPath, to: statement, at: 1)
        try bind(record.layer.rawValue, to: statement, at: 2)
        try bind(record.title, to: statement, at: 3)
        try bind(record.content, to: statement, at: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func removeEntryUnlocked(_ relativePath: RelativePath) throws {
        let statement = try prepare("DELETE FROM search_records WHERE entry_path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(relativePath, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func rebuildUnlocked() throws {
        guard let vaultRoot else {
            throw SearchIndexError.sqlite("rebuild requires a vault root")
        }
        let rebuilt = entryPaths(in: vaultRoot).map { path -> (RelativePath, String, [SearchRecord]) in
            let entryURL = vaultRoot.appendingRelativePath(path)
            return (path, Self.fingerprint(at: entryURL), recordsForEntry(at: entryURL, relativePath: path))
        }
        try transaction {
            try execute("DELETE FROM search_records")
            try execute("DELETE FROM search_meta")
            for (path, fingerprint, records) in rebuilt {
                for record in records { try upsertUnlocked(record) }
                try writeFingerprintUnlocked(path, fingerprint: fingerprint)
            }
        }
    }

    // MARK: - Fingerprints

    /// Identity of everything `recordsForEntry` reads: the markdown file's
    /// name, size and modification date, and the same for the original
    /// transcript. The entry folder's own name is the key these are stored
    /// under, so a rename is a different row rather than a missed change.
    private static func fingerprint(at entryURL: URL) -> String {
        func stamp(_ url: URL?) -> String {
            guard let url,
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey]
                  ),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize else { return "-" }
            return "\(url.lastPathComponent)|\(modified.timeIntervalSince1970)|\(size)"
        }
        let markdownURL = TranscriptFile.url(inEntry: entryURL)
        return stamp(markdownURL) + "::" + stamp(TranscriptOriginal.url(inEntry: entryURL))
    }

    private func storedFingerprintsUnlocked() throws -> [RelativePath: String] {
        let statement = try prepare("SELECT entry_path, fingerprint FROM search_meta")
        defer { sqlite3_finalize(statement) }
        var result: [RelativePath: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[columnText(statement, 0)] = columnText(statement, 1)
        }
        try checkStep(statement)
        return result
    }

    private func writeFingerprintUnlocked(
        _ relativePath: RelativePath, fingerprint: String
    ) throws {
        let statement = try prepare("""
        INSERT INTO search_meta(entry_path, fingerprint) VALUES (?, ?)
        ON CONFLICT(entry_path) DO UPDATE SET fingerprint=excluded.fingerprint
        """)
        defer { sqlite3_finalize(statement) }
        try bind(relativePath, to: statement, at: 1)
        try bind(fingerprint, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func deleteFingerprintUnlocked(_ relativePath: RelativePath) throws {
        let statement = try prepare("DELETE FROM search_meta WHERE entry_path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(relativePath, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func recordsForEntry(at entryURL: URL, relativePath: RelativePath) -> [SearchRecord] {
        var records: [SearchRecord] = []
        var title = EntryFolderName(parsing: relativePath.lastComponent)?.slug?
            .split(separator: "-").joined(separator: " ").capitalized ?? ""
        // Rendered with the entry's speaker renames so original-layer match
        // offsets index straight into the synced view's word map.
        var speakerNames: [String: String] = [:]
        let original = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        if let markdownURL = TranscriptFile.url(inEntry: entryURL),
           let text = try? String(contentsOf: markdownURL, encoding: .utf8) {
            let document = FrontmatterDocument.parse(text)
            title = document.title ?? title
            speakerNames = SpeakerNames.names(in: document)
            // Before the first edit, transcript.md is merely the generated
            // projection of Original. Indexing it twice produces two visually
            // identical results. A real fork (including an external edit
            // without the explicit flag) gets its own higher-ranked record.
            if original == nil || TranscriptEditDocument.isForked(document, comparedTo: original) {
                records.append(SearchRecord(
                    entryPath: relativePath, layer: .edited, title: title, content: document.body
                ))
            }
        }
        if let original {
            records.append(SearchRecord(
                entryPath: relativePath,
                layer: .original,
                title: title,
                content: TranscriptMarkdown.body(from: original, speakerNames: speakerNames)
            ))
        }
        return records
    }

    private func indexedEntryPathsUnlocked() throws -> Set<RelativePath> {
        let statement = try prepare("SELECT DISTINCT entry_path FROM search_records")
        defer { sqlite3_finalize(statement) }
        var paths: Set<RelativePath> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            paths.insert(columnText(statement, 0))
        }
        try checkStep(statement)
        return paths
    }

    private func entryPaths(in root: URL) -> [RelativePath] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [RelativePath] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true
            guard isDirectory else { continue }
            if EntryFolderName(parsing: url.lastPathComponent) != nil {
                let rootPath = root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                result.append(relative)
                enumerator.skipDescendants()
            }
        }
        return result.sorted()
    }

    // MARK: - Matching

    private struct Match {
        var range: Range<Int>
        var score: Int
    }

    /// The query as the fuzzy scan needs it: tokenized once for the whole
    /// search rather than per record.
    private struct FuzzyQuery {
        /// Number of content words one window spans.
        var windowSize: Int
        /// Query words lowercased and joined by single spaces.
        var normalized: [Character]
        var threshold: Int

        init?(query: String) {
            let words = tokens(in: query)
            guard !words.isEmpty else { return nil }
            let text = words.map(\.text).joined(separator: " ").lowercased()
            windowSize = words.count
            normalized = Array(text)
            threshold = text.count >= 8 ? 2 : 1
        }
    }

    private static func match(
        _ query: String, fuzzy: FuzzyQuery?, in content: String
    ) throws -> Match? {
        if let range = content.range(of: query, options: [.caseInsensitive]) {
            return Match(range: utf16Range(range, in: content), score: 0)
        }
        guard let fuzzy else { return nil }
        let contentWords = tokens(in: content)
        guard contentWords.count >= fuzzy.windowSize else { return nil }
        return try windowMatch(contentWords: contentWords, query: fuzzy)
    }

    /// Slides a query-sized word window across the record.
    ///
    /// The comparison text — the window's words lowercased and joined by
    /// single spaces — is materialized once as a flat character buffer, so a
    /// window is a contiguous slice instead of a freshly joined, lowercased
    /// string. Two lower bounds on Damerau-Levenshtein distance then reject
    /// almost every window before the distance matrix runs: the length must be
    /// reachable within `threshold` insertions or deletions, and the
    /// character-bag difference must be reachable at all (a substitution moves
    /// the bag by 2, an insertion or deletion by 1, a transposition by 0, so
    /// distance is at least half the bag difference). Neither bound can
    /// discard a window that would have matched, so the surviving results are
    /// exactly the ones the exhaustive scan produced.
    private static func windowMatch(
        contentWords: [Token], query: FuzzyQuery
    ) throws -> Match? {
        let windowSize = query.windowSize
        var flat: [Character] = []
        flat.reserveCapacity(contentWords.reduce(contentWords.count) { $0 + $1.text.count })
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(contentWords.count)
        ends.reserveCapacity(contentWords.count)
        for (offset, token) in contentWords.enumerated() {
            if offset > 0 { flat.append(" ") }
            starts.append(flat.count)
            flat.append(contentsOf: token.text.lowercased())
            ends.append(flat.count)
        }

        var bag = CharacterBag(query: query.normalized)
        var low = starts[0]
        var high = ends[windowSize - 1]
        for index in low..<high { bag.add(flat[index]) }

        var best: Match?
        for start in 0...(contentWords.count - windowSize) {
            if start > 0 {
                let nextLow = starts[start]
                let nextHigh = ends[start + windowSize - 1]
                for index in low..<nextLow { bag.remove(flat[index]) }
                for index in high..<nextHigh { bag.add(flat[index]) }
                low = nextLow
                high = nextHigh
            }
            if start & 0xFFF == 0 { try Task.checkCancellation() }
            guard abs((high - low) - query.normalized.count) <= query.threshold,
                  bag.difference <= 2 * query.threshold else { continue }
            let distance = damerauLevenshtein(
                flat[low..<high], query.normalized, maximum: query.threshold
            )
            guard distance <= query.threshold, best == nil || distance < best!.score else { continue }
            let end = start + windowSize - 1
            best = Match(
                range: contentWords[start].range.lowerBound..<contentWords[end].range.upperBound,
                score: distance
            )
            // The earliest window holding the smallest distance wins, and
            // nothing beats zero — so this is the answer the full scan reached.
            if distance == 0 { break }
        }
        return best
    }

    /// Running per-character count difference between the current window and
    /// the query, updated as the window slides rather than recomputed. ASCII
    /// uses a flat table; anything else falls back to a dictionary.
    private struct CharacterBag {
        private var asciiDelta = [Int](repeating: 0, count: 128)
        private var otherDelta: [Character: Int] = [:]
        private(set) var difference = 0

        init(query: [Character]) {
            for character in query { adjust(character, by: -1) }
        }

        mutating func add(_ character: Character) { adjust(character, by: 1) }
        mutating func remove(_ character: Character) { adjust(character, by: -1) }

        private mutating func adjust(_ character: Character, by delta: Int) {
            if let ascii = character.asciiValue {
                let index = Int(ascii)
                let previous = asciiDelta[index]
                asciiDelta[index] = previous + delta
                difference += abs(previous + delta) - abs(previous)
            } else {
                let previous = otherDelta[character] ?? 0
                otherDelta[character] = previous + delta
                difference += abs(previous + delta) - abs(previous)
            }
        }
    }

    private struct Token {
        var text: String
        var range: Range<Int>
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) {
            substring, range, _, _ in
            guard let substring else { return }
            tokens.append(Token(text: substring, range: utf16Range(range, in: text)))
        }
        return tokens
    }

    /// Rows are recycled across iterations and both operands arrive as
    /// character arrays, so a window costs no allocation at all.
    private static func damerauLevenshtein(
        _ a: ArraySlice<Character>, _ b: [Character], maximum: Int
    ) -> Int {
        if abs(a.count - b.count) > maximum { return maximum + 1 }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        let base = a.startIndex
        var previousPrevious = Array(0...b.count)
        var previous = previousPrevious
        var current = previousPrevious
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            let left = a[base + i - 1]
            for j in 1...b.count {
                let cost = left == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, left == b[j - 2], a[base + i - 2] == b[j - 1] {
                    current[j] = min(current[j], previousPrevious[j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func hit(
        for record: SearchRecord,
        match: Match,
        kind: SearchMatchKind
    ) -> SearchHit {
        let sourceText = kind == .content ? record.content : record.title
        let source = sourceText as NSString
        let matchLength = match.range.count
        let desiredStart = max(0, match.range.lowerBound - 60)
        let desiredEnd = min(
            source.length,
            max(match.range.upperBound + 80, desiredStart + 160)
        )
        // UTF-16 offsets are the API contract, but snippet boundaries must
        // not split an emoji or combining-character sequence.
        let snippetRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: desiredStart, length: desiredEnd - desiredStart)
        )
        let start = snippetRange.location
        let end = NSMaxRange(snippetRange)
        var snippet = source.substring(with: snippetRange)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < source.length ? "…" : ""
        snippet = prefix + snippet + suffix
        let localStart = prefix.utf16.count + match.range.lowerBound - start
        return SearchHit(
            entryPath: record.entryPath,
            layer: record.layer,
            title: record.title,
            snippet: snippet,
            matchKind: kind,
            matchRange: match.range,
            snippetMatchRange: localStart..<(localStart + matchLength),
            score: match.score
        )
    }

    private static func utf16Range(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = range.lowerBound.utf16Offset(in: text)
        return lower..<range.upperBound.utf16Offset(in: text)
    }

    // MARK: - SQLite helpers

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
            sqlite3_free(message)
            throw SearchIndexError.sqlite(detail ?? String(cString: sqlite3_errmsg(database)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
        guard result == SQLITE_OK else { throw sqliteError() }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func checkStep(_ statement: OpaquePointer) throws {
        let code = sqlite3_errcode(database)
        if code != SQLITE_OK && code != SQLITE_DONE { throw sqliteError() }
    }

    private func sqliteError() -> SearchIndexError {
        SearchIndexError.sqlite(database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error")
    }
}
