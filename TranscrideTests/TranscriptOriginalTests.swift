import Foundation
import Testing

@Suite("transcript.original.json schema")
struct TranscriptOriginalTests {
    private func sampleTranscript() -> TranscriptOriginal {
        TranscriptOriginal(
            engine: .init(
                engine: "parakeet",
                model: "parakeet-tdt-0.6b-v3",
                options: ["language_hint": "en"],
                created: "2026-07-09T12:00:00Z",
                appVersion: "1.0 (1)"
            ),
            segments: [
                .init(start: 0.0, end: 2.5, speaker: nil, words: [
                    .init(text: "Hello", start: 0.02, end: 0.4),
                    .init(text: "world.", start: 0.5, end: 0.9, correctedFrom: "wold."),
                ]),
                .init(start: 4.0, end: 5.0, speaker: nil, words: [
                    .init(text: "Again", start: 4.1, end: 4.6),
                ]),
            ]
        )
    }

    @Test func roundTripsThroughJSON() throws {
        let original = sampleTranscript()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptOriginal.self, from: data)
        #expect(decoded == original)
        #expect(decoded.schema == 1)
        #expect(decoded.engine.appVersion == "1.0 (1)")
        #expect(decoded.segments[0].words[1].correctedFrom == "wold.")
    }

    @Test func serializesSnakeCaseAndNullSpeaker() throws {
        let data = try JSONEncoder().encode(sampleTranscript())
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"app_version\""))
        #expect(json.contains("\"corrected_from\""))
        #expect(json.contains("\"speaker\":null"))
        // Uncorrected words must not carry a corrected_from key.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segments = object?["segments"] as? [[String: Any]]
        let firstWord = (segments?[0]["words"] as? [[String: Any]])?[0]
        #expect(firstWord?["corrected_from"] == nil)
    }

    @Test func writesAndLoadsAtomically() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcript-original-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = sampleTranscript()
        let url = TranscriptOriginal.url(inEntry: dir)
        try original.write(to: url)
        #expect(TranscriptOriginal.load(from: url) == original)
        // Human-readable: pretty-printed with real newlines.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"))
    }

    @Test func archivesExistingOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcript-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = TranscriptOriginal.url(inEntry: dir)
        try sampleTranscript().write(to: url)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let archived = try TranscriptOriginal.archiveExisting(inEntry: dir, date: date)

        #expect(archived != nil)
        #expect(archived!.lastPathComponent.hasPrefix("transcript.original.2"))
        #expect(archived!.lastPathComponent.hasSuffix(".json"))
        #expect(!archived!.lastPathComponent.contains(":"))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // Nothing to archive → nil.
        #expect(try TranscriptOriginal.archiveExisting(inEntry: dir, date: date) == nil)

        // A second archive on the same timestamp never overwrites the first.
        try sampleTranscript().write(to: url)
        let second = try TranscriptOriginal.archiveExisting(inEntry: dir, date: date)
        #expect(second != nil)
        #expect(second!.lastPathComponent != archived!.lastPathComponent)
    }
}
