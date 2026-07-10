import Foundation

/// One diarizer speaker turn: a machine speaker id active over a time range.
/// The App layer maps FluidAudio's `TimedSpeakerSegment` values into this Core
/// type so fusion stays pure and unit-testable.
struct SpeakerTurn: Equatable, Sendable {
    var speakerID: String
    var start: Double
    var end: Double
}

/// Fuses diarizer speaker turns into ASR segments (TRN-6): each word is
/// assigned the speaker whose turn contains the word's midpoint, and segments
/// are re-sliced at speaker changes so every segment carries a single
/// `speaker`. The diarizer emits non-overlapping turns, which makes midpoint
/// containment unambiguous; words falling in inter-turn gaps take the nearest
/// turn's speaker.
enum SpeakerAssigner {
    static func apply(
        turns: [SpeakerTurn],
        to segments: [TranscriptOriginal.Segment]
    ) -> [TranscriptOriginal.Segment] {
        guard !turns.isEmpty else { return segments }
        let sorted = turns.sorted { $0.start < $1.start }

        var result: [TranscriptOriginal.Segment] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                result.append(segment)
                continue
            }
            var slice: [TranscriptOriginal.Word] = []
            var sliceSpeaker: String?
            func flush() {
                guard let first = slice.first, let last = slice.last else { return }
                result.append(TranscriptOriginal.Segment(
                    start: first.start, end: last.end, speaker: sliceSpeaker, words: slice
                ))
                slice = []
            }
            for word in segment.words {
                let speaker = speakerID(at: (word.start + word.end) / 2, in: sorted)
                if !slice.isEmpty, speaker != sliceSpeaker { flush() }
                sliceSpeaker = speaker
                slice.append(word)
            }
            flush()
        }
        return result
    }

    /// The speaker at a time: the containing turn (ranges are `[start, end)`),
    /// else the nearest turn by interval distance, earlier turn on ties.
    static func speakerID(at time: Double, in sortedTurns: [SpeakerTurn]) -> String? {
        var best: (distance: Double, id: String)?
        for turn in sortedTurns {
            if time >= turn.start, time < turn.end { return turn.speakerID }
            let distance = time < turn.start ? turn.start - time : time - turn.end
            if best == nil || distance < best!.distance {
                best = (distance, turn.speakerID)
            }
        }
        return best?.id
    }
}

/// Display names for machine speaker ids. The JSON keeps the diarizer's
/// stable ids ("S1", "S2", …) forever; user-chosen names live in the entry's
/// frontmatter as flat `speaker_s1: "Alice"` scalars, which Obsidian shows as
/// plain text properties.
enum SpeakerNames {
    static let frontmatterKeyPrefix = "speaker_"

    /// "S1" → "Speaker 1"; anything unrecognized displays as-is.
    static func defaultDisplayName(forID id: String) -> String {
        let rest = id.dropFirst()
        if id.first?.uppercased() == "S", !rest.isEmpty, rest.allSatisfy(\.isNumber) {
            return "Speaker \(rest)"
        }
        return id
    }

    static func frontmatterKey(forID id: String) -> String {
        frontmatterKeyPrefix + id.lowercased()
    }

    /// The rename map stored in a document's frontmatter, keyed by uppercased
    /// machine id (frontmatter keys are written lowercased).
    static func names(in document: FrontmatterDocument) -> [String: String] {
        var names: [String: String] = [:]
        for field in document.fields {
            guard let key = field.key, key.hasPrefix(frontmatterKeyPrefix) else { continue }
            let id = String(key.dropFirst(frontmatterKeyPrefix.count))
            guard !id.isEmpty, let value = document.value(for: key), !value.isEmpty else { continue }
            names[id.uppercased()] = value
        }
        return names
    }

    static func displayName(forID id: String, names: [String: String]) -> String {
        names[id.uppercased()] ?? defaultDisplayName(forID: id)
    }

    /// Writes (or, for nil/empty names, removes) one rename.
    static func set(name: String?, forID id: String, in document: inout FrontmatterDocument) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        document.setValue(value, for: frontmatterKey(forID: id), quoted: value != nil)
    }

    /// Machine ids in a transcript, ordered by first appearance.
    static func speakerIDs(in transcript: TranscriptOriginal) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for segment in transcript.segments {
            guard let speaker = segment.speaker, seen.insert(speaker).inserted else { continue }
            ids.append(speaker)
        }
        return ids
    }
}
