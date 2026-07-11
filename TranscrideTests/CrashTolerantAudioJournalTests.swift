import AVFoundation
import Foundation
import Testing

@Suite("Crash-tolerant audio journal")
struct CrashTolerantAudioJournalTests {
    private func makeJournal(seconds: Double = 0.4) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcride-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: RecorderPartialFile.name)
        let file = try AVAudioFile(
            forWriting: url,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = 0.25
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    @Test func journalUsesFixedWidthPCM() throws {
        let journal = try makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.deletingLastPathComponent()) }
        let input = try AVAudioFile(forReading: journal)
        #expect(input.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(input.length > 0)
    }

    @Test(arguments: [RecordingOutputEncoding.aac, .alac])
    func finishedJournalEncodesToSelectedM4A(encoding: RecordingOutputEncoding) async throws {
        let journal = try makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.deletingLastPathComponent()) }
        let output = journal.deletingLastPathComponent().appending(path: "audio.m4a")
        try CrashTolerantAudioJournal.encodeM4A(
            from: journal, to: output, encoding: encoding
        )
        let duration = try await AudioImportFormat.probeDuration(of: output)
        #expect(abs(duration - 0.4) < 0.15)
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }
}
