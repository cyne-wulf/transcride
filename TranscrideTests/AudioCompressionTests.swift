import Foundation
import Testing

@Suite("Silence-removal compression")
struct AudioCompressionTests {
    @Test func planOnlyRemovesRunsLongerThanThreshold() {
        // 0.5 s sound, exactly 1.5 s silence, 0.5 s sound: unchanged.
        let exact = AudioCompressionPlan.make(
            windowPeaks: [0.5] + Array(repeating: 0, count: 3) + [0.5],
            windowDuration: 0.5,
            sourceDuration: 2.5,
            boundaryPadding: 0.1
        )
        #expect(exact.removedIntervals.isEmpty)

        // 2 s silence qualifies, with 0.1 s retained at each boundary.
        let long = AudioCompressionPlan.make(
            windowPeaks: [0.5] + Array(repeating: 0, count: 4) + [0.5],
            windowDuration: 0.5,
            sourceDuration: 3,
            boundaryPadding: 0.1
        )
        #expect(long.removedIntervals == [.init(start: 0.6, end: 2.4)])
        #expect(abs(long.removedDuration - 1.8) < 0.001)
        #expect(long.keptIntervals == [
            .init(start: 0, end: 0.6), .init(start: 2.4, end: 3),
        ])
    }

    @Test func quietRoomToneCountsAsSilenceButSoftSpeechDoesNot() {
        let plan = AudioCompressionPlan.make(
            windowPeaks: [0.009, 0.01, 0.011],
            windowDuration: 1,
            sourceDuration: 3,
            boundaryPadding: 0
        )
        #expect(plan.removedIntervals == [.init(start: 0, end: 2)])
    }

    @Test func analyzerAndRendererRemoveRealSilentSpan() async throws {
        let source = try TestAudio.makeWAV(segments: [
            .init(seconds: 0.6, amplitude: 0.25),
            .init(seconds: 2.0, amplitude: 0),
            .init(seconds: 0.6, amplitude: 0.4),
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let plan = try await AudioSilenceAnalyzer.analyze(source)
        #expect(plan.removedIntervals.count == 1)
        #expect(abs(plan.removedDuration - 1.8) < 0.08)
        let rendered = try await AudioCompressionRenderer.render(sourceURL: source, plan: plan)
        defer { try? FileManager.default.removeItem(at: rendered.url.deletingLastPathComponent()) }
        #expect(abs(rendered.duration - 1.4) < 0.3)
    }

    @Test func analyzerDoesNotChangeContinuousAudio() async throws {
        let source = try TestAudio.makeWAV(seconds: 2, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let plan = try await AudioSilenceAnalyzer.analyze(source)
        #expect(plan.removedIntervals.isEmpty)
    }

    @Test func applierPreservesOriginalAndUnknownFrontmatter() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-compress-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = "transcride-2026-07-11T06-00-00-compress"
        let entry = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.write("original", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write(
            "---\ntitle: Test\nduration: 8.00\ncustom: keep\n---\nHand edited.\n",
            to: entry.appending(path: "transcript.md")
        )
        try WaveformData(duration: 8, peaks: [0.1]).write(to: WaveformData.url(inEntry: entry))
        let outputDir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-rendered-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let output = outputDir.appending(path: "audio.m4a")
        try AtomicFile.write("compressed", to: output)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let result = try AudioCompressionApplier(vaultRoot: root).apply(
            renderedFileAt: output,
            expectedSourceFileName: "audio.m4a",
            sourceDuration: 8,
            compressedDuration: 5,
            removedDuration: 3,
            toEntryAt: path
        )
        #expect(result.removedDuration == 3)
        #expect(try String(contentsOf: entry.appending(path: "audio.m4a"), encoding: .utf8) == "compressed")
        let markdown = try String(contentsOf: entry.appending(path: "transcript.md"), encoding: .utf8)
        #expect(markdown.contains("duration: 5.00"))
        #expect(markdown.contains("custom: keep"))
        #expect(markdown.contains("Hand edited."))
        let original = try #require(
            try TrashStore(vaultRoot: root).items().first(where: { $0.kind == .preCompressionAudio })
        )
        #expect(original.trashedName == result.trashedName)
        #expect(original.displayName == "Pre-Compression Audio — Compress")

        _ = try TrashStore(vaultRoot: root).restore(original)
        #expect(try String(contentsOf: entry.appending(path: "audio.m4a"), encoding: .utf8) == "original")
        #expect(try TrashStore(vaultRoot: root).items().isEmpty)
    }

    @Test func legacyDisplacedCompressedAudioRestoresOneWay() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-legacy-compress-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = "transcride-2026-07-11T06-00-00-legacy-compress"
        let entry = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.write("compressed", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("---\ntitle: Test\nduration: 8.00\n---\n", to: entry.appending(path: "transcript.md"))
        try WaveformData(duration: 8, peaks: [0.1]).write(to: WaveformData.url(inEntry: entry))

        let store = TrashStore(vaultRoot: root)
        // Reproduce the sidecar shape written by the affected build: the
        // compressed timeline was displaced as ordinary entryAudio even
        // though the entry still had active audio.
        let legacyName = try store.trashEntryAudio(atEntryPath: path)
        try AtomicFile.write("original", to: entry.appending(path: "audio.m4a"))
        try AtomicFile.write("---\ntitle: Test\nduration: 8.00\n---\n", to: entry.appending(path: "transcript.md"))
        try store.restore(try #require(store.items().first(where: { $0.trashedName == legacyName })))

        #expect(try String(contentsOf: entry.appending(path: "audio.m4a"), encoding: .utf8) == "compressed")
        #expect(!FileManager.default.fileExists(atPath: entry.appending(path: "audio-2.m4a").path))
        #expect(try store.items().isEmpty)
    }
}
