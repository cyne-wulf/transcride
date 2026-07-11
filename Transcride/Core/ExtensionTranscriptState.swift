import Foundation

/// Hidden, derived UI state while the visible transcript still belongs to the
/// pre-extension audio. It lives outside Markdown so a hand-edited note stays
/// byte-identical through append and retranscription.
struct ExtensionTranscriptState: Codable, Equatable, Sendable {
    static let fileName = ".extension-transcript-state.json"

    var knownTranscriptDuration: Double
    var combinedAudioDuration: Double
    var normalizedToM4A: Bool

    static func url(inEntry entryURL: URL) -> URL {
        entryURL.appending(path: fileName)
    }

    static func load(from entryURL: URL) -> ExtensionTranscriptState? {
        guard let data = try? Data(contentsOf: url(inEntry: entryURL)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to entryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: Self.url(inEntry: entryURL))
    }
}
