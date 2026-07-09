import Foundation

/// One entry waiting for (or failing at) transcription. Persisted per vault in
/// `.transcride/queue.json` so unfinished work survives relaunch (TRN-3).
struct TranscriptionQueueItem: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting
        case running
        case failed
    }

    var id: String
    var entryRelativePath: RelativePath
    var modelID: String
    /// "recorded" / "imported" / "retranscribe" — for display and debugging.
    var source: String
    var isRetranscribe: Bool
    var createdAt: Date
    var state: State
    var errorMessage: String?

    init(
        entryRelativePath: RelativePath,
        modelID: String,
        source: String,
        isRetranscribe: Bool = false,
        createdAt: Date,
        state: State = .waiting,
        errorMessage: String? = nil,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.entryRelativePath = entryRelativePath
        self.modelID = modelID
        self.source = source
        self.isRetranscribe = isRetranscribe
        self.createdAt = createdAt
        self.state = state
        self.errorMessage = errorMessage
    }
}

/// Load/save for the persistent queue. Completed items are never persisted —
/// the file only holds work that still needs doing.
enum TranscriptionQueueStore {
    static let directoryName = ".transcride"
    static let fileName = "queue.json"

    struct FileFormat: Codable {
        var version: Int
        var items: [TranscriptionQueueItem]
    }

    static func url(inVault vaultURL: URL) -> URL {
        vaultURL.appending(path: directoryName).appending(path: fileName)
    }

    /// Loads persisted items. Anything that was `running` when the app died
    /// comes back as `waiting` so it re-runs.
    static func load(fromVault vaultURL: URL) -> [TranscriptionQueueItem] {
        guard let data = try? Data(contentsOf: url(inVault: vaultURL)),
              let file = try? decoder().decode(FileFormat.self, from: data)
        else { return [] }
        return file.items.map { item in
            var item = item
            if item.state == .running { item.state = .waiting }
            return item
        }
    }

    static func save(_ items: [TranscriptionQueueItem], toVault vaultURL: URL) throws {
        let fileURL = url(inVault: vaultURL)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(FileFormat(version: 1, items: items)), to: fileURL)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
