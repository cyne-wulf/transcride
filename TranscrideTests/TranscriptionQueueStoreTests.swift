import Foundation
import Testing

@Suite("Transcription queue persistence")
struct TranscriptionQueueStoreTests {
    private func makeVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "queue-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func roundTripsItems() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let items = [
            TranscriptionQueueItem(
                entryRelativePath: "transcride-20260709-120000",
                modelID: "parakeet-tdt-v3", source: "recorded",
                createdAt: Date(timeIntervalSince1970: 1_780_000_000)
            ),
            TranscriptionQueueItem(
                entryRelativePath: "notes/transcride-20260709-130000-title",
                modelID: "whisperkit-small", source: "retranscribe",
                isRetranscribe: true,
                createdAt: Date(timeIntervalSince1970: 1_780_000_100),
                state: .failed, errorMessage: "boom"
            ),
        ]
        try TranscriptionQueueStore.save(items, toVault: vault)
        let loaded = TranscriptionQueueStore.load(fromVault: vault)
        #expect(loaded == items)
    }

    @Test func preSpeakerDetectionQueueFilesStillDecode() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // A queue file written before TRN-6 added detectSpeakers/speakerCount.
        let legacy = """
        {
          "version": 1,
          "items": [{
            "id": "legacy-item",
            "entryRelativePath": "transcride-20260709-120000",
            "modelID": "parakeet-tdt-v3",
            "source": "recorded",
            "isRetranscribe": false,
            "createdAt": "2026-07-09T12:00:00Z",
            "state": "waiting"
          }]
        }
        """
        let fileURL = TranscriptionQueueStore.url(inVault: vault)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try legacy.data(using: .utf8)!.write(to: fileURL)

        let loaded = TranscriptionQueueStore.load(fromVault: vault)
        #expect(loaded.count == 1)
        #expect(loaded.first?.detectSpeakers == false)
        #expect(loaded.first?.speakerCount == nil)

        // New fields round-trip.
        var item = try #require(loaded.first)
        item.detectSpeakers = true
        item.speakerCount = 2
        try TranscriptionQueueStore.save([item], toVault: vault)
        #expect(TranscriptionQueueStore.load(fromVault: vault) == [item])
    }

    @Test func runningItemsResumeAsWaitingAfterRelaunch() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        var item = TranscriptionQueueItem(
            entryRelativePath: "transcride-20260709-120000",
            modelID: "parakeet-tdt-v3", source: "imported",
            createdAt: .now
        )
        item.state = .running
        try TranscriptionQueueStore.save([item], toVault: vault)

        let loaded = TranscriptionQueueStore.load(fromVault: vault)
        #expect(loaded.count == 1)
        #expect(loaded[0].state == .waiting)
        #expect(loaded[0].id == item.id)
    }

    @Test func missingFileLoadsEmpty() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(TranscriptionQueueStore.load(fromVault: vault).isEmpty)
    }

    @Test func queueFileLivesInHiddenDirectory() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try TranscriptionQueueStore.save([], toVault: vault)
        let url = TranscriptionQueueStore.url(inVault: vault)
        #expect(url.pathComponents.contains(".transcride"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
