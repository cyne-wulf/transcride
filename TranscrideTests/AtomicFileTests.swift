import Foundation
import Testing

@Suite("Atomic file writes")
struct AtomicFileTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcride-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesNewFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        try AtomicFile.write("hello world", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
    }

    @Test func overwritesExistingFileAtomically() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        try AtomicFile.write("version 1", to: target)
        try AtomicFile.write("version 2 — much longer content than before", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "version 2 — much longer content than before")
    }

    @Test func leavesNoTempFilesBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "note.md")
        for i in 0..<10 {
            try AtomicFile.write("content \(i)", to: target)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["note.md"])
    }

    @Test func failsCleanlyWhenDirectoryMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "missing-subdir/note.md")
        #expect(throws: (any Error).self) {
            try AtomicFile.write("data", to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func binaryDataRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "blob.bin")
        let data = Data((0..<255).map { UInt8($0) })
        try AtomicFile.write(data, to: target)
        #expect(try Data(contentsOf: target) == data)
    }
}
