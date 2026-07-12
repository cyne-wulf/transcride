import Foundation

/// A skippable silence interval before, between, or after rendered transcript
/// words. Leading/trailing gaps require the corresponding audio boundary.
struct SilenceGap: Equatable, Sendable {
    static let defaultThreshold: TimeInterval = 1.5
    /// Keep playback cuts perceptually identical to Compress Audio cuts.
    static let boundaryPadding = AudioCompressionPlan.boundaryPadding

    var start: TimeInterval
    var end: TimeInterval
    var previousWordIndex: Int
    var nextWordIndex: Int

    var duration: TimeInterval { end - start }

    static func compute(
        from transcript: TranscriptOriginal,
        duration: TimeInterval? = nil,
        threshold: TimeInterval = defaultThreshold,
        repairTiming: Bool = true
    ) -> [SilenceGap] {
        let effectiveWords = duration.flatMap { duration in
            guard repairTiming else { return transcript.allWords }
            return TranscriptTimingRepair.repair(segments: transcript.segments, duration: duration)
                .segments.flatMap(\.words)
        } ?? transcript.allWords
        let words = effectiveWords.enumerated().filter {
            !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let first = words.first else { return [] }

        var result: [SilenceGap] = []
        // Transcript timing describes the first spoken word, so the interval
        // from the beginning of the clip to that word is real leading silence.
        // Use the same strict threshold as gaps between words.
        if first.element.start > threshold {
            result.append(SilenceGap(
                start: min(first.element.start, boundaryPadding),
                end: max(boundaryPadding, first.element.start - boundaryPadding),
                previousWordIndex: first.offset,
                nextWordIndex: first.offset
            ))
        }
        for pairIndex in 1..<words.count {
            let previous = words[pairIndex - 1]
            let next = words[pairIndex]
            let duration = next.element.start - previous.element.end
            // PLY-5 says gaps longer than the threshold, not equal to it.
            if duration > threshold {
                result.append(SilenceGap(
                    start: min(next.element.start, previous.element.end + boundaryPadding),
                    end: max(previous.element.end + boundaryPadding,
                             next.element.start - boundaryPadding),
                    previousWordIndex: previous.offset,
                    nextWordIndex: next.offset
                ))
            }
        }
        if let audioDuration = duration, let last = words.last {
            let trailingDuration = audioDuration - last.element.end
            if trailingDuration > threshold {
                result.append(SilenceGap(
                    start: min(audioDuration, last.element.end + boundaryPadding),
                    end: max(last.element.end + boundaryPadding,
                             audioDuration - boundaryPadding),
                    previousWordIndex: last.offset,
                    nextWordIndex: last.offset
                ))
            }
        }
        return result
    }

    /// Preferred Skip Silence source: the same real-audio amplitude, duration,
    /// and boundary rules used by Compress Audio. Waveform peaks are 50 ms
    /// windows rather than Compress's 20 ms analysis windows, but both share
    /// the exact -40 dBFS threshold and cut planner.
    static func compute(from waveform: WaveformData) -> [SilenceGap] {
        let plan = AudioCompressionPlan.make(
            windowPeaks: waveform.peaks,
            windowDuration: 1 / Double(waveform.peaksPerSecond),
            sourceDuration: waveform.duration
        )
        return plan.removedIntervals.map {
            SilenceGap(start: $0.start, end: $0.end, previousWordIndex: 0, nextWordIndex: 0)
        }
    }

    /// Destination for a playhead currently inside a skippable gap.
    static func skipDestination(
        at time: TimeInterval,
        in gaps: [SilenceGap]
    ) -> TimeInterval? {
        gaps.first(where: { time >= $0.start && time < $0.end })?.end
    }
}
