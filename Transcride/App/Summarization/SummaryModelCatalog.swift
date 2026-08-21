import Foundation

/// Per-model knobs the shared `TranscriptionModelInfo` can't carry: the
/// chunker's context budget and the sampling preset. The context budget is
/// deliberately far below Gemma's native window — KV-cache memory grows with
/// context, and the 8 GB peak-RSS ceiling governs.
struct SummaryModelSpec: Sendable {
    let contextTokens: Int
    let temperature: Float
    let topK: Int
    let topP: Float
    let maxTokens: Int
}

/// The summary model picker: small Gemma 3 QAT 4-bit checkpoints served by
/// MLX. Reuses `TranscriptionModelInfo` so `ModelManager` and the Settings
/// model rows work unchanged.
enum SummaryModelCatalog {
    static let gemma1B = TranscriptionModelInfo(
        id: "summary-gemma-3-1b-qat4",
        displayName: "Gemma 3 1B (Fast)",
        engineID: "mlx-gemma",
        modelID: "mlx-community/gemma-3-1b-it-qat-4bit",
        languagesDescription: "Multilingual",
        languageCodes: [],
        downloadSizeBytes: 750_000_000,
        supportsVocabularyBiasing: false,
        supportsDiarization: false
    )

    static let gemma4B = TranscriptionModelInfo(
        id: "summary-gemma-3-4b-qat4",
        displayName: "Gemma 3 4B (High Quality)",
        engineID: "mlx-gemma",
        modelID: "mlx-community/gemma-3-4b-it-qat-4bit",
        languagesDescription: "Multilingual",
        languageCodes: [],
        downloadSizeBytes: 3_200_000_000,
        supportsVocabularyBiasing: false,
        supportsDiarization: false
    )

    static let available: [TranscriptionModelInfo] = [gemma1B, gemma4B]

    /// Gemma's official sampling preset (temp 1.0 / top_k 64 / top_p 0.95) —
    /// the QAT checkpoints are tuned for it; a "safer" low temperature
    /// degrades them.
    static func spec(forModelInfoID id: String) -> SummaryModelSpec? {
        guard isSummaryModelID(id) else { return nil }
        return SummaryModelSpec(
            contextTokens: 8_192, temperature: 1.0, topK: 64, topP: 0.95, maxTokens: 1_024
        )
    }

    static let defaultModelPreferenceKey = "defaultSummaryModel"

    static func isSummaryModelID(_ id: String) -> Bool {
        available.contains { $0.id == id }
    }

    static func info(forID id: String) -> TranscriptionModelInfo? {
        available.first { $0.id == id }
    }

    /// What "Automatic" resolves to: under 16 GB of physical memory the 1B
    /// model, else the 4B.
    static func automaticModel(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> TranscriptionModelInfo {
        physicalMemory >= 16 * 1024 * 1024 * 1024 ? gemma4B : gemma1B
    }

    /// The user's explicit choice wins; otherwise the RAM-adaptive automatic.
    static func preferredModel(
        defaults: UserDefaults = .standard,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> TranscriptionModelInfo {
        if let id = defaults.string(forKey: defaultModelPreferenceKey),
           let info = info(forID: id) {
            return info
        }
        return automaticModel(physicalMemory: physicalMemory)
    }
}
