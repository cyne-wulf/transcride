import Foundation

/// Options handed to an engine for one transcription run (ENG-3).
struct TranscriptionOptions: Sendable, Equatable {
    /// BCP-47-ish language code hint ("en", "de") or nil for auto-detect.
    var languageHint: String?
    /// Vocabulary terms, given to engines whose capability flags say they can
    /// bias natively. The correction backstop runs for every engine regardless.
    var vocabulary: [String] = []
    /// Speaker detection (TRN-6): run the diarizer after transcription and
    /// fill `speaker` in the segments. Engines ignore this — diarization is a
    /// separate post-pass in the queue.
    var detectSpeakers: Bool = false
    /// Exact speaker count when the user knows it; nil = auto-detect.
    var speakerCount: Int?

    /// Flat string form recorded in the transcript's engine metadata (ENG-4).
    var metadataDictionary: [String: String] {
        var dict: [String: String] = [:]
        if let languageHint { dict["language_hint"] = languageHint }
        if !vocabulary.isEmpty { dict["vocabulary_terms"] = String(vocabulary.count) }
        if detectSpeakers {
            dict["speaker_detection"] = "true"
            if let speakerCount { dict["speaker_count"] = String(speakerCount) }
        }
        return dict
    }
}

/// One step of a model download as reported to the UI (ENG-2). `preparing`
/// covers work after the bytes land — first-load CoreML compilation and
/// tokenizer fetch — which can take minutes with no measurable fraction.
enum ModelDownloadProgress: Sendable, Equatable {
    case downloading(Double)
    case preparing
}

/// Static description of one model-picker entry: a concrete model on a
/// concrete engine, with the capability flags ENG-3 requires.
struct TranscriptionModelInfo: Sendable, Equatable, Identifiable {
    /// Stable id persisted in queue items and UserDefaults.
    let id: String
    let displayName: String
    /// Engine family id recorded in transcript metadata ("parakeet",
    /// "whisperkit", "apple-speech").
    let engineID: String
    /// Model id recorded in transcript metadata.
    let modelID: String
    /// Human-readable language coverage for the picker.
    let languagesDescription: String
    /// ISO codes the model supports; empty means "many/auto".
    let languageCodes: [String]
    /// Approximate download size in bytes; 0 = nothing to download.
    let downloadSizeBytes: Int64
    let supportsVocabularyBiasing: Bool
    let supportsDiarization: Bool

    var downloadSizeDescription: String {
        guard downloadSizeBytes > 0 else { return "No download" }
        return ByteCountFormatter.string(fromByteCount: downloadSizeBytes, countStyle: .file)
    }
}

/// Error taxonomy shared by all engines — local ones now, cloud ones in P2.
enum TranscriptionError: LocalizedError, Sendable {
    case modelNotDownloaded(String)
    case modelLoadFailed(String)
    case audioUnreadable(String)
    case engineFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let model):
            return "The model \(model) is not downloaded."
        case .modelLoadFailed(let reason):
            return "The model could not be loaded: \(reason)"
        case .audioUnreadable(let reason):
            return "The audio file could not be read: \(reason)"
        case .engineFailure(let reason):
            return "Transcription failed: \(reason)"
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

/// Builds sentence-shaped segments from a flat, time-ordered word stream —
/// for engines (Parakeet) that don't produce segments themselves. Breaks on
/// sentence-final punctuation, on pauses, and at a hard word cap so no
/// segment grows unbounded.
enum SegmentBuilder {
    static let pauseBreak: TimeInterval = 1.2
    static let maxWordsPerSegment = 60

    /// Removes decoder control tokens (`<|en|>`, `<|endoftext|>`, …) that some
    /// engines leak into segment text — they must never reach a transcript.
    static func strippingSpecialTokens(_ text: String) -> String {
        text.replacing(/<\|[^<>|]*\|>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func segments(from words: [TranscriptOriginal.Word]) -> [TranscriptOriginal.Segment] {
        var segments: [TranscriptOriginal.Segment] = []
        var current: [TranscriptOriginal.Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptOriginal.Segment(
                start: first.start, end: last.end, speaker: nil, words: current
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end >= pauseBreak {
                flush()
            }
            current.append(word)
            let endsSentence = word.text.last.map { ".!?…".contains($0) } ?? false
            if endsSentence || current.count >= maxWordsPerSegment {
                flush()
            }
        }
        flush()
        return segments
    }
}
