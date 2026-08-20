import AVFoundation
import Foundation
import Testing

/// Pins the two contracts for a sidecar whose final record is severed at EOF:
/// finalize (strict) treats it as corruption, recovery (lenient) keeps the
/// intact prefix — and structural corruption throws under both.
@Suite("Sparse sidecar tail policy")
struct SparseSidecarTailPolicyTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcride-tailpolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A one-second microphone journal and a sidecar holding two records, the
    /// second of which is then severed mid-payload.
    private func makeTornFixture(in directory: URL) throws -> (mic: URL, sidecar: URL) {
        let micURL = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: micURL, barrier: { _ in .full })
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: 44_100)
        }
        try writer.write(from: buffer)
        writer.close()

        let sidecarURL = directory.appending(path: ".recording-system-audio.sparse")
        let journal = SparseSystemAudioJournal(
            url: sidecarURL, configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try journal.append(
            samples: [Float](repeating: 0.5, count: 4_410), startFrame: 0, peak: 0.5
        )
        try journal.append(
            samples: [Float](repeating: 0.5, count: 4_410), startFrame: 8_820, peak: 0.5
        )
        _ = try #require(journal.finish())

        let byteCount = try #require(
            FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? Int
        )
        let handle = try FileHandle(forWritingTo: sidecarURL)
        try handle.truncate(atOffset: UInt64(byteCount - 100))
        try handle.close()
        return (micURL, sidecarURL)
    }

    @Test func strictModeRejectsATornTail() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeTornFixture(in: directory)

        #expect(throws: UniversalRecordingFileMixError.self) {
            try UniversalRecordingFileMixer.render(
                microphoneURL: fixture.mic,
                systemJournalURL: fixture.sidecar,
                stagedURL: directory.appending(path: ".recording-mixed.caf")
            )
        }
    }

    @Test func lenientModeMixesTheIntactPrefix() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeTornFixture(in: directory)
        let stagedURL = directory.appending(path: ".recording-mixed.caf")

        let result = try UniversalRecordingFileMixer.render(
            microphoneURL: fixture.mic,
            systemJournalURL: fixture.sidecar,
            stagedURL: stagedURL,
            tailPolicy: .tolerateTruncatedTail
        )
        #expect(result.frames == 44_100)
        #expect(result.firstSystemFrame == 0)

        // The intact first record is audible in the mix; the torn region is
        // silent microphone only.
        let file = try AVAudioFile(forReading: stagedURL)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 44_100
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(abs(channel[1_000]) > 0.1)
        #expect(abs(channel[20_000]) < 0.001)
    }

    /// The torn record began at frame 8,820 with 4,410 samples; truncation cut
    /// its last 100 bytes (25 samples). The 4,385 whole frames that reached the
    /// file are genuine captured audio and must survive into the mix — lenient
    /// recovery salvages the record's prefix, not just earlier records.
    @Test func lenientModeSalvagesTheTornRecordsSurvivingFrames() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeTornFixture(in: directory)
        let stagedURL = directory.appending(path: ".recording-mixed.caf")

        let result = try UniversalRecordingFileMixer.render(
            microphoneURL: fixture.mic,
            systemJournalURL: fixture.sidecar,
            stagedURL: stagedURL,
            tailPolicy: .tolerateTruncatedTail
        )
        #expect(result.frames == 44_100)

        let file = try AVAudioFile(forReading: stagedURL)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 44_100
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(abs(channel[12_000]) > 0.09)   // inside the salvaged prefix
        #expect(abs(channel[20_000]) < 0.001)  // beyond the torn point
    }

    /// A count field corrupted within its valid range (4,410 → 4,411) is
    /// indistinguishable from a torn tail at EOF. Lenient recovery must still
    /// deliver every frame physically present instead of discarding the whole
    /// final record; strict finalize still refuses the file.
    @Test func corruptedCountFieldStillRecoversEveryPresentFrame() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeTornFixture(in: directory)
        // Rebuild the sidecar intact, then bump only the final record's count.
        let journal = SparseSystemAudioJournal(
            url: fixture.sidecar, configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try journal.append(
            samples: [Float](repeating: 0.5, count: 4_410), startFrame: 0, peak: 0.5
        )
        try journal.append(
            samples: [Float](repeating: 0.5, count: 4_410), startFrame: 8_820, peak: 0.5
        )
        _ = try #require(journal.finish())
        // Layout: 8 (magic) + 12 + 4410×4 (record 1) puts record 2's header at
        // 17,660; its little-endian UInt32 count sits 8 bytes in.
        let handle = try FileHandle(forWritingTo: fixture.sidecar)
        try handle.seek(toOffset: 17_668)
        try handle.write(contentsOf: Data([0x3B, 0x11, 0x00, 0x00])) // 4,411
        try handle.close()

        #expect(throws: UniversalRecordingFileMixError.self) {
            try UniversalRecordingFileMixer.render(
                microphoneURL: fixture.mic,
                systemJournalURL: fixture.sidecar,
                stagedURL: directory.appending(path: ".recording-mixed.caf")
            )
        }

        let stagedURL = directory.appending(path: ".recording-mixed-lenient.caf")
        let result = try UniversalRecordingFileMixer.render(
            microphoneURL: fixture.mic,
            systemJournalURL: fixture.sidecar,
            stagedURL: stagedURL,
            tailPolicy: .tolerateTruncatedTail
        )
        #expect(result.frames == 44_100)

        let file = try AVAudioFile(forReading: stagedURL)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 44_100
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        // Every frame of both records is physically present and recovered.
        #expect(abs(channel[1_000]) > 0.09)
        #expect(abs(channel[13_000]) > 0.09)
    }

    @Test func structuralCorruptionThrowsUnderBothPolicies() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeTornFixture(in: directory)
        // Repair nothing — instead scramble the magic so the defect is
        // structural rather than a torn tail.
        let handle = try FileHandle(forWritingTo: fixture.sidecar)
        try handle.write(contentsOf: Data("XXXXXXXX".utf8))
        try handle.close()

        for tailPolicy in [SparseSidecarTailPolicy.strict, .tolerateTruncatedTail] {
            #expect(throws: UniversalRecordingFileMixError.self) {
                try UniversalRecordingFileMixer.render(
                    microphoneURL: fixture.mic,
                    systemJournalURL: fixture.sidecar,
                    stagedURL: directory.appending(path: ".recording-mixed.caf"),
                    tailPolicy: tailPolicy
                )
            }
        }
    }
}
