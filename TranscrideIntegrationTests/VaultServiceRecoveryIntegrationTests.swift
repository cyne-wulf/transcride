import Foundation
import Testing
@testable import Transcride

/// Crash-recovery records store the entry path they were written at. Renaming
/// or moving the entry afterwards — including an ordinary in-app rename, which
/// rewrites the folder slug — must not strand work that already happened (R7).
@Suite("Vault service recovery after a rename", .serialized)
struct VaultServiceRecoveryIntegrationTests {
    private static let originalName = "transcride-2026-07-01T10-00-00-field-notes"
    private static let renamedName = "transcride-2026-07-01T10-00-00-field-notes-v2"

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entry = root.appending(path: "Journal/\(Self.originalName)")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Field Notes\"\ncreated: 2026-07-01T10:00:00+00:00\n---\nBody.\n",
            to: entry.appending(path: "Field Notes.md")
        )
        try AtomicFile.write(Data([0x01, 0x02, 0x03]), to: entry.appending(path: "audio.m4a"))
        return root
    }

    /// Writes an interrupted replacement session into the entry at `entryPath`.
    @discardableResult
    private func writeSession(
        inVault root: URL, entryPath: RelativePath
    ) throws -> ReplacementTakeSession {
        let session = ReplacementTakeSession(
            entryRelativePath: entryPath,
            sourceAudioFileName: "audio.m4a",
            timelineDuration: 30,
            region: ReplacementRegion(
                selection: AudioRangeSelection(start: 5, end: 10),
                timelineDuration: 30,
                sampleRate: 48_000
            )
        )
        let directory = root.appendingRelativePath(entryPath).appending(
            path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            encoder.encode(session),
            to: directory.appending(path: AudioReplacementArtifacts.sessionFileName)
        )
        return session
    }

    private func readSession(inVault root: URL, entryPath: RelativePath) throws -> ReplacementTakeSession {
        let url = root.appendingRelativePath(entryPath)
            .appending(path: AudioReplacementArtifacts.sessionDirectoryName, directoryHint: .isDirectory)
            .appending(path: AudioReplacementArtifacts.sessionFileName)
        return try JSONDecoder().decode(ReplacementTakeSession.self, from: Data(contentsOf: url))
    }

    @Test func replacementSessionSurvivesAnEntryRename() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let original: RelativePath = "Journal/\(Self.originalName)"
        let renamed: RelativePath = "Journal/\(Self.renamedName)"
        try writeSession(inVault: root, entryPath: original)
        // The user renames the entry (or moves it in Finder) before relaunch.
        try FileManager.default.moveItem(
            at: root.appendingRelativePath(original), to: root.appendingRelativePath(renamed)
        )

        let service = VaultService(rootURL: root)
        let discovery = await service.replacementTakeSessions()

        #expect(discovery.recoverable.count == 1)
        #expect(discovery.recoverable.first?.entryRelativePath == renamed)
        // The correction is persisted, so later steps address the right entry.
        #expect(try readSession(inVault: root, entryPath: renamed).entryRelativePath == renamed)
    }

    @Test func replacementSessionWithAMatchingPathIsUnaffected() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryPath: RelativePath = "Journal/\(Self.originalName)"
        let written = try writeSession(inVault: root, entryPath: entryPath)

        let service = VaultService(rootURL: root)
        let discovery = await service.replacementTakeSessions()

        #expect(discovery.recoverable.count == 1)
        #expect(discovery.recoverable.first?.entryRelativePath == entryPath)
        #expect(discovery.recoverable.first?.id == written.id)
    }

    /// The staging contract from the same wave: a completed recovery entry
    /// appears in one step, with nothing left behind under `.staging`.
    @Test func stagingIsEmptyAfterVaultServiceStartsUp() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try EntryStaging(vaultRoot: root)
        try Data([0x00]).write(to: staging.url.appending(path: "audio.m4a"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: staging.url.path
        )

        let service = VaultService(rootURL: root)
        _ = await service.recoverInterruptedRecordings()

        #expect(try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: EntryStaging.directoryName).path
        ).isEmpty)
        // And it never looked like an entry in the first place.
        let entries = await service.snapshot().allEntries
        #expect(entries.count == 1)
    }
}
