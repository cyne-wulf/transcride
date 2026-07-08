import Foundation

/// ⚠️ M3 SEAM — the transcription hand-off point.
///
/// `audioEntryReady` is called exactly once for every entry whose audio just
/// became final:
/// - after a recording is stopped and finalized (`AppModel.stopRecording`)
/// - after each successful file import (`AppModel.importFiles`)
///
/// At that moment the entry folder contains its audio file, `waveform.json`
/// (recordings only — imports generate it lazily on first open), and a stub
/// transcript with frontmatter (`title`, `created`, `duration`, `source`) and
/// an empty body. Milestone 3 replaces this no-op with enqueueing the entry
/// into the transcription queue; the stub's empty body is what transcription
/// fills in.
enum TranscriptionSeam {
    enum Source: String {
        case recorded
        case imported
    }

    static func audioEntryReady(entryRelativePath: RelativePath, source: Source) {
        DebugLog.append(
            "TranscriptionSeam: \(source.rawValue) entry ready [\(entryRelativePath)] (no-op until M3)"
        )
    }
}
