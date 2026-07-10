import Foundation
import Testing

@Suite("Storage accounting")
struct VaultStorageTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "transcride-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test func bucketsAudioTextAndTrash() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let entryA = root.appending(path: "Journal/transcride-2026-07-01T10-00-00-big")
        try write(5000, to: entryA.appending(path: "audio.m4a"))
        try write(300, to: entryA.appending(path: "transcript.md"))
        try write(200, to: entryA.appending(path: "transcript.original.json"))
        try write(100, to: entryA.appending(path: "waveform.json"))

        let entryB = root.appending(path: "transcride-2026-07-02T11-00-00-small")
        try write(2000, to: entryB.appending(path: "audio.wav"))
        try write(50, to: entryB.appending(path: "transcript.md"))

        // Note-only entry: never in the audio bucket or the ranking.
        let entryC = root.appending(path: "transcride-2026-07-03T12-00-00-note")
        try write(80, to: entryC.appending(path: "transcript.md"))

        try write(40, to: root.appending(path: "vocabulary.txt"))
        try write(60, to: root.appending(path: ".transcride/queue.json"))
        try write(900, to: root.appending(path: ".trash/audio-old/audio.m4a"))
        try write(30, to: root.appending(path: ".trash/audio-old.trashinfo.json"))

        let summary = VaultStorage.measure(vaultRoot: root)
        #expect(summary.audioBytes == 7000)
        #expect(summary.textBytes == 300 + 200 + 100 + 50 + 80 + 40 + 60)
        #expect(summary.trashBytes == 930)
        #expect(summary.totalBytes == 7000 + 830 + 930)
    }

    @Test func ranksLargestAudioEntriesDescending() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(1000, to: root.appending(path: "transcride-2026-07-01T10-00-00-a/audio.m4a"))
        try write(3000, to: root.appending(path: "Journal/transcride-2026-07-02T10-00-00-b/audio.m4a"))
        try write(2000, to: root.appending(path: "transcride-2026-07-03T10-00-00-c/audio.mp3"))
        try write(500, to: root.appending(path: "transcride-2026-07-04T10-00-00-d/transcript.md"))

        let ranked = VaultStorage.measure(vaultRoot: root).largestAudioEntries
        #expect(ranked.map(\.audioBytes) == [3000, 2000, 1000])
        #expect(ranked.first?.entryRelativePath == "Journal/transcride-2026-07-02T10-00-00-b")
    }

    @Test func rankingIsCappedAndDeterministicOnTies() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...5 {
            try write(100, to: root.appending(
                path: "transcride-2026-07-0\(index)T10-00-00-e\(index)/audio.m4a"
            ))
        }
        let ranked = VaultStorage.measure(vaultRoot: root, topAudioCount: 3).largestAudioEntries
        #expect(ranked.count == 3)
        // Equal sizes fall back to path order, so the cap never flickers.
        #expect(ranked.map(\.entryRelativePath) == ranked.map(\.entryRelativePath).sorted())
    }

    @Test func emptyVaultMeasuresZero() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = VaultStorage.measure(vaultRoot: root)
        #expect(summary == VaultStorageSummary())
        #expect(summary.totalBytes == 0)
    }
}
