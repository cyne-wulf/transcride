import Foundation

/// The transcription hand-off point.
///
/// `audioEntryReady` is called exactly once for every entry whose audio just
/// became final:
/// - after a recording is stopped and finalized (`AppModel.stopRecording`)
/// - after each successful file import (`AppModel.importFiles`)
///
/// At that moment the entry folder contains its audio file, `waveform.json`
/// (recordings only — imports generate it lazily on first open), and a stub
/// transcript with frontmatter and an empty body. The entry is enqueued into
/// the current vault's transcription queue (TRN-1), which fills the stub in.
@MainActor
enum TranscriptionSeam {
    enum Source: String {
        case recorded
        case imported
    }

    /// The active vault's queue; owned by `AppModel`, swapped on vault change.
    static weak var queue: TranscriptionQueue?

    static func audioEntryReady(entryRelativePath: RelativePath, source: Source) {
        DebugLog.append("TranscriptionSeam: \(source.rawValue) entry ready [\(entryRelativePath)]")
        queue?.enqueue(entryRelativePath: entryRelativePath, source: source.rawValue)
    }
}
