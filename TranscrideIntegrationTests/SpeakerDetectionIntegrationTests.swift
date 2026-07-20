import Foundation
import Testing
@testable import Transcride

@Suite("Speaker detection vault integration", .serialized)
struct SpeakerDetectionIntegrationTests {
    @Test func generatedMarkdownTogglesBothWaysWithoutChangingCachedDiarization() async throws {
        let fixture = try makeFixture(bodyIsHandEdited: false)
        defer { try? FileManager.default.removeItem(at: fixture.vault) }
        let originalBefore = try Data(contentsOf: fixture.originalURL)
        let service = VaultService(rootURL: fixture.vault)

        try await service.setSpeakerDetectionEnabled(false, atEntryPath: fixture.entryPath)
        var document = try loadDocument(at: fixture.transcriptURL)
        #expect(!document.speakerDetectionEnabled)
        #expect(document.rawValue(for: "speaker_detection") == "false")
        #expect(document.body == "\nHello there. Welcome back.\n")
        #expect(SpeakerNames.names(in: document)["S1"] == "Alice")
        #expect(try Data(contentsOf: fixture.originalURL) == originalBefore)

        try await service.setSpeakerDetectionEnabled(true, atEntryPath: fixture.entryPath)
        document = try loadDocument(at: fixture.transcriptURL)
        #expect(document.speakerDetectionEnabled)
        #expect(document.rawValue(for: "speaker_detection") == nil)
        #expect(document.body == "\n**Alice:** Hello there.\n\n**Speaker 2:** Welcome back.\n")
        #expect(SpeakerNames.names(in: document)["S1"] == "Alice")
        #expect(try Data(contentsOf: fixture.originalURL) == originalBefore)
    }

    @Test func handEditedBodyAndSpeakerNamesSurviveBothToggleDirections() async throws {
        let fixture = try makeFixture(bodyIsHandEdited: true)
        defer { try? FileManager.default.removeItem(at: fixture.vault) }
        let originalBody = try loadDocument(at: fixture.transcriptURL).body
        let service = VaultService(rootURL: fixture.vault)

        try await service.setSpeakerDetectionEnabled(false, atEntryPath: fixture.entryPath)
        var document = try loadDocument(at: fixture.transcriptURL)
        #expect(document.body == originalBody)
        #expect(document.handEdited)
        #expect(SpeakerNames.names(in: document)["S1"] == "Alice")

        try await service.setSpeakerDetectionEnabled(true, atEntryPath: fixture.entryPath)
        document = try loadDocument(at: fixture.transcriptURL)
        #expect(document.body == originalBody)
        #expect(document.handEdited)
        #expect(SpeakerNames.names(in: document)["S1"] == "Alice")
    }

    private struct Fixture {
        let vault: URL
        let entryPath: RelativePath
        let transcriptURL: URL
        let originalURL: URL
    }

    private func makeFixture(bodyIsHandEdited: Bool) throws -> Fixture {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "TranscrideSpeakerDetectionIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let entryPath = "transcride-2026-07-17T05-50-00-speakers"
        let entryURL = vault.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)

        let original = TranscriptOriginal(
            engine: .init(
                engine: "test", model: "test", options: [:], created: "", appVersion: ""
            ),
            segments: [
                .init(
                    start: 0, end: 0.9, speaker: "S1",
                    words: [
                        .init(text: "Hello", start: 0, end: 0.4),
                        .init(text: "there.", start: 0.5, end: 0.9),
                    ]
                ),
                .init(
                    start: 1, end: 1.9, speaker: "S2",
                    words: [
                        .init(text: "Welcome", start: 1, end: 1.4),
                        .init(text: "back.", start: 1.5, end: 1.9),
                    ]
                ),
            ]
        )
        let originalURL = TranscriptOriginal.url(inEntry: entryURL)
        try original.write(to: originalURL)

        var document = FrontmatterDocument(fields: [], body: "")
        document.title = "Interview"
        SpeakerNames.set(name: "Alice", forID: "S1", in: &document)
        if bodyIsHandEdited {
            document.handEdited = true
            document.body = "My hand-edited **interview** note.\n"
        } else {
            document.body = TranscriptMarkdown.body(
                from: original, speakerNames: SpeakerNames.names(in: document)
            ) + "\n"
        }
        let transcriptURL = entryURL.appending(path: TranscriptFile.defaultName)
        try AtomicFile.write(document.serialized(), to: transcriptURL)
        return Fixture(
            vault: vault,
            entryPath: entryPath,
            transcriptURL: transcriptURL,
            originalURL: originalURL
        )
    }

    private func loadDocument(at url: URL) throws -> FrontmatterDocument {
        FrontmatterDocument.parse(try String(contentsOf: url, encoding: .utf8))
    }
}
