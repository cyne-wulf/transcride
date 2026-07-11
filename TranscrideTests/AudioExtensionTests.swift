import Foundation
import Testing

@Suite("Audio extension safe swap (EXT-5)")
struct AudioExtensionTests {
    private func makeVault() throws -> (root: URL, entryPath: RelativePath, entryURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = "transcride-2026-07-11T12-00-00-test"
        let entry = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try AtomicFile.write("old", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write(
            "---\ntitle: Test\nduration: 10.00\ncustom_field: keep-me\n---\nEdited body.\n",
            to: entry.appending(path: "Test.md")
        )
        try WaveformData(duration: 10, peaks: [0.1, 0.2])
            .write(to: WaveformData.url(inEntry: entry))
        return (root, path, entry)
    }

    @Test func applyPreservesOldVersionAndUnknownFrontmatter() throws {
        let fixture = try makeVault()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.entryURL.appending(path: RecordingExtensionArtifacts.combinedFileName)
        try AtomicFile.write("combined", to: output)

        let outcome = try AudioExtensionApplier(vaultRoot: fixture.root).apply(
            combinedFileAt: output,
            fileName: "audio.m4a",
            combinedDuration: 12.5,
            previousTranscriptDuration: 10,
            normalizedToM4A: false,
            expectedSourceFileName: "audio.m4a",
            toEntryAt: fixture.entryPath
        )

        #expect(try String(contentsOf: fixture.entryURL.appending(path: "audio.m4a"), encoding: .utf8) == "combined")
        #expect(!FileManager.default.fileExists(atPath: WaveformData.url(inEntry: fixture.entryURL).path))
        let markdown = try String(contentsOf: fixture.entryURL.appending(path: "Test.md"), encoding: .utf8)
        #expect(markdown.contains("duration: 12.50"))
        #expect(markdown.contains("custom_field: keep-me"))
        #expect(markdown.contains("Edited body."))
        let extensionState = try #require(ExtensionTranscriptState.load(from: fixture.entryURL))
        #expect(extensionState.knownTranscriptDuration == 10)
        #expect(extensionState.combinedAudioDuration == 12.5)
        #expect(!extensionState.normalizedToM4A)

        let store = TrashStore(vaultRoot: fixture.root)
        let old = try #require(try store.items().first(where: { $0.trashedName == outcome.trashedName }))
        #expect(old.kind == .preExtensionAudio)
        #expect(old.displayName == "Pre-Extension Audio — Test")
    }

    @Test func restoreIsSymmetricAndKeepsBothVersions() throws {
        let fixture = try makeVault()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.entryURL.appending(path: RecordingExtensionArtifacts.combinedFileName)
        try AtomicFile.write("combined", to: output)
        let store = TrashStore(vaultRoot: fixture.root)
        _ = try AudioExtensionApplier(vaultRoot: fixture.root).apply(
            combinedFileAt: output, fileName: "audio.m4a", combinedDuration: 12.5,
            previousTranscriptDuration: 10, normalizedToM4A: false,
            expectedSourceFileName: "audio.m4a", toEntryAt: fixture.entryPath
        )

        let old = try #require(try store.items().first(where: { $0.kind == .preExtensionAudio }))
        _ = try store.restore(old)
        #expect(try String(contentsOf: fixture.entryURL.appending(path: "audio.m4a"), encoding: .utf8) == "old")
        let combined = try #require(try store.items().first(where: { $0.kind == .preExtensionAudio }))
        let staged = store.trashDirectory.appending(path: combined.trashedName).appending(path: "audio.m4a")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "combined")
    }

    @Test func sourceIdentityMismatchDoesNotTouchAudio() throws {
        let fixture = try makeVault()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.entryURL.appending(path: RecordingExtensionArtifacts.combinedFileName)
        try AtomicFile.write("combined", to: output)

        #expect(throws: RecordingExtensionError.self) {
            try AudioExtensionApplier(vaultRoot: fixture.root).apply(
                combinedFileAt: output, fileName: "audio.m4a", combinedDuration: 12,
                previousTranscriptDuration: 10, normalizedToM4A: false,
                expectedSourceFileName: "different.m4a", toEntryAt: fixture.entryPath
            )
        }
        #expect(try String(contentsOf: fixture.entryURL.appending(path: "audio.m4a"), encoding: .utf8) == "old")
    }

    @Test func composerAppendsTwoReadableFiles() async throws {
        let source = try TestAudio.makeWAV(seconds: 1.0, amplitude: 0.2)
        let segment = try TestAudio.makeWAV(seconds: 0.7, amplitude: 0.5)
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: segment.deletingLastPathComponent())
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "extension-combined-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await AudioExtensionComposer.compose(
            sourceURL: source, segmentURL: segment, outputURL: output
        )
        #expect(result.normalized)
        #expect(abs(result.duration - 1.7) < 0.35)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func failureInjectorIsOneShotAndPhaseSpecific() {
        let injector = AudioExtensionFailureInjector()
        injector.arm(.beforeSafeSwap)
        #expect(!injector.consume(.beforeComposition))
        #expect(injector.consume(.beforeSafeSwap))
        #expect(!injector.consume(.beforeSafeSwap))
        injector.arm(.afterSafeSwap)
        #expect(injector.consume(.afterSafeSwap))
    }
}
