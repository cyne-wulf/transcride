import Foundation

/// Chooses which transcript layer feeds summary generation: the Edited layer
/// when the entry is genuinely forked (same predicate the export sheet uses),
/// otherwise the Original rendered as plain markdown. Speaker labels are kept
/// in both cases so the model can attribute points to speakers.
enum SummarySourceSelector {
    static func source(
        document: FrontmatterDocument?,
        original: TranscriptOriginal?
    ) -> (text: String, layer: SummarySourceLayer)? {
        if let document,
           !TranscriptMarkdown.isStubBody(document.body),
           TranscriptEditDocument.isForked(document, comparedTo: original) {
            return nonEmpty(document.body, layer: .edited)
        }
        if let original {
            let names = document.map(SpeakerNames.names(in:)) ?? [:]
            let text = TranscriptMarkdown.body(from: original, speakerNames: names)
            return nonEmpty(text, layer: .original)
        }
        return nil
    }

    private static func nonEmpty(
        _ text: String, layer: SummarySourceLayer
    ) -> (text: String, layer: SummarySourceLayer)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed, layer)
    }
}
