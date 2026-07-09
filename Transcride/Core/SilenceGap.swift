import Foundation

/// A skippable silence interval between consecutive rendered transcript words.
struct SilenceGap: Equatable, Sendable {
    static let defaultThreshold: TimeInterval = 1.5

    var start: TimeInterval
    var end: TimeInterval
    var previousWordIndex: Int
    var nextWordIndex: Int

    var duration: TimeInterval { end - start }

    static func compute(
        from transcript: TranscriptOriginal,
        threshold: TimeInterval = defaultThreshold
    ) -> [SilenceGap] {
        let words = transcript.allWords.enumerated().filter {
            !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard words.count > 1 else { return [] }

        var result: [SilenceGap] = []
        for pairIndex in 1..<words.count {
            let previous = words[pairIndex - 1]
            let next = words[pairIndex]
            let duration = next.element.start - previous.element.end
            // PLY-5 says gaps longer than the threshold, not equal to it.
            if duration > threshold {
                result.append(SilenceGap(
                    start: previous.element.end,
                    end: next.element.start,
                    previousWordIndex: previous.offset,
                    nextWordIndex: next.offset
                ))
            }
        }
        return result
    }

    /// Destination for a playhead currently inside a skippable gap.
    static func skipDestination(
        at time: TimeInterval,
        in gaps: [SilenceGap]
    ) -> TimeInterval? {
        gaps.first(where: { time >= $0.start && time < $0.end })?.end
    }
}
