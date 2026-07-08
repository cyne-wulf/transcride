import Foundation
import Testing

@Suite("Import format detection")
struct AudioImportFormatTests {
    @Test func detectsSupportedExtensionsCaseInsensitively() {
        for name in [
            "a.m4a", "b.AAC", "c.mp3", "d.WAV", "e.flac", "f.ogg", "g.opus",
            "h.aiff", "i.aif", "movie.MP4", "clip.mov",
        ] {
            #expect(AudioImportFormat.isSupported(fileName: name), "\(name) should be supported")
        }
        for name in ["notes.txt", "noextension", "archive.zip", "a.md", "x.caf"] {
            #expect(!AudioImportFormat.isSupported(fileName: name), "\(name) should be rejected")
        }
        #expect(AudioImportFormat.isVideo(fileName: "clip.MOV"))
        #expect(!AudioImportFormat.isVideo(fileName: "a.mp3"))
    }

    @Test func sanitizesImportedFileNames() {
        #expect(AudioImportFormat.importedFileName(forSourceName: "Standup 3.mp3") == "Standup 3.mp3")
        #expect(AudioImportFormat.importedFileName(forSourceName: ".hidden.mp3") == "hidden.mp3")
        #expect(AudioImportFormat.importedFileName(forSourceName: "a/b:c.wav") == "a-b-c.wav")
    }

    @Test func titleComesFromSourceFileName() {
        #expect(AudioImportFormat.title(forSourceName: "Standup 3.mp3") == "Standup 3")
        #expect(AudioImportFormat.title(forSourceName: "archive.tar.mp3") == "archive.tar")
    }

    @Test func probeAcceptsRealAudio() async throws {
        let url = try TestAudio.makeWAV(seconds: 1.0, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let duration = try await AudioImportFormat.probeDuration(of: url)
        #expect(abs(duration - 1.0) < 0.05)
    }

    @Test func probeRejectsGarbageAndUnsupported() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A text file wearing an audio extension must fail per-file, not crash.
        let fake = dir.appending(path: "fake.mp3")
        try AtomicFile.write("definitely not an mp3", to: fake)
        await #expect(throws: (any Error).self) {
            _ = try await AudioImportFormat.probeDuration(of: fake)
        }

        let unsupported = dir.appending(path: "notes.txt")
        try AtomicFile.write("text", to: unsupported)
        await #expect(throws: (any Error).self) {
            _ = try await AudioImportFormat.probeDuration(of: unsupported)
        }
    }
}
