import Foundation

/// One transcription runtime bound to one concrete model (ENG-3). Async and
/// cancellable throughout (cancellation = structured `Task` cancellation) so
/// the protocol can host cloud engines in P2 without change.
protocol TranscriptionEngine: Sendable {
    var info: TranscriptionModelInfo { get }

    func isDownloaded() async -> Bool
    func downloadModel(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    func deleteModel() async throws
    /// Bytes the downloaded model occupies on disk, nil when not downloaded.
    func downloadedByteSize() async -> Int64?
    /// On-disk model folder for "Show in Finder", nil when not downloaded or
    /// system-managed (Apple Speech).
    func modelDirectory() async -> URL?

    /// Transcribes one audio file into word-timed segments. `progress` is
    /// called with 0…1 fractions on an arbitrary queue.
    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptOriginal.Segment]
}

/// The model dropdown's contents: every model the app can offer, in display
/// order. Apple SpeechTranscriber is macOS 26+ only and hidden below (ENG-1).
enum ModelCatalog {
    static let parakeetV3 = TranscriptionModelInfo(
        id: "parakeet-tdt-v3",
        displayName: "Parakeet v3",
        engineID: "parakeet",
        modelID: "parakeet-tdt-0.6b-v3",
        languagesDescription: "25 European languages incl. English",
        languageCodes: [
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
            "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ],
        downloadSizeBytes: 470_000_000,
        supportsVocabularyBiasing: false,
        supportsDiarization: false
    )

    // Vocabulary biasing stays off for the turbo variant: its distilled
    // decoder can't handle `<|startofprev|>` prompt conditioning and emits
    // an immediate end-of-text (reproduced against WhisperKit 1.0.0). The
    // correction backstop covers it instead; Whisper Small biases natively.
    static let whisperLargeV3Turbo = TranscriptionModelInfo(
        id: "whisperkit-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        engineID: "whisperkit",
        modelID: "openai_whisper-large-v3-v20240930_626MB",
        languagesDescription: "≈99 languages, auto-detected",
        languageCodes: [],
        downloadSizeBytes: 650_000_000,
        supportsVocabularyBiasing: false,
        supportsDiarization: false
    )

    static let whisperSmall = TranscriptionModelInfo(
        id: "whisperkit-small",
        displayName: "Whisper Small",
        engineID: "whisperkit",
        modelID: "openai_whisper-small",
        languagesDescription: "≈99 languages, auto-detected",
        languageCodes: [],
        downloadSizeBytes: 500_000_000,
        supportsVocabularyBiasing: true,
        supportsDiarization: false
    )

    static let appleSpeech = TranscriptionModelInfo(
        id: "apple-speech",
        displayName: "Apple Speech",
        engineID: "apple-speech",
        modelID: "speechtranscriber",
        languagesDescription: "System languages, on-device",
        languageCodes: [],
        downloadSizeBytes: 0,
        supportsVocabularyBiasing: false,
        supportsDiarization: false
    )

    /// Models offered on this machine, dropdown order. Parakeet first — it's
    /// the default.
    static var available: [TranscriptionModelInfo] {
        var models = [parakeetV3, whisperLargeV3Turbo, whisperSmall]
        if #available(macOS 26, *) {
            models.append(appleSpeech)
        }
        return models
    }

    static let defaultModelID = parakeetV3.id

    /// UserDefaults key behind the Settings default-model picker.
    static let defaultModelPreferenceKey = "defaultTranscriptionModel"

    static func info(forID id: String) -> TranscriptionModelInfo? {
        available.first { $0.id == id }
    }

    /// The user's chosen default model (Settings), falling back to Parakeet.
    static func preferredDefaultModelID(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultModelPreferenceKey) ?? ""
        return info(forID: stored)?.id ?? defaultModelID
    }
}

/// Creates and caches one engine instance per model id — loaded ML models are
/// expensive, so an engine (and its runtime) lives for the app's lifetime
/// once used.
actor EngineRegistry {
    static let shared = EngineRegistry()

    private var engines: [String: any TranscriptionEngine] = [:]

    func engine(forModelInfoID id: String) -> (any TranscriptionEngine)? {
        if let existing = engines[id] { return existing }
        guard let info = ModelCatalog.info(forID: id) else { return nil }
        let engine: (any TranscriptionEngine)?
        switch info.engineID {
        case "parakeet":
            engine = ParakeetEngine(info: info)
        case "whisperkit":
            engine = WhisperKitEngine(info: info)
        case "apple-speech":
            if #available(macOS 26, *) {
                engine = AppleSpeechEngine(info: info)
            } else {
                engine = nil
            }
        default:
            engine = nil
        }
        if let engine { engines[id] = engine }
        return engine
    }
}
