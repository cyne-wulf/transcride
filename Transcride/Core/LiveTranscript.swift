import Foundation

/// Display state for live (streaming) transcription: `confirmed` text is
/// final through the last detected end-of-utterance; `volatile` is the
/// still-decoding tail that may keep growing. The streaming decoder is
/// append-only, so the confirmed transcript is normally a strict prefix of
/// every later partial — `resolve` degrades to the longest common prefix if
/// an engine ever violates that.
struct LiveTranscript: Sendable, Equatable {
    var confirmed = ""
    var volatile = ""

    var isEmpty: Bool { confirmed.isEmpty && volatile.isEmpty }
    var display: String { confirmed + volatile }

    /// Splits a partial transcript against the last confirmed prefix.
    static func resolve(partial: String, confirmed: String) -> LiveTranscript {
        if partial.hasPrefix(confirmed) {
            return LiveTranscript(
                confirmed: confirmed,
                volatile: String(partial.dropFirst(confirmed.count))
            )
        }
        let common = partial.commonPrefix(with: confirmed)
        return LiveTranscript(
            confirmed: common,
            volatile: String(partial.dropFirst(common.count))
        )
    }

    /// The last `maxCharacters` of the display text with the
    /// confirmed/volatile boundary preserved — for one-line tickers that
    /// must show the newest words, not the oldest.
    func tail(_ maxCharacters: Int) -> LiveTranscript {
        let overflow = confirmed.count + volatile.count - maxCharacters
        guard overflow > 0 else { return self }
        if overflow >= confirmed.count {
            return LiveTranscript(
                confirmed: "",
                volatile: String(volatile.suffix(maxCharacters))
            )
        }
        return LiveTranscript(
            confirmed: String(confirmed.dropFirst(overflow)),
            volatile: volatile
        )
    }
}
