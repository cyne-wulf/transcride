import Foundation

/// Per-entry policy for deciding which portions of an audio clip are silent.
enum SilenceDetectionMode: String, Codable, CaseIterable, Sendable {
    case waveform
    case speech

    var displayName: String {
        switch self {
        case .waveform: "Waveform (Audio Level)"
        case .speech: "Speech Transcript"
        }
    }
}

/// Why transcript-derived silence can or cannot be used for the current audio.
enum SpeechTranscriptAvailability: Equatable, Sendable {
    case available
    case missing
    case stale
    case malformed
    case regenerating

    var explanation: String? {
        switch self {
        case .available:
            nil
        case .missing:
            "Speech Transcript needs a timed Original transcript. Transcribe this audio first."
        case .stale:
            "The Original transcript is being refreshed for changed audio. Speech-based silence detection will resume when it finishes."
        case .malformed:
            "The Original transcript does not contain valid word timing. Retranscribe this audio to use Speech Transcript."
        case .regenerating:
            "The Original transcript is currently being regenerated. Speech-based silence detection will resume when it finishes."
        }
    }
}

/// Hidden derived state proving that the visible Original still belongs to an
/// older audio timeline. Audio mutations create it; only an authoritative
/// transcription removes it. It intentionally lives outside Markdown so an
/// edited note remains byte-identical.
enum TranscriptAlignmentState {
    static let staleFileName = ".transcript-alignment-stale"

    static func staleURL(inEntry entryURL: URL) -> URL {
        entryURL.appending(path: staleFileName)
    }

    static func isStale(inEntry entryURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: staleURL(inEntry: entryURL).path)
            || ExtensionTranscriptState.load(from: entryURL) != nil
    }

    static func markStale(inEntry entryURL: URL) throws {
        try AtomicFile.write("stale\n", to: staleURL(inEntry: entryURL))
    }

    static func markAligned(inEntry entryURL: URL) {
        try? FileManager.default.removeItem(at: staleURL(inEntry: entryURL))
        try? FileManager.default.removeItem(at: ExtensionTranscriptState.url(inEntry: entryURL))
    }
}

/// A validated transcript-derived compression plan. Unlike transcript display,
/// silence detection must not invent timing by repairing malformed engine data:
/// an explicit speech selection either uses trustworthy raw word timing or is
/// visibly unavailable.
enum SpeechSilencePlanner {
    static func availability(
        transcript: TranscriptOriginal?,
        audioDuration: Double?,
        alignmentIsStale: Bool
    ) -> SpeechTranscriptAvailability {
        if alignmentIsStale { return .stale }
        guard let transcript else { return .missing }
        guard let duration = audioDuration, validatedWords(in: transcript, duration: duration) != nil else {
            return .malformed
        }
        return .available
    }

    static func makePlan(
        transcript: TranscriptOriginal,
        audioDuration: Double
    ) throws -> AudioCompressionPlan {
        guard validatedWords(in: transcript, duration: audioDuration) != nil else {
            throw AudioCompressionError.malformedTranscriptTiming
        }
        let gaps = SilenceGap.compute(from: transcript, duration: audioDuration, repairTiming: false)
        return AudioCompressionPlan(
            sourceDuration: audioDuration,
            removedIntervals: gaps.map { .init(start: $0.start, end: $0.end) }
        )
    }

    private static func validatedWords(
        in transcript: TranscriptOriginal,
        duration: Double
    ) -> [TranscriptOriginal.Word]? {
        guard duration.isFinite, duration > 0 else { return nil }
        let words = transcript.allWords.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !words.isEmpty else { return nil }
        var priorStart = -Double.infinity
        var priorEnd = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end > word.start,
                  word.end <= duration + 0.25,
                  word.start >= priorStart,
                  word.end >= priorEnd else { return nil }
            priorStart = word.start
            priorEnd = word.end
        }
        return words
    }
}

/// Pure routing state used by PlayerService. Entry identity is part of every
/// asynchronous install, preventing a late waveform/transcript task from one
/// clip from changing another clip's skip targets.
struct SilenceGapRouter: Equatable, Sendable {
    private(set) var entryID: String?
    private(set) var mode: SilenceDetectionMode = .waveform
    private(set) var waveformGaps: [SilenceGap]?
    private(set) var speechGaps: [SilenceGap]?

    mutating func configure(entryID: String, mode: SilenceDetectionMode) {
        if self.entryID != entryID {
            self.entryID = entryID
            waveformGaps = nil
            speechGaps = nil
        }
        self.mode = mode
    }

    mutating func clear() {
        entryID = nil
        mode = .waveform
        waveformGaps = nil
        speechGaps = nil
    }

    @discardableResult
    mutating func installWaveform(_ gaps: [SilenceGap], forEntryID entryID: String) -> Bool {
        guard self.entryID == entryID else { return false }
        waveformGaps = gaps
        return true
    }

    @discardableResult
    mutating func installSpeech(_ gaps: [SilenceGap]?, forEntryID entryID: String) -> Bool {
        guard self.entryID == entryID else { return false }
        speechGaps = gaps
        return true
    }

    var activeGaps: [SilenceGap] {
        switch mode {
        case .waveform: waveformGaps ?? []
        case .speech: speechGaps ?? []
        }
    }

    var selectedSourceIsReady: Bool {
        switch mode {
        case .waveform: waveformGaps != nil
        case .speech: speechGaps != nil
        }
    }
}
