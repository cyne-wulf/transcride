import Foundation
import Testing

@Suite("Vault move operations (Quick Move contract)")
struct VaultOperationsMoveTests {
    private let entryName = "transcride-2026-07-01T10-00-00-field-notes"

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-move-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default

        let entry = root.appending(path: "Journal/\(entryName)")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write(
            "---\ntitle: \"Field Notes\"\ncreated: 2026-07-01T10:00:00+00:00\n---\nBody.\n",
            to: entry.appending(path: "Field Notes.md")
        )
        try AtomicFile.write(Data([0x01, 0x02, 0x03]), to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("{}", to: entry.appending(path: "waveform.json"))
        try fm.createDirectory(
            at: root.appending(path: "Projects/Nested/Deep"),
            withIntermediateDirectories: true
        )
        return root
    }

    @Test func moveIntoNestedFolderPreservesEveryFile() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let newPath = try ops.moveItem(
            at: "Journal/\(entryName)", toFolder: "Projects/Nested/Deep"
        )
        #expect(newPath == "Projects/Nested/Deep/\(entryName)")

        let dest = root.appendingRelativePath(newPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        #expect(names == ["Field Notes.md", "audio.m4a", "waveform.json"])
        let body = try String(
            contentsOf: dest.appending(path: "Field Notes.md"), encoding: .utf8
        )
        #expect(body.contains("Field Notes"))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "Journal/\(entryName)").path
        ))
    }

    @Test func moveToVaultRootUsesEmptyRelativePath() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let newPath = try ops.moveItem(at: "Journal/\(entryName)", toFolder: "")
        #expect(newPath == entryName)
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: entryName).path
        ))
    }

    @Test func moveToSameFolderIsANoOp() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        let newPath = try ops.moveItem(at: "Journal/\(entryName)", toFolder: "Journal")
        #expect(newPath == "Journal/\(entryName)")
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "Journal/\(entryName)").path
        ))
    }

    @Test func moveToMissingDestinationThrowsAndLeavesSourceIntact() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)

        #expect(throws: (any Error).self) {
            try ops.moveItem(at: "Journal/\(entryName)", toFolder: "Vanished")
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "Journal/\(entryName)").path
        ))
    }

    @Test func moveCollisionThrowsAlreadyExistsAndNeverOverwrites() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // A same-named entry already sits in the destination with content that
        // must survive.
        let occupied = root.appending(path: "Projects/\(entryName)")
        try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
        try AtomicFile.write("keep me", to: occupied.appending(path: "existing.md"))

        let ops = VaultOperations(vaultRoot: root)
        #expect(throws: VaultError.alreadyExists(entryName)) {
            try ops.moveItem(at: "Journal/\(entryName)", toFolder: "Projects")
        }
        // Neither side was touched.
        #expect(try String(
            contentsOf: occupied.appending(path: "existing.md"), encoding: .utf8
        ) == "keep me")
        #expect(fm.fileExists(
            atPath: root.appending(path: "Journal/\(entryName)/audio.m4a").path
        ))
    }

    @Test func moveMissingSourceThrowsNotFound() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = VaultOperations(vaultRoot: root)
        #expect(throws: VaultError.notFound("Journal/absent")) {
            try ops.moveItem(at: "Journal/absent", toFolder: "Projects")
        }
    }
}
