import Foundation

/// Decides whether an AI summary title may rename the entry: only titles the
/// machine gave the entry are replaceable — a human-chosen title is
/// permanent. Machine lineage is detected by regenerating what the machine
/// would have produced and comparing (same trick fork detection uses), so no
/// frontmatter flag is needed.
enum SummaryTitlePolicy {
    static func entryTitleIsMachineDerived(
        currentTitle: String?,
        original: TranscriptOriginal?,
        previousSummaryTitle: String?
    ) -> Bool {
        guard let currentTitle = currentTitle?.trimmingCharacters(in: .whitespaces),
              !currentTitle.isEmpty
        else { return true }
        if currentTitle == AutoTitle.placeholderTitle { return true }
        // A prior AI summary title stays replaceable on regeneration.
        if let previousSummaryTitle, currentTitle == previousSummaryTitle { return true }
        // The transcription auto-title (first meaningful words) is machine
        // output too — recompute it and compare.
        if let original,
           let heuristic = AutoTitle.extract(
               fromTranscriptText: TranscriptMarkdown.body(from: original, speakerLabels: false)
           ),
           currentTitle == heuristic {
            return true
        }
        return false
    }
}
