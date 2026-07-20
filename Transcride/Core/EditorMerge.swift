import CryptoKit
import Foundation

enum EditorMergeOrigin: String, Codable, Sendable {
    case mine
    case external
}

struct EditorLineChange: Codable, Equatable, Sendable {
    var lowerBound: Int
    var upperBound: Int
    var replacement: [String]
    var origin: EditorMergeOrigin

    var range: Range<Int> { lowerBound..<upperBound }
}

struct EditorMergedBody: Codable, Equatable, Sendable {
    var body: String
    var mineChanges: [EditorLineChange]
    var externalChanges: [EditorLineChange]
}

struct EditorMergeConflictHunk: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var lowerBound: Int
    var upperBound: Int
    var base: String
    var mine: String
    var external: String

    init(
        id: UUID = UUID(),
        lowerBound: Int,
        upperBound: Int,
        base: String,
        mine: String,
        external: String
    ) {
        self.id = id
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.base = base
        self.mine = mine
        self.external = external
    }
}

enum EditorConflictChoice: String, Codable, Sendable {
    case mine
    case external
    case keepBoth
}

struct EditorMergeConflict: Codable, Equatable, Sendable {
    var base: String
    var mine: String
    var external: String
    var hunks: [EditorMergeConflictHunk]

    func resolvedBody(choices: [UUID: EditorConflictChoice]) -> String? {
        guard hunks.allSatisfy({ choices[$0.id] != nil }) else { return nil }
        let baseLines = EditorBodyMerger.lines(in: base)
        let mineChanges = EditorBodyMerger.changes(from: baseLines, to: EditorBodyMerger.lines(in: mine), origin: .mine)
        let externalChanges = EditorBodyMerger.changes(from: baseLines, to: EditorBodyMerger.lines(in: external), origin: .external)

        var allChanges = EditorBodyMerger.nonconflictingChanges(
            mine: mineChanges,
            external: externalChanges
        )
        for hunk in hunks {
            let replacement: String
            switch choices[hunk.id]! {
            case .mine: replacement = hunk.mine
            case .external: replacement = hunk.external
            case .keepBoth: replacement = EditorBodyMerger.keepBoth(mine: hunk.mine, external: hunk.external)
            }
            allChanges.append(EditorLineChange(
                lowerBound: hunk.lowerBound,
                upperBound: hunk.upperBound,
                replacement: EditorBodyMerger.lines(in: replacement),
                origin: .mine
            ))
        }
        return EditorBodyMerger.apply(allChanges, to: baseLines).joined()
    }
}

enum EditorThreeWayMergeResult: Equatable, Sendable {
    case merged(EditorMergedBody)
    case conflict(EditorMergeConflict)
}

enum EditorBodyMerger {
    static func utf16Patches(from source: String, to target: String) -> [EditorUTF16Patch] {
        let sourceLines = lines(in: source)
        let targetLines = lines(in: target)
        let lineChanges = changes(from: sourceLines, to: targetLines, origin: .external)
        var offsets = [0]
        offsets.reserveCapacity(sourceLines.count + 1)
        for line in sourceLines {
            offsets.append(offsets.last! + line.utf16.count)
        }
        return lineChanges.map { change in
            EditorUTF16Patch(
                from: offsets[change.lowerBound],
                to: offsets[change.upperBound],
                insert: change.replacement.joined()
            )
        }
    }

    static func merge(base: String, mine: String, external: String) -> EditorThreeWayMergeResult {
        if mine == external {
            return .merged(EditorMergedBody(body: mine, mineChanges: [], externalChanges: []))
        }

        let baseLines = lines(in: base)
        let mineChanges = changes(from: baseLines, to: lines(in: mine), origin: .mine)
        let externalChanges = changes(from: baseLines, to: lines(in: external), origin: .external)
        let clusters = conflictClusters(mine: mineChanges, external: externalChanges)
        guard !clusters.isEmpty else {
            let combined = deduplicated(mineChanges + externalChanges)
            return .merged(EditorMergedBody(
                body: apply(combined, to: baseLines).joined(),
                mineChanges: mineChanges,
                externalChanges: externalChanges
            ))
        }

        let hunks = clusters.map { cluster in
            let range = clusterRange(cluster)
            let basePart = Array(baseLines[range]).joined()
            let minePart = apply(cluster.filter { $0.origin == .mine }, toSliceOf: baseLines, range: range).joined()
            let externalPart = apply(cluster.filter { $0.origin == .external }, toSliceOf: baseLines, range: range).joined()
            return EditorMergeConflictHunk(
                lowerBound: range.lowerBound,
                upperBound: range.upperBound,
                base: basePart,
                mine: minePart,
                external: externalPart
            )
        }
        return .conflict(EditorMergeConflict(
            base: base,
            mine: mine,
            external: external,
            hunks: hunks
        ))
    }

    static func keepBoth(mine: String, external: String) -> String {
        guard !mine.isEmpty else { return external }
        guard !external.isEmpty else { return mine }
        if mine.last?.isNewline == true || external.first?.isNewline == true {
            return mine + external
        }
        let separator = mine.reversed().first(where: \.isNewline).map(String.init)
            ?? external.first(where: \.isNewline).map(String.init)
            ?? "\n"
        return mine + separator + external
    }

    static func lines(in body: String) -> [String] {
        guard !body.isEmpty else { return [] }
        var result: [String] = []
        var start = body.startIndex
        while start < body.endIndex {
            // Swift treats CRLF as one extended grapheme cluster, so looking
            // only for the Character "\n" misses Windows line endings. Find
            // any newline grapheme and retain its exact bytes in the token.
            if let newline = body[start...].firstIndex(where: \.isNewline) {
                let after = body.index(after: newline)
                result.append(String(body[start..<after]))
                start = after
            } else {
                result.append(String(body[start...]))
                break
            }
        }
        return result
    }

    static func changes(
        from base: [String],
        to target: [String],
        origin: EditorMergeOrigin
    ) -> [EditorLineChange] {
        let difference = target.difference(from: base)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var result: [EditorLineChange] = []
        var baseIndex = 0
        var targetIndex = 0
        var changeStart: Int?
        var replacement: [String] = []

        func flush() {
            guard let start = changeStart else { return }
            result.append(EditorLineChange(
                lowerBound: start,
                upperBound: baseIndex,
                replacement: replacement,
                origin: origin
            ))
            changeStart = nil
            replacement.removeAll(keepingCapacity: true)
        }

        while baseIndex < base.count || targetIndex < target.count {
            let removes = baseIndex < base.count && removals.contains(baseIndex)
            let inserts = targetIndex < target.count && insertions.contains(targetIndex)
            if removes || inserts {
                changeStart = changeStart ?? baseIndex
                if removes { baseIndex += 1 }
                if inserts {
                    replacement.append(target[targetIndex])
                    targetIndex += 1
                }
                continue
            }

            if baseIndex < base.count, targetIndex < target.count,
               base[baseIndex] == target[targetIndex] {
                flush()
                baseIndex += 1
                targetIndex += 1
            } else if targetIndex < target.count {
                // Defensive fallback for an unexpected CollectionDifference
                // alignment: treat the unmatched pair as one replacement.
                changeStart = changeStart ?? baseIndex
                if baseIndex < base.count { baseIndex += 1 }
                replacement.append(target[targetIndex])
                targetIndex += 1
            } else {
                changeStart = changeStart ?? baseIndex
                baseIndex += 1
            }
        }
        flush()
        return result
    }

    static func nonconflictingChanges(
        mine: [EditorLineChange],
        external: [EditorLineChange]
    ) -> [EditorLineChange] {
        let conflicts = conflictClusters(mine: mine, external: external).flatMap { $0 }
        return deduplicated((mine + external).filter { change in
            !conflicts.contains(change)
        })
    }

    static func apply(_ changes: [EditorLineChange], to base: [String]) -> [String] {
        var result = base
        for change in deduplicated(changes).sorted(by: descendingChangeOrder) {
            result.replaceSubrange(change.range, with: change.replacement)
        }
        return result
    }

    private static func apply(
        _ changes: [EditorLineChange],
        toSliceOf base: [String],
        range: Range<Int>
    ) -> [String] {
        var slice = Array(base[range])
        for change in deduplicated(changes).sorted(by: descendingChangeOrder) {
            let local = (change.lowerBound - range.lowerBound)..<(change.upperBound - range.lowerBound)
            slice.replaceSubrange(local, with: change.replacement)
        }
        return slice
    }

    private static func deduplicated(_ changes: [EditorLineChange]) -> [EditorLineChange] {
        var result: [EditorLineChange] = []
        for change in changes.sorted(by: ascendingChangeOrder) {
            if result.contains(where: {
                $0.lowerBound == change.lowerBound &&
                $0.upperBound == change.upperBound &&
                $0.replacement == change.replacement
            }) { continue }
            result.append(change)
        }
        return result
    }

    private static func conflictClusters(
        mine: [EditorLineChange],
        external: [EditorLineChange]
    ) -> [[EditorLineChange]] {
        let all = mine + external
        var adjacency = Array(repeating: Set<Int>(), count: all.count)
        for mineIndex in mine.indices {
            for externalIndex in external.indices {
                let rightIndex = mine.count + externalIndex
                if changesConflict(mine[mineIndex], external[externalIndex]) {
                    adjacency[mineIndex].insert(rightIndex)
                    adjacency[rightIndex].insert(mineIndex)
                }
            }
        }

        var visited = Set<Int>()
        var clusters: [[EditorLineChange]] = []
        for index in all.indices where !adjacency[index].isEmpty && !visited.contains(index) {
            var stack = [index]
            var cluster: [EditorLineChange] = []
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                cluster.append(all[current])
                stack.append(contentsOf: adjacency[current])
            }
            clusters.append(cluster)
        }
        return clusters.sorted { clusterRange($0).lowerBound < clusterRange($1).lowerBound }
    }

    private static func changesConflict(_ lhs: EditorLineChange, _ rhs: EditorLineChange) -> Bool {
        if lhs.lowerBound == rhs.lowerBound,
           lhs.upperBound == rhs.upperBound,
           lhs.replacement == rhs.replacement { return false }

        if lhs.range.isEmpty && rhs.range.isEmpty {
            return lhs.lowerBound == rhs.lowerBound
        }
        if lhs.range.isEmpty {
            return lhs.lowerBound > rhs.lowerBound && lhs.lowerBound < rhs.upperBound
        }
        if rhs.range.isEmpty {
            return rhs.lowerBound > lhs.lowerBound && rhs.lowerBound < lhs.upperBound
        }
        return lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func clusterRange(_ cluster: [EditorLineChange]) -> Range<Int> {
        let lower = cluster.map(\.lowerBound).min() ?? 0
        let upper = cluster.map(\.upperBound).max() ?? lower
        return lower..<upper
    }

    private static func ascendingChangeOrder(_ lhs: EditorLineChange, _ rhs: EditorLineChange) -> Bool {
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
        if lhs.upperBound != rhs.upperBound { return lhs.upperBound < rhs.upperBound }
        return lhs.origin.rawValue < rhs.origin.rawValue
    }

    private static func descendingChangeOrder(_ lhs: EditorLineChange, _ rhs: EditorLineChange) -> Bool {
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound > rhs.lowerBound }
        // At a shared boundary, replacements run before insertions so an
        // insertion remains at that boundary rather than being consumed.
        if lhs.upperBound != rhs.upperBound { return lhs.upperBound > rhs.upperBound }
        return lhs.origin.rawValue > rhs.origin.rawValue
    }
}

struct EditorRecoveryDraft: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var id: UUID
    var vaultID: String
    var entryID: String
    var entryPath: String
    var base: String
    var mine: String
    var external: String
    var baseRevision: EditorBodyRevision
    var externalRevision: EditorBodyRevision
    var timestamp: Date

    init(
        id: UUID = UUID(),
        vaultID: String,
        entryID: String,
        entryPath: String,
        base: String,
        mine: String,
        external: String,
        baseRevision: EditorBodyRevision? = nil,
        externalRevision: EditorBodyRevision? = nil,
        timestamp: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.vaultID = vaultID
        self.entryID = entryID
        self.entryPath = entryPath
        self.base = base
        self.mine = mine
        self.external = external
        self.baseRevision = baseRevision ?? EditorBodyRevision(body: base)
        self.externalRevision = externalRevision ?? EditorBodyRevision(body: external)
        self.timestamp = timestamp
    }
}

enum EditorVaultIdentity {
    /// Recovery state is app-support data, so a relative entry path is not a
    /// sufficient identity. Hash the canonical root without exposing the
    /// user's vault path in the recovery directory or JSON record.
    static func identifier(forRootURL rootURL: URL) -> String {
        let canonicalPath = rootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path(percentEncoded: false)
        return SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct EditorRecoveryDraftStore: Sendable {
    struct ScanFailure: Equatable, Sendable {
        var fileName: String
        var message: String
    }

    struct ScanResult: Equatable, Sendable {
        var drafts: [EditorRecoveryDraft]
        var failures: [ScanFailure]
    }

    var rootDirectoryURL: URL
    var vaultID: String

    var directoryURL: URL {
        rootDirectoryURL.appendingPathComponent(vaultID, isDirectory: true)
    }

    func persist(_ draft: EditorRecoveryDraft) throws {
        guard draft.vaultID == vaultID else {
            throw EditorRecoveryDraftStoreError.vaultMismatch(
                expected: vaultID,
                received: draft.vaultID
            )
        }
        try validate(draft)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destination = fileURL(for: draft.id)
        if FileManager.default.fileExists(atPath: destination.path),
           let existing = try? load(id: draft.id),
           existing.entryID != draft.entryID {
            throw EditorRecoveryDraftStoreError.identityReuse(
                expected: existing.entryID,
                received: draft.entryID
            )
        }
        let data = try JSONEncoder.editorRecovery.encode(draft)
        try AtomicFile.write(data, to: destination)
        var removedPredecessor = false
        for predecessor in scanDrafts().drafts where
            predecessor.entryID == draft.entryID && predecessor.id != draft.id {
            try FileManager.default.removeItem(at: fileURL(for: predecessor.id))
            removedPredecessor = true
        }
        if removedPredecessor {
            try AtomicFile.synchronizeDirectory(at: directoryURL)
        }
    }

    func load(id: UUID) throws -> EditorRecoveryDraft? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder.editorRecovery.decode(
            EditorRecoveryDraft.self,
            from: Data(contentsOf: url)
        )
        guard draft.schemaVersion == EditorRecoveryDraft.currentSchemaVersion else {
            throw EditorRecoveryDraftStoreError.unsupportedSchema(draft.schemaVersion)
        }
        guard draft.vaultID == vaultID else {
            throw EditorRecoveryDraftStoreError.vaultMismatch(
                expected: vaultID,
                received: draft.vaultID
            )
        }
        try validate(draft)
        return draft
    }

    func allDrafts() throws -> [EditorRecoveryDraft] {
        scanDrafts().drafts
    }

    /// Corrupt or unsupported records are isolated per file so one damaged
    /// JSON document can never hide a different note's valid recovery draft.
    func scanDrafts() -> ScanResult {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return ScanResult(drafts: [], failures: [])
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            return ScanResult(
                drafts: [],
                failures: [ScanFailure(
                    fileName: directoryURL.lastPathComponent,
                    message: error.localizedDescription
                )]
            )
        }
        var drafts: [EditorRecoveryDraft] = []
        var failures: [ScanFailure] = []
        for url in urls {
            do {
                let draft = try JSONDecoder.editorRecovery.decode(
                    EditorRecoveryDraft.self,
                    from: Data(contentsOf: url)
                )
                guard draft.schemaVersion == EditorRecoveryDraft.currentSchemaVersion else {
                    throw EditorRecoveryDraftStoreError.unsupportedSchema(draft.schemaVersion)
                }
                guard draft.vaultID == vaultID else {
                    throw EditorRecoveryDraftStoreError.vaultMismatch(
                        expected: vaultID,
                        received: draft.vaultID
                    )
                }
                try validate(draft)
                drafts.append(draft)
            } catch {
                failures.append(ScanFailure(
                    fileName: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        return ScanResult(
            drafts: drafts.sorted { $0.timestamp < $1.timestamp },
            failures: failures.sorted { $0.fileName < $1.fileName }
        )
    }

    /// A cancellation or failed save must retain the draft. Call this only at
    /// the end of the durable compare-and-save path.
    @discardableResult
    func deleteAfterResolution(id: UUID, durablySaved: Bool) throws -> Bool {
        guard durablySaved else { return false }
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        try FileManager.default.removeItem(at: url)
        try AtomicFile.synchronizeDirectory(at: directoryURL)
        return true
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func validate(_ draft: EditorRecoveryDraft) throws {
        guard !draft.vaultID.isEmpty, !draft.entryID.isEmpty,
              !draft.entryPath.isEmpty else {
            throw EditorRecoveryDraftStoreError.invalidIdentity
        }
        guard draft.baseRevision == EditorBodyRevision(body: draft.base),
              draft.externalRevision == EditorBodyRevision(body: draft.external) else {
            throw EditorRecoveryDraftStoreError.revisionMismatch
        }
    }
}

enum EditorRecoveryDraftStoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case vaultMismatch(expected: String, received: String)
    case invalidIdentity
    case revisionMismatch
    case identityReuse(expected: String, received: String)
}

private extension JSONEncoder {
    static var editorRecovery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var editorRecovery: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
