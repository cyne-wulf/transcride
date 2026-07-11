import Foundation
import Testing

@Suite("Interrupted recording recovery")
struct InterruptedRecordingRecoveryTests {
    private func makeEntry() throws -> (root: URL, path: RelativePath, url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let path = "Journal/transcride-2026-07-11T10-30-00"
        let url = root.appendingRelativePath(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (root, path, url)
    }

    @Test func relaunchPromotesValidPartialIntoCompleteEntry() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 1.2, amplitude: 0.35)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let recovered = try #require(summary.recovered.first)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(recovered.entryRelativePath == fixture.path)
        #expect(abs(recovered.duration - 1.2) < 0.1)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(path: recovered.audioFileName).path
        ))
        #expect(WaveformData.load(from: WaveformData.url(inEntry: fixture.url)) != nil)

        let transcriptURL = try #require(TranscriptFile.url(inEntry: fixture.url))
        let document = FrontmatterDocument.parse(
            try String(contentsOf: transcriptURL, encoding: .utf8)
        )
        #expect(document.title == EntryCreator.recordingDefaultTitle)
        #expect(document.source == "recorded")
        #expect(abs((document.duration ?? 0) - 1.2) < 0.1)

        var scanner = VaultScanner()
        let entry = try #require(scanner.scan(root: fixture.root).entry(withID: fixture.path))
        #expect(entry.hasAudio)
        #expect(entry.hasTranscript)
    }

    @Test func recoveryIsIdempotent() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.5, amplitude: 0.2)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let first = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(first.recovered.count == 1)
        #expect(second.recovered.isEmpty)
        #expect(second.failures.isEmpty)
        let visible = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
            .filter { $0 == "audio.m4a" || $0 == "audio.caf" }
        #expect(visible.count == 1)
    }

    @Test func corruptPartialIsRetainedForFutureRecovery() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try AtomicFile.write("not audio", to: partial)

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.recovered.isEmpty)
        #expect(summary.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(TranscriptFile.url(inEntry: fixture.url) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        #expect(VaultScanner.audioFile(in: names.filter { !$0.hasPrefix(".") }) == nil)
    }

    @Test func crashAfterVisibleInstallConvergesWithoutDuplication() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try TestAudio.makeWAV(seconds: 0.6, amplitude: 0.4)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: source, to: fixture.url.appending(path: "audio.caf"))
        try FileManager.default.copyItem(
            at: source,
            to: fixture.url.appending(path: RecorderPartialFile.name)
        )

        let summary = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(summary.recovered.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.url.appending(path: RecorderPartialFile.name).path
        ))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
        #expect(names.filter { $0 == "audio.m4a" || $0 == "audio.caf" }.count == 1)
    }

    @Test func legacyPacketizedPartialIsAcknowledgedOnceWithoutDeletingBytes() async throws {
        let fixture = try makeEntry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Minimal CAF header with a description chunk whose format id is
        // ALAC, matching the variable-packet journals written pre-fix.
        var bytes = Data("caff".utf8)
        bytes.append(contentsOf: [0, 1, 0, 0])
        bytes.append(Data("desc".utf8))
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
        bytes.append(contentsOf: [0x40, 0xe5, 0x88, 0x80, 0, 0, 0, 0])
        bytes.append(Data("alac".utf8))
        bytes.append(Data(repeating: 0, count: 128))
        let partial = fixture.url.appending(path: RecorderPartialFile.name)
        try bytes.write(to: partial)

        let first = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(first.recovered.isEmpty)
        #expect(first.failures.isEmpty)
        #expect(first.acknowledgedLegacyPaths == [fixture.path])
        #expect(try Data(contentsOf: partial) == bytes)
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.appending(
                path: InterruptedRecordingRecovery.legacyMarkerFileName
            ).path
        ))

        let second = await InterruptedRecordingRecovery.recoverAll(inVault: fixture.root)
        #expect(second == InterruptedRecordingRecoverySummary())
        #expect(try Data(contentsOf: partial) == bytes)
    }
}
