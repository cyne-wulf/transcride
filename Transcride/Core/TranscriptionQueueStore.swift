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
    /// Speaker detection (TRN-6): run the diarizer post-pass for this item.
    var detectSpeakers: Bool
    /// Exact speaker count hint; nil = auto.
    var speakerCount: Int?
    var createdAt: Date
    var state: State
    var errorMessage: String?

    init(
        entryRelativePath: RelativePath,
        modelID: String,
        source: String,
        isRetranscribe: Bool = false,
        detectSpeakers: Bool = false,
        speakerCount: Int? = nil,
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
        self.detectSpeakers = detectSpeakers
        self.speakerCount = speakerCount
        self.createdAt = createdAt
        self.state = state
        self.errorMessage = errorMessage
    }

    // Tolerant decode: queue files written before speaker detection existed
    // have no `detectSpeakers`/`speakerCount` keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entryRelativePath = try c.decode(RelativePath.self, forKey: .entryRelativePath)
        modelID = try c.decode(String.self, forKey: .modelID)
        source = try c.decode(String.self, forKey: .source)
        isRetranscribe = try c.decode(Bool.self, forKey: .isRetranscribe)
        detectSpeakers = try c.decodeIfPresent(Bool.self, forKey: .detectSpeakers) ?? false
        speakerCount = try c.decodeIfPresent(Int.self, forKey: .speakerCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        state = try c.decode(State.self, forKey: .state)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
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
