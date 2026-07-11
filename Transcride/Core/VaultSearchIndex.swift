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
            try removeEntryUnlocked(relativePath)
            return
        }
        let records = recordsForEntry(at: entryURL, relativePath: relativePath)
        try transaction {
            try removeEntryUnlocked(relativePath)
            for record in records { try upsertUnlocked(record) }
        }
    }

    func removeEntry(_ relativePath: RelativePath) throws {
        lock.lock(); defer { lock.unlock() }
        try removeEntryUnlocked(relativePath)
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

        try transaction {
            for stalePath in indexedPaths.subtracting(currentPaths) {
                try removeEntryUnlocked(stalePath)
            }
            for relativePath in affectedPaths {
                try removeEntryUnlocked(relativePath)
                for record in recordsForEntry(
                    at: vaultRoot.appendingRelativePath(relativePath),
                    relativePath: relativePath
                ) {
                    try upsertUnlocked(record)
                }
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
            let record = SearchRecord(
                entryPath: columnText(statement, 0),
                layer: SearchLayer(rawValue: columnText(statement, 1)) ?? .original,
                title: columnText(statement, 2),
                content: columnText(statement, 3)
            )
            if let match = Self.match(query, in: record.content, fuzzy: fuzzy) {
                hits.append(Self.hit(for: record, match: match, kind: .content))
            } else if let match = Self.match(query, in: record.title, fuzzy: fuzzy) {
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
        let paths = entryPaths(in: vaultRoot)
        var records: [SearchRecord] = []
        for path in paths {
            records += recordsForEntry(
                at: vaultRoot.appendingRelativePath(path), relativePath: path
            )
        }
        try transaction {
            try execute("DELETE FROM search_records")
            for record in records { try upsertUnlocked(record) }
        }
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

    private static func match(_ query: String, in content: String, fuzzy: Bool) -> Match? {
        if let range = content.range(of: query, options: [.caseInsensitive]) {
            return Match(range: utf16Range(range, in: content), score: 0)
        }
        guard fuzzy else { return nil }

        let queryWords = tokens(in: query)
        guard !queryWords.isEmpty else { return nil }
        let contentWords = tokens(in: content)
        guard contentWords.count >= queryWords.count else { return nil }
        let normalizedQuery = queryWords.map(\.text).joined(separator: " ").lowercased()
        let threshold = normalizedQuery.count >= 8 ? 2 : 1
        var best: Match?
        for start in 0...(contentWords.count - queryWords.count) {
            let end = start + queryWords.count - 1
            let candidate = contentWords[start...end].map(\.text).joined(separator: " ").lowercased()
            let distance = damerauLevenshtein(candidate, normalizedQuery, maximum: threshold)
            guard distance <= threshold else { continue }
            let range = contentWords[start].range.lowerBound..<contentWords[end].range.upperBound
            if best == nil || distance < best!.score { best = Match(range: range, score: distance) }
        }
        return best
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

    private static func damerauLevenshtein(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > maximum { return maximum + 1 }
        var previousPrevious = Array(0...b.count)
        var previous = previousPrevious
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previousPrevious[j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maximum { return maximum + 1 }
            previousPrevious = previous
            previous = current
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
