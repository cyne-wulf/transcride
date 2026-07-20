import Foundation
import Testing

@Suite("Editor three-way merge")
struct EditorMergeTests {
    @Test func returnsMineWhenBodiesAlreadyAgree() {
        let result = EditorBodyMerger.merge(base: "a\n", mine: "same\n", external: "same\n")
        guard case .merged(let merged) = result else {
            Issue.record("Expected clean merge")
            return
        }
        #expect(merged.body == "same\n")
    }

    @Test func deterministicallyMergesNonoverlappingLineChanges() {
        let base = "one\ntwo\nthree\nfour\n"
        let mine = "ONE\ntwo\nthree\nfour\n"
        let external = "one\ntwo\nthree\nFOUR\n"
        let result = EditorBodyMerger.merge(base: base, mine: mine, external: external)
        guard case .merged(let merged) = result else {
            Issue.record("Expected non-overlapping merge")
            return
        }
        #expect(merged.body == "ONE\ntwo\nthree\nFOUR\n")
        #expect(merged.mineChanges.count == 1)
        #expect(merged.externalChanges.count == 1)
    }

    @Test func identicalOverlappingChangeIsAppliedOnce() {
        let result = EditorBodyMerger.merge(
            base: "one\ntwo\n",
            mine: "one\nTWO\n",
            external: "one\nTWO\n"
        )
        guard case .merged(let merged) = result else {
            Issue.record("Expected identical edit to merge")
            return
        }
        #expect(merged.body == "one\nTWO\n")
    }

    @Test func reportsOverlappingChangeAsPerHunkConflict() throws {
        let result = EditorBodyMerger.merge(
            base: "before\nshared\nafter\n",
            mine: "before\nmine\nafter\n",
            external: "before\nexternal\nafter\n"
        )
        guard case .conflict(let conflict) = result else {
            Issue.record("Expected overlap conflict")
            return
        }
        let hunk = try #require(conflict.hunks.first)
        #expect(conflict.hunks.count == 1)
        #expect(hunk.base == "shared\n")
        #expect(hunk.mine == "mine\n")
        #expect(hunk.external == "external\n")

        #expect(conflict.resolvedBody(choices: [:]) == nil)
        #expect(conflict.resolvedBody(choices: [hunk.id: .mine]) == "before\nmine\nafter\n")
        #expect(conflict.resolvedBody(choices: [hunk.id: .external]) == "before\nexternal\nafter\n")
        #expect(conflict.resolvedBody(choices: [hunk.id: .keepBoth]) ==
            "before\nmine\nexternal\nafter\n")
    }

    @Test func keepBothAddsOnlyMinimumNewlineAndNeverMarkers() {
        #expect(EditorBodyMerger.keepBoth(mine: "mine", external: "external") == "mine\nexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "mine\n", external: "external") == "mine\nexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "mine", external: "\nexternal") == "mine\nexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "", external: "external") == "external")
        #expect(!EditorBodyMerger.keepBoth(mine: "mine", external: "external").contains("<<<<<<<"))
    }

    @Test func keepBothPreservesCRCRLFAndMixedSeamConventions() {
        #expect(EditorBodyMerger.keepBoth(mine: "a\r\nmine", external: "external")
            == "a\r\nmine\r\nexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "a\rmine", external: "external")
            == "a\rmine\rexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "mine\r", external: "external")
            == "mine\rexternal")
        #expect(EditorBodyMerger.keepBoth(mine: "mine", external: "\r\nexternal")
            == "mine\r\nexternal")
        #expect(EditorBodyMerger.keepBoth(
            mine: "first\nsecond\r\nthird",
            external: "outside\rfourth"
        ) == "first\nsecond\r\nthird\r\noutside\rfourth")
    }

    @Test func insertionAtSamePositionConflictsButDifferentPositionsMerge() {
        let samePosition = EditorBodyMerger.merge(
            base: "one\ntwo\n",
            mine: "one\nmine\ntwo\n",
            external: "one\nexternal\ntwo\n"
        )
        guard case .conflict = samePosition else {
            Issue.record("Expected same-position insert conflict")
            return
        }

        let differentPositions = EditorBodyMerger.merge(
            base: "one\ntwo\nthree\n",
            mine: "mine\none\ntwo\nthree\n",
            external: "one\ntwo\nthree\nexternal\n"
        )
        guard case .merged(let merged) = differentPositions else {
            Issue.record("Expected separated inserts to merge")
            return
        }
        #expect(merged.body == "mine\none\ntwo\nthree\nexternal\n")
    }

    @Test func lineTokenizerPreservesExactNewlineBytes() {
        #expect(EditorBodyMerger.lines(in: "") == [])
        #expect(EditorBodyMerger.lines(in: "a") == ["a"])
        #expect(EditorBodyMerger.lines(in: "a\n") == ["a\n"])
        #expect(EditorBodyMerger.lines(in: "a\n\n") == ["a\n", "\n"])
        #expect(EditorBodyMerger.lines(in: "a\r\nb") == ["a\r\n", "b"])
    }

    @Test func recoveryDraftRoundTripsAndSurvivesCancelOrFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorRecoveryDraftStore(rootDirectoryURL: directory, vaultID: "vault-a")
        let draft = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "entry-1",
            entryPath: "Journal/entry-1",
            base: "base",
            mine: "mine",
            external: "external",
            timestamp: Date(timeIntervalSince1970: 123)
        )

        try store.persist(draft)
        #expect(try store.load(id: draft.id) == draft)
        #expect(try store.allDrafts() == [draft])
        #expect(try !store.deleteAfterResolution(id: draft.id, durablySaved: false))
        #expect(try store.load(id: draft.id) == draft)
        #expect(try store.deleteAfterResolution(id: draft.id, durablySaved: true))
        #expect(try store.load(id: draft.id) == nil)
    }

    @Test func recoveryDraftRecordsExactRevisionsAndCodableSchema() throws {
        let draft = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "id",
            entryPath: "path",
            base: "base\n",
            mine: "mine\n",
            external: "external\n"
        )
        #expect(draft.schemaVersion == 2)
        #expect(draft.baseRevision == EditorBodyRevision(body: "base\n"))
        #expect(draft.externalRevision == EditorBodyRevision(body: "external\n"))
        let decoded = try JSONDecoder().decode(
            EditorRecoveryDraft.self,
            from: JSONEncoder().encode(draft)
        )
        #expect(decoded == draft)
    }

    @Test func recoveryDraftsAreNamespacedAndRejectedAcrossVaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("First Vault")
        let secondRoot = directory.appendingPathComponent("Second Vault")
        let firstID = EditorVaultIdentity.identifier(forRootURL: firstRoot)
        let secondID = EditorVaultIdentity.identifier(forRootURL: secondRoot)
        #expect(firstID != secondID)

        let firstStore = EditorRecoveryDraftStore(
            rootDirectoryURL: directory.appendingPathComponent("Recovery"),
            vaultID: firstID
        )
        let secondStore = EditorRecoveryDraftStore(
            rootDirectoryURL: directory.appendingPathComponent("Recovery"),
            vaultID: secondID
        )
        let firstDraft = EditorRecoveryDraft(
            vaultID: firstID,
            entryID: "shared-entry",
            entryPath: "Journal/shared-entry",
            base: "base",
            mine: "first vault mine",
            external: "external"
        )
        try firstStore.persist(firstDraft)

        #expect(try secondStore.allDrafts().isEmpty)
        #expect(try secondStore.load(id: firstDraft.id) == nil)
        #expect(throws: EditorRecoveryDraftStoreError.vaultMismatch(
            expected: secondID,
            received: firstID
        )) {
            try secondStore.persist(firstDraft)
        }
    }

    @Test func corruptRecoveryRecordDoesNotHideValidDraft() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorRecoveryDraftStore(rootDirectoryURL: directory, vaultID: "vault-a")
        let valid = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "stable-entry",
            entryPath: "Journal/entry",
            base: "base",
            mine: "mine",
            external: "external"
        )
        try store.persist(valid)
        try Data("{ definitely-not-json".utf8).write(
            to: store.directoryURL.appendingPathComponent("corrupt.json")
        )

        let scan = store.scanDrafts()
        #expect(scan.drafts.map(\.id) == [valid.id])
        #expect(scan.failures.count == 1)
        #expect(scan.failures.first?.fileName == "corrupt.json")
        #expect(try store.allDrafts().map(\.id) == [valid.id])
    }

    @Test func recoveryStoreRejectsRevisionMismatchAndUUIDIdentityReuse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorRecoveryDraftStore(rootDirectoryURL: directory, vaultID: "vault-a")
        let id = UUID()
        let valid = EditorRecoveryDraft(
            id: id,
            vaultID: "vault-a",
            entryID: "stable-a",
            entryPath: "A/entry",
            base: "base",
            mine: "mine",
            external: "external"
        )
        try store.persist(valid)

        let reused = EditorRecoveryDraft(
            id: id,
            vaultID: "vault-a",
            entryID: "stable-b",
            entryPath: "B/entry",
            base: "base",
            mine: "mine",
            external: "external"
        )
        #expect(throws: EditorRecoveryDraftStoreError.identityReuse(
            expected: "stable-a",
            received: "stable-b"
        )) {
            try store.persist(reused)
        }

        var mismatched = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "stable-a",
            entryPath: "A/entry",
            base: "base",
            mine: "mine",
            external: "external"
        )
        mismatched.baseRevision = EditorBodyRevision(body: "different")
        #expect(throws: EditorRecoveryDraftStoreError.revisionMismatch) {
            try store.persist(mismatched)
        }
    }

    @Test func newerRecoveryDraftSupersedesPredecessorForSameDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorRecoveryDraftStore(rootDirectoryURL: directory, vaultID: "vault-a")
        let older = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "stable-a",
            entryPath: "old/path",
            base: "base",
            mine: "older",
            external: "external",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let newer = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "stable-a",
            entryPath: "new/path",
            base: "base",
            mine: "newer",
            external: "external",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        try store.persist(older)
        try store.persist(newer)

        #expect(try store.load(id: older.id) == nil)
        #expect(try store.allDrafts() == [newer])
    }

    @Test func inaccessibleRecoveryDirectoryReportsFailureWithoutInventingDrafts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-editor-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.write("not-a-directory", to: root)
        let store = EditorRecoveryDraftStore(rootDirectoryURL: root, vaultID: "vault-a")
        let draft = EditorRecoveryDraft(
            vaultID: "vault-a",
            entryID: "stable-a",
            entryPath: "path",
            base: "base",
            mine: "mine",
            external: "external"
        )
        #expect(throws: (any Error).self) { try store.persist(draft) }
        #expect(store.scanDrafts().drafts.isEmpty)
    }
}
