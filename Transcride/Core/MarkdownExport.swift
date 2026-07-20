import Foundation

/// Builds the content and file name for "Export Markdown…" (EXP-2): a clean
/// `.md` — body only, no frontmatter — written into a user-picked folder such
/// as an Obsidian vault. Options apply to the original layer, whose content is
/// regenerated from the transcript; an edited body is the user's text and is
/// exported verbatim.
enum MarkdownExport {
    struct Options: Equatable, Sendable {
        var includeSpeakerLabels = true
        var includeParagraphTimestamps = false
        var speakerDetectionEnabled = true

        init(
            includeSpeakerLabels: Bool = true,
            includeParagraphTimestamps: Bool = false,
            speakerDetectionEnabled: Bool = true
        ) {
            self.includeSpeakerLabels = includeSpeakerLabels
            self.includeParagraphTimestamps = includeParagraphTimestamps
            self.speakerDetectionEnabled = speakerDetectionEnabled
        }
    }

    /// Original-layer export content: the shared rendering walk (so exports
    /// match Copy as Markdown and the generated `transcript.md` exactly),
    /// optionally prefixing each paragraph with its first word's start time.
    static func originalContent(
        from transcript: TranscriptOriginal,
        speakerNames: [String: String] = [:],
        options: Options = Options()
    ) -> String {
        let rendering = TranscriptMarkdown.rendering(
            from: transcript,
            speakerNames: speakerNames,
            speakerDetectionEnabled: options.speakerDetectionEnabled,
            speakerLabels: options.includeSpeakerLabels
        )
        guard options.includeParagraphTimestamps else { return rendering.text }

        var paragraphs: [String] = []
        var offset = 0
        for (index, paragraph) in rendering.text.components(separatedBy: "\n\n").enumerated() {
            if index > 0 { offset += 2 }
            let start = offset
            offset += paragraph.utf16.count
            let firstWord = rendering.words.first { $0.range.lowerBound >= start }
            if let firstWord, !paragraph.isEmpty {
                paragraphs.append("[\(timestampLabel(firstWord.startTime))] \(paragraph)")
            } else {
                paragraphs.append(paragraph)
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Edited-layer export content: the markdown body as the user wrote it.
    static func editedContent(body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[m:ss]`-style paragraph timestamp, growing to `[h:mm:ss]` past an hour.
    static func timestampLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Export file name from the entry title (same sanitization as the vault's
    /// transcript file), suffixed " 2", " 3", … until it avoids `existingNames`
    /// (compared case-insensitively — export destinations are usually on
    /// case-insensitive file systems).
    static func fileName(forTitle title: String?, existingNames: some Sequence<String>) -> String {
        let base = TranscriptFile.fileName(forTitle: title)
        let taken = Set(existingNames.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        let stem = String(base.dropLast(".md".count))
        var counter = 2
        while taken.contains("\(stem) \(counter).md".lowercased()) { counter += 1 }
        return "\(stem) \(counter).md"
    }
}
