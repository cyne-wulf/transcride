import Foundation
import Testing
@testable import Transcride

@Suite("Transcript compare-and-save integration", .serialized)
struct TranscriptCompareSaveIntegrationTests {
    @Test func successPreservesFrontmatterAndExactNewlinesAndForksOnlyOnChange() async throws {
        let fixture = try Fixture(newline: "\r\n", body: "one\r\ntwo\r\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        let initialRevision = EditorBodyRevision(body: "one\r\ntwo\r\n")

        let unchanged = try await service.compareAndSaveTranscriptBody(
            "one\r\ntwo\r\n",
            expectedRevision: initialRevision,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let unchangedDocument, _) = unchanged else {
            Issue.record("Expected unchanged save")
            return
        }
        #expect(!unchangedDocument.handEdited)

        let changed = try await service.compareAndSaveTranscriptBody(
            "ONE\r\ntwo\r\n",
            expectedRevision: initialRevision,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let saved, let revision) = changed else {
            Issue.record("Expected changed save")
            return
        }
        #expect(saved.handEdited)
        #expect(saved.value(for: "unknown") == "keep-me")
        #expect(saved.frontmatterNewline == "\r\n")
        #expect(saved.body == "ONE\r\ntwo\r\n")
        #expect(revision == EditorBodyRevision(body: saved.body))
        let bytes = try String(contentsOf: fixture.transcriptURL, encoding: .utf8)
        #expect(bytes.contains("unknown: keep-me\r\n"))
        #expect(bytes.hasSuffix("ONE\r\ntwo\r\n"))
        #expect(try temporaryArtifacts(nextTo: fixture.transcriptURL).isEmpty)
    }

    @Test func staleRevisionAndPrecommitFrontmatterRaceNeverOverwriteDisk() async throws {
        let fixture = try Fixture(newline: "\n", body: "base\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)

        let stale = try await service.compareAndSaveTranscriptBody(
            "mine\n",
            expectedRevision: EditorBodyRevision(body: "not-base\n"),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let external, _) = stale else {
            Issue.record("Expected stale revision conflict")
            return
        }
        #expect(external.body == "base\n")

        await service.setCompareSavePrecommitHookForTesting { url in
            try AtomicFile.write(
                "---\nunknown: externally-updated\n---\nbase\n",
                to: url
            )
        }
        let raced = try await service.compareAndSaveTranscriptBody(
            "mine\n",
            expectedRevision: EditorBodyRevision(body: "base\n"),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let racedExternal, _) = raced else {
            Issue.record("Expected full-file precommit conflict")
            return
        }
        #expect(racedExternal.value(for: "unknown") == "externally-updated")
        #expect(racedExternal.body == "base\n")
        #expect(try String(contentsOf: fixture.transcriptURL, encoding: .utf8)
            == "---\nunknown: externally-updated\n---\nbase\n")
        #expect(try temporaryArtifacts(nextTo: fixture.transcriptURL).isEmpty)
    }

    @Test func missingTranscriptFailsWithoutCreatingAnyFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcride-compare-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = VaultService(rootURL: root)
        await #expect(throws: VaultError.self) {
            try await service.compareAndSaveTranscriptBody(
                "mine",
                expectedRevision: EditorBodyRevision(body: ""),
                markHandEdited: true,
                atEntryPath: "missing"
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingRelativePath("missing").path
        ))
    }

    @Test func twoSuccessiveExternalRevisionsMergeAndRetryWithoutBlindOverwrite() async throws {
        let base = "one\ntwo\nthree\nfour\n"
        let fixture = try Fixture(newline: "\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        var mergeBase = base
        var candidate = "ONE\ntwo\nthree\nfour\n"
        var expected = EditorBodyRevision(body: base)

        await service.setCompareSavePrecommitHookForTesting { url in
            try AtomicFile.write(
                "---\nunknown: keep-me\n---\none\ntwo\nTHREE\nfour\n",
                to: url
            )
        }
        let first = try await service.compareAndSaveTranscriptBody(
            candidate,
            expectedRevision: expected,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let firstExternal, let firstRevision) = first,
              case .merged(let firstMerge) = EditorBodyMerger.merge(
                base: mergeBase,
                mine: candidate,
                external: firstExternal.body
              ) else {
            Issue.record("Expected first non-overlap retry")
            return
        }
        mergeBase = firstExternal.body
        candidate = firstMerge.body
        expected = firstRevision

        await service.setCompareSavePrecommitHookForTesting { url in
            try AtomicFile.write(
                "---\nunknown: second-external\n---\none\ntwo\nTHREE\nFOUR\n",
                to: url
            )
        }
        let second = try await service.compareAndSaveTranscriptBody(
            candidate,
            expectedRevision: expected,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let secondExternal, let secondRevision) = second,
              case .merged(let secondMerge) = EditorBodyMerger.merge(
                base: mergeBase,
                mine: candidate,
                external: secondExternal.body
              ) else {
            Issue.record("Expected second non-overlap retry")
            return
        }

        let saved = try await service.compareAndSaveTranscriptBody(
            secondMerge.body,
            expectedRevision: secondRevision,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let document, _) = saved else {
            Issue.record("Expected exact third-attempt save")
            return
        }
        #expect(document.body == "ONE\ntwo\nTHREE\nFOUR\n")
        #expect(document.value(for: "unknown") == "second-external")
        #expect(document.handEdited)
        #expect(try temporaryArtifacts(nextTo: fixture.transcriptURL).isEmpty)
    }

    @Test func resolvedOverlapReentersCleanMergeWhenDiskChangesAgain() async throws {
        let base = "before\nshared\nafter\nlast\n"
        let fixture = try Fixture(newline: "\r", body: base.replacingOccurrences(of: "\n", with: "\r"))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        let exactBase = "before\rshared\rafter\rlast\r"
        let mine = "before\rmine\rafter\rlast\r"
        let firstExternal = "before\rexternal\rafter\rlast\r"
        try AtomicFile.write(
            "---\runknown: keep-me\r---\r\(firstExternal)",
            to: fixture.transcriptURL
        )

        guard case .conflict(let conflict) = EditorBodyMerger.merge(
            base: exactBase,
            mine: mine,
            external: firstExternal
        ), let hunk = conflict.hunks.first,
              let resolved = conflict.resolvedBody(choices: [hunk.id: .mine]) else {
            Issue.record("Expected an overlap requiring a Mine choice")
            return
        }
        let laterExternal = "before\rexternal\rafter\rLAST\r"
        try AtomicFile.write(
            "---\runknown: later\r---\r\(laterExternal)",
            to: fixture.transcriptURL
        )
        let attempted = try await service.compareAndSaveTranscriptBody(
            resolved,
            expectedRevision: EditorBodyRevision(body: firstExternal),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let current, let currentRevision) = attempted,
              case .merged(let clean) = EditorBodyMerger.merge(
                base: firstExternal,
                mine: resolved,
                external: current.body
              ) else {
            Issue.record("Expected resolved choice to cleanly merge with later disk change")
            return
        }
        let final = try await service.compareAndSaveTranscriptBody(
            clean.body,
            expectedRevision: currentRevision,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let document, _) = final else {
            Issue.record("Expected resolved retry to save")
            return
        }
        #expect(document.body == "before\rmine\rafter\rLAST\r")
        #expect(document.value(for: "unknown") == "later")
    }

    @Test func pendingDebounceFrontmatterOnlyReloadPromotesExactLocalBody() async throws {
        let base = "one\r\ntwo\r\n"
        let local = "ONE\r\ntwo\r\n"
        let fixture = try Fixture(newline: "\r\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        try AtomicFile.write(
            "---\r\nunknown: external-frontmatter\r\n---\r\n\(base)",
            to: fixture.transcriptURL
        )

        let result = try await service.compareAndSaveTranscriptBody(
            local,
            expectedRevision: EditorBodyRevision(body: base),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let saved, _) = result else {
            Issue.record("Pending local body should save across a frontmatter-only reload")
            return
        }
        #expect(saved.body == local)
        #expect(saved.value(for: "unknown") == "external-frontmatter")
    }

    @Test func pendingDebounceDisjointReloadMergesBeforeDiskAdmission() async throws {
        let base = "one\ntwo\nthree\n"
        let local = "ONE\ntwo\nthree\n"
        let external = "one\ntwo\nTHREE\n"
        let fixture = try Fixture(newline: "\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        try AtomicFile.write(
            "---\nunknown: external\n---\n\(external)",
            to: fixture.transcriptURL
        )

        let first = try await service.compareAndSaveTranscriptBody(
            local,
            expectedRevision: EditorBodyRevision(body: base),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let disk, let revision) = first,
              case .merged(let merged) = EditorBodyMerger.merge(
                base: base,
                mine: local,
                external: disk.body
              ) else {
            Issue.record("Expected a disjoint pending-buffer merge")
            return
        }
        let retry = try await service.compareAndSaveTranscriptBody(
            merged.body,
            expectedRevision: revision,
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .saved(let saved, _) = retry else {
            Issue.record("Expected merged pending buffer to save before reload")
            return
        }
        #expect(saved.body == "ONE\ntwo\nTHREE\n")
        #expect(saved.value(for: "unknown") == "external")
    }

    @Test func pendingDebounceOverlapBlocksReloadWithoutOverwritingExternal() async throws {
        let base = "before\nshared\nafter\n"
        let local = "before\nlocal\nafter\n"
        let external = "before\nexternal\nafter\n"
        let fixture = try Fixture(newline: "\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        try AtomicFile.write(
            "---\nunknown: external\n---\n\(external)",
            to: fixture.transcriptURL
        )

        let attempt = try await service.compareAndSaveTranscriptBody(
            local,
            expectedRevision: EditorBodyRevision(body: base),
            markHandEdited: true,
            atEntryPath: fixture.entryPath
        )
        guard case .conflict(let disk, _) = attempt,
              case .conflict = EditorBodyMerger.merge(
                base: base,
                mine: local,
                external: disk.body
              ) else {
            Issue.record("Expected overlap to block watcher reload")
            return
        }
        #expect(FrontmatterDocument.parse(
            try String(contentsOf: fixture.transcriptURL, encoding: .utf8)
        ).body == external)
    }

    @MainActor
    @Test func delayedOlderSaveRebasesNewGenerationBeforeAdvancingBaseline() async throws {
        let base = "top\nmiddle\nbottom\n"
        let generationOne = "TOP\nmiddle\nbottom\n"
        let generationTwo = "TOP\nmiddle\nBOTTOM LOCAL\n"
        let external = "top\nMIDDLE EXTERNAL\nbottom\n"
        let expectedFinal = "TOP\nMIDDLE EXTERNAL\nBOTTOM LOCAL\n"
        let fixture = try Fixture(newline: "\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        let scheduler = EditorSaveScheduler()
        let identity = EditorDocumentIdentity(
            vaultID: "vault", documentID: "stable", path: fixture.entryPath,
            generation: 1
        )
        let hookGate = CompareHookGate()
        await service.setCompareSavePrecommitHookForTesting { url in
            try AtomicFile.write(
                "---\nunknown: external\n---\n\(external)",
                to: url
            )
            hookGate.enterAndWait()
        }

        var liveBody = generationOne
        var diskBody = base
        var diskRevision = EditorBodyRevision(body: base)
        let first = Task { @MainActor in
            await scheduler.enqueue(.init(
                identity: identity,
                generation: 1,
                body: generationOne,
                source: .autosave
            )) { ticket in
                var candidate = ticket.body
                var mergeBase = diskBody
                var expectedRevision = diskRevision
                for _ in 0..<3 {
                    guard let result = try? await service.compareAndSaveTranscriptBody(
                        candidate,
                        expectedRevision: expectedRevision,
                        markHandEdited: true,
                        atEntryPath: fixture.entryPath
                    ) else { return false }
                    switch result {
                    case .conflict(let disk, let revision):
                        guard case .merged(let merged) = EditorBodyMerger.merge(
                            base: mergeBase,
                            mine: candidate,
                            external: disk.body
                        ) else { return false }
                        mergeBase = disk.body
                        candidate = merged.body
                        expectedRevision = revision
                    case .saved(let saved, let revision):
                        diskBody = saved.body
                        diskRevision = revision
                        if liveBody != ticket.body,
                           case .merged(let rebased) = EditorSaveLineage.rebaseNewerBody(
                            savedInput: ticket.body,
                            newerBody: liveBody,
                            savedDiskBody: saved.body
                           ) {
                            liveBody = rebased.body
                        }
                        return true
                    }
                }
                return false
            }
        }
        await hookGate.waitUntilEntered()
        liveBody = generationTwo
        let second = Task { @MainActor in
            await scheduler.enqueue(.init(
                identity: identity,
                generation: 2,
                body: generationTwo,
                source: .autosave
            )) { _ in
                guard case .saved(let saved, let revision) = try? await service
                    .compareAndSaveTranscriptBody(
                        liveBody,
                        expectedRevision: diskRevision,
                        markHandEdited: true,
                        atEntryPath: fixture.entryPath
                    ) else { return false }
                diskBody = saved.body
                diskRevision = revision
                return true
            }
        }
        hookGate.release()
        #expect(await first.value)
        #expect(await second.value)
        #expect(liveBody == expectedFinal)
        #expect(diskBody == expectedFinal)
        #expect(FrontmatterDocument.parse(
            try String(contentsOf: fixture.transcriptURL, encoding: .utf8)
        ).body == expectedFinal)
    }

    @MainActor
    @Test func externalReloadAdmissionPersistsGenerationTypedDuringTransitionRetry() async throws {
        let base = "top\nmiddle\nbottom\n"
        let generationOne = "TOP\nmiddle\nbottom\n"
        let generationTwo = "TOP\nmiddle\nBOTTOM LOCAL\n"
        let external = "top\nMIDDLE EXTERNAL\nbottom\n"
        let expectedFinal = "TOP\nMIDDLE EXTERNAL\nBOTTOM LOCAL\n"
        let fixture = try Fixture(newline: "\n", body: base)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = VaultService(rootURL: fixture.root)
        let identity = EditorDocumentIdentity(
            vaultID: "vault",
            documentID: "stable",
            path: fixture.entryPath,
            generation: 1
        )
        let hookGate = CompareHookGate()
        await service.setCompareSavePrecommitHookForTesting { url in
            try AtomicFile.write(
                "---\nunknown: external\n---\n\(external)",
                to: url
            )
            hookGate.enterAndWait()
        }

        var live = EditorExternalReloadAdmissionState(
            identity: identity,
            generation: 1,
            body: generationOne,
            baselineBody: base,
            needsSave: true
        )
        var admittedDiskBodies: [String] = []
        let admission = Task { @MainActor in
            await EditorExternalReloadAdmission.saveLatest(
                currentState: { live },
                save: { requested in
                    var mergeBase = requested.baselineBody
                    var candidate = requested.body
                    var expectedRevision = EditorBodyRevision(body: mergeBase)
                    for _ in 0..<4 {
                        guard let result = try? await service.compareAndSaveTranscriptBody(
                            candidate,
                            expectedRevision: expectedRevision,
                            markHandEdited: true,
                            atEntryPath: fixture.entryPath
                        ) else { return false }
                        switch result {
                        case .conflict(let disk, let revision):
                            guard case .merged(let merged) = EditorBodyMerger.merge(
                                base: mergeBase,
                                mine: candidate,
                                external: disk.body
                            ) else { return false }
                            mergeBase = disk.body
                            candidate = merged.body
                            expectedRevision = revision
                        case .saved(let saved, _):
                            admittedDiskBodies.append(saved.body)
                            if live.generation == requested.generation,
                               live.body == requested.body {
                                live.body = saved.body
                                live.baselineBody = saved.body
                                live.needsSave = false
                            } else {
                                guard case .merged(let rebased) = EditorSaveLineage
                                    .rebaseNewerBody(
                                        savedInput: requested.body,
                                        newerBody: live.body,
                                        savedDiskBody: saved.body
                                    ) else { return false }
                                live.body = rebased.body
                                live.baselineBody = saved.body
                                live.needsSave = true
                            }
                            return true
                        }
                    }
                    return false
                }
            )
        }

        await hookGate.waitUntilEntered()
        live.generation = 2
        live.body = generationTwo
        live.needsSave = true
        hookGate.release()

        #expect(await admission.value)
        #expect(admittedDiskBodies.count == 2)
        #expect(admittedDiskBodies.first != expectedFinal)
        #expect(admittedDiskBodies.last == expectedFinal)
        #expect(live.body == expectedFinal)
        #expect(live.baselineBody == expectedFinal)
        #expect(live.isDurablyCurrent)
        #expect(FrontmatterDocument.parse(
            try String(contentsOf: fixture.transcriptURL, encoding: .utf8)
        ).body == expectedFinal)
    }

    private func temporaryArtifacts(nextTo url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".\(url.lastPathComponent).tmp-") }
    }

    private struct Fixture {
        var root: URL
        var entryPath: RelativePath
        var transcriptURL: URL

        init(newline: String, body: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcride-compare-save-\(UUID().uuidString)")
            entryPath = "transcride-2026-07-20T06-00-00-test"
            let entryURL = root.appendingRelativePath(entryPath)
            transcriptURL = entryURL.appendingPathComponent("transcript.md")
            try FileManager.default.createDirectory(
                at: entryURL,
                withIntermediateDirectories: true
            )
            try AtomicFile.write(
                "---\(newline)unknown: keep-me\(newline)---\(newline)\(body)",
                to: transcriptURL
            )
        }
    }
}

private final class CompareHookGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() async {
        while !isEntered() { await Task.yield() }
    }

    private func isEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
