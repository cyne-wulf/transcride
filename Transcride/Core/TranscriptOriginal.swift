import Foundation

/// The transcript data contract (TRN-4): `transcript.original.json`, the
/// word-timed source of truth every later milestone builds on. The engine's
/// raw output lands here once and is then never regenerated in place —
/// retranscription archives the old file and writes a new one, and vocabulary
/// corrections rewrite `text` while preserving the engine's word in
/// `corrected_from`.
///
/// Schema (version 1):
/// ```json
/// {
///   "schema": 1,
///   "engine": {
///     "engine": "parakeet",
///     "model": "parakeet-tdt-0.6b-v3",
///     "options": { "language_hint": "en" },
///     "created": "2026-07-09T14:30:00Z",
///     "app_version": "1.0 (12)"
///   },
///   "segments": [
///     { "start": 0.0, "end": 3.4, "speaker": null,
///       "words": [ { "text": "Hello", "start": 0.02, "end": 0.31 } ] }
///   ]
/// }
/// ```
/// `speaker` is always serialized (as `null` until M5 diarization fills it);
/// `corrected_from` appears only on corrected words.
struct TranscriptOriginal: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let fileName = "transcript.original.json"

    var schema: Int
    var engine: EngineMetadata
    var segments: [Segment]

    init(engine: EngineMetadata, segments: [Segment]) {
        self.schema = Self.currentSchema
        self.engine = engine
        self.segments = segments
    }

    struct EngineMetadata: Codable, Equatable, Sendable {
        /// Engine family id, e.g. "parakeet", "whisperkit", "apple-speech".
        var engine: String
        /// Concrete model id, e.g. "whisperkit-large-v3-turbo".
        var model: String
        /// Flat option strings recorded for reproducibility (ENG-4).
        var options: [String: String]
        /// ISO 8601 timestamp of when this transcript was produced.
        var created: String
        var appVersion: String

        enum CodingKeys: String, CodingKey {
            case engine, model, options, created
            case appVersion = "app_version"
        }
    }

    struct Segment: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        /// Speaker label — nil (serialized as JSON null) until M5 diarization.
        var speaker: String?
        var words: [Word]

        init(start: Double, end: Double, speaker: String? = nil, words: [Word]) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.words = words
        }

        enum CodingKeys: String, CodingKey {
            case start, end, speaker, words
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
            words = try c.decode([Word].self, forKey: .words)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            // Always emit the key so the M5 field is visible in the schema now.
            try c.encode(speaker, forKey: .speaker)
            try c.encode(words, forKey: .words)
        }
    }

    struct Word: Codable, Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
        /// The engine's original text when the vocabulary backstop rewrote it.
        var correctedFrom: String?

        init(text: String, start: Double, end: Double, correctedFrom: String? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.correctedFrom = correctedFrom
        }

        enum CodingKeys: String, CodingKey {
            case text, start, end
            case correctedFrom = "corrected_from"
        }
    }
}

// MARK: - Text projection

extension TranscriptOriginal {
    /// All words in transcript order.
    var allWords: [Word] {
        segments.flatMap(\.words)
    }

    /// Plain text of one segment (word texts joined by single spaces).
    static func text(of segment: Segment) -> String {
        segment.words.map(\.text).joined(separator: " ")
    }
}

// MARK: - File IO

extension TranscriptOriginal {
    static func url(inEntry entryURL: URL) -> URL {
        entryURL.appending(path: fileName)
    }

    /// Archive name for a superseded original: `transcript.original.<date>.json`.
    /// Colon-free so the name is valid on every filesystem.
    static func archiveFileName(date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d%02d",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "transcript.original.\(stamp).json"
    }

    /// Human-readable, deterministic JSON via `AtomicFile`.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(self), to: url)
    }

    static func load(from url: URL) -> TranscriptOriginal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptOriginal.self, from: data)
    }

    /// Moves an existing original aside before a retranscription writes the
    /// new one. Returns the archive URL, or nil when there was nothing to
    /// archive. Never overwrites an existing archive (appends a counter).
    @discardableResult
    static func archiveExisting(inEntry entryURL: URL, date: Date) throws -> URL? {
        let fm = FileManager.default
        let originalURL = url(inEntry: entryURL)
        guard fm.fileExists(atPath: originalURL.path) else { return nil }
        let baseName = archiveFileName(date: date)
        var destURL = entryURL.appending(path: baseName)
        var counter = 2
        while fm.fileExists(atPath: destURL.path) {
            let name = baseName.replacingOccurrences(of: ".json", with: "-\(counter).json")
            destURL = entryURL.appending(path: name)
            counter += 1
        }
        try fm.moveItem(at: originalURL, to: destURL)
        return destURL
    }
}
