import AVFoundation
import Foundation
import Testing

/// Proves the hand-written CAF journal against every consumer that reads it
/// after a crash — before and instead of trusting the format by inspection.
@Suite("Durable audio journal writer")
struct DurableAudioJournalWriterTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcride-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        return buffer
    }

    private func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func dataChunkSize(of url: URL) throws -> Int64 {
        let data = try Data(contentsOf: url)
        try #require(data.count >= DurableAudioJournalWriter.headerByteCount)
        return (56..<64).reduce(Int64(0)) { ($0 << 8) | Int64(data[$1]) }
    }

    // MARK: Format

    @Test func headerIsTheExpectedSixtyEightBytes() throws {
        let header = DurableAudioJournalWriter.header()
        #expect(header.count == 68)
        // File header: 'caff', version 1, flags 0.
        #expect(Array(header[0..<4]) == Array("caff".utf8))
        #expect(Array(header[4..<8]) == [0, 1, 0, 0])
        // desc chunk: type + big-endian Int64 size 32.
        #expect(Array(header[8..<12]) == Array("desc".utf8))
        #expect(Array(header[12..<20]) == [0, 0, 0, 0, 0, 0, 0, 32])
        // desc payload: BE Float64 44100.0, 'lpcm', flags 2 (little-endian
        // integer), 2 bytes/packet, 1 frame/packet, 1 channel, 16 bits.
        #expect(Array(header[20..<28]) == [0x40, 0xE5, 0x88, 0x80, 0, 0, 0, 0])
        #expect(Array(header[28..<32]) == Array("lpcm".utf8))
        #expect(Array(header[32..<36]) == [0, 0, 0, 2])
        #expect(Array(header[36..<40]) == [0, 0, 0, 2])
        #expect(Array(header[40..<44]) == [0, 0, 0, 1])
        #expect(Array(header[44..<48]) == [0, 0, 0, 1])
        #expect(Array(header[48..<52]) == [0, 0, 0, 16])
        // data chunk: size -1 ("to EOF"), then mEditCount 0.
        #expect(Array(header[52..<56]) == Array("data".utf8))
        #expect(Array(header[56..<64]) == [Int](repeating: 0xFF, count: 8).map(UInt8.init))
        #expect(Array(header[64..<68]) == [0, 0, 0, 0])
    }

    @Test func cleanCloseProducesAnExactReadableFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 0.25, 2.0, -3.0]
        try writer.write(from: makeBuffer(samples))
        #expect(writer.framesWritten == Int64(samples.count))
        writer.close()

        // The size field was patched: mEditCount (4) + 8 frames × 2 bytes.
        #expect(try dataChunkSize(of: url) == 20)

        let decoded = try decode(url)
        try #require(decoded.count == samples.count)
        let tolerance = Float(1.5) / 32_767
        for (index, sample) in samples.enumerated() {
            // Out-of-range input must clamp, not wrap.
            let expected = min(max(sample, -1), 1)
            #expect(abs(decoded[index] - expected) <= tolerance)
        }
    }

    @Test func unclosedJournalIsReadableToEOF() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        let samples = (0..<4410).map { Float(sin(Double($0) * 0.05)) * 0.8 }
        try writer.write(from: makeBuffer(samples))
        writer.closeDiscarding()

        // Bytes on disk are exactly what a crash leaves: size still -1.
        #expect(try dataChunkSize(of: url) == -1)

        let file = try AVAudioFile(forReading: url)
        #expect(Int(file.length) == samples.count)
        file.close()
        let decoded = try decode(url)
        try #require(decoded.count == samples.count)
        #expect(abs(decoded[100] - samples[100]) <= 1.5 / 32_767)
    }

    @Test func everyRecoveryConsumerAcceptsAnUnclosedJournal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        let samples = [Float](repeating: 0.4, count: 44_100)
        try writer.write(from: makeBuffer(samples))
        writer.closeDiscarding()

        // The crash-recovery inspector.
        let inspection = try MicrophoneJournalInspector.inspect(url)
        #expect(inspection.frames == 44_100)
        #expect(inspection.hasSignal)

        // The finalize encoder.
        let m4a = directory.appending(path: "audio.m4a")
        try CrashTolerantAudioJournal.encodeM4A(from: url, to: m4a, encoding: .aac)
        let encoded = try AVAudioFile(forReading: m4a)
        #expect(abs(Double(encoded.length) - 44_100) < 4_500)
        encoded.close()

        // The recovery pre-flight: an audio track AVFoundation can time.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.05)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)

        // The recovery passthrough exporter treats failure as a soft path
        // (CAF-copy fallback), so the contract is parity: our journal must
        // export exactly when an AVAudioFile-written journal of the same
        // content does.
        let referenceURL = directory.appending(path: "reference.caf")
        let reference = try AVAudioFile(
            forWriting: referenceURL,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try reference.write(from: makeBuffer(samples))
        reference.close()
        func passthroughExports(_ source: URL, to name: String) async -> Bool {
            guard let exporter = AVAssetExportSession(
                asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough
            ) else { return false }
            do {
                try await exporter.export(to: directory.appending(path: name), as: .m4a)
                return true
            } catch { return false }
        }
        let ours = await passthroughExports(url, to: "ours.m4a")
        let theirs = await passthroughExports(referenceURL, to: "theirs.m4a")
        #expect(ours == theirs)

        // The universal-recording mixer, with this journal as the microphone.
        let sidecarURL = directory.appending(path: ".recording-system-audio.sparse")
        let sidecar = SparseSystemAudioJournal(
            url: sidecarURL, configuration: .init(preRollFrames: 0, releaseFrames: 0)
        )
        try sidecar.append(
            samples: [Float](repeating: 0.5, count: 1_000), startFrame: 100, peak: 0.5
        )
        _ = sidecar.finish()
        let mixed = try UniversalRecordingFileMixer.render(
            microphoneURL: url,
            systemJournalURL: sidecarURL,
            stagedURL: directory.appending(path: ".recording-mixed.caf")
        )
        #expect(mixed.frames == 44_100)
    }

    @Test func truncatedTailReadsWholeFramesOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        try writer.write(from: makeBuffer([Float](repeating: 0.3, count: 1_000)))
        writer.closeDiscarding()

        // Sever mid-sample: 999 whole frames plus one torn byte.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(68 + 999 * 2 + 1))
        try handle.close()

        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        #expect(Int(file.length) == 999)
    }

    @Test func headerOnlyJournalHasZeroFrames() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        writer.closeDiscarding()

        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        #expect(file.length == 0)
    }

    // MARK: Durability barriers

    @Test func barriersFireOnTheByteCadenceOffTheWritingThread() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")

        let state = BarrierSpy()
        let writingThread = Thread.current
        // 500-frame interval; each 441-frame buffer is under it, every second
        // buffer crosses it.
        let writer = try DurableAudioJournalWriter(
            url: url,
            barrierIntervalBytes: 1_000,
            barrier: { _ in
                state.record(onWritingThread: Thread.current == writingThread)
                return .full
            }
        )
        for _ in 0..<10 {
            try writer.write(from: makeBuffer([Float](repeating: 0.2, count: 441)))
        }
        // closeDiscarding() drains the barrier queue without a barrier of its
        // own, so the snapshot holds exactly the cadence-driven invocations.
        writer.closeDiscarding()
        let cadenceBarriers = state.snapshot()

        #expect(cadenceBarriers.count >= 1)
        #expect(cadenceBarriers.count <= 5)
        #expect(cadenceBarriers.allSatisfy { !$0 })
    }

    @Test func noCadenceBarrierFiresBelowTheThreshold() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let state = BarrierSpy()
        let writer = try DurableAudioJournalWriter(
            url: url,
            barrierIntervalBytes: .max,
            barrier: { _ in
                state.record(onWritingThread: false)
                return .full
            }
        )
        try writer.write(from: makeBuffer([Float](repeating: 0.2, count: 4_410)))
        #expect(state.snapshot().isEmpty)

        // The pause/sleep hook forces the partial interval out.
        writer.scheduleDurabilityBarrier()
        writer.closeDiscarding()
        #expect(state.snapshot().count == 1)
    }

    @Test func laterCadenceBarrierBelowFullFlipsDurabilityDegraded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(
            url: url,
            barrierIntervalBytes: 1_000,
            barrier: { _ in .fsync }
        )
        // The init-time barrier on a real APFS volume achieves F_FULLFSYNC.
        #expect(!writer.durabilityDegraded)
        try writer.write(from: makeBuffer([Float](repeating: 0.2, count: 4_410)))
        // closeDiscarding drains the barrier queue behind the cadence barrier.
        writer.closeDiscarding()
        #expect(writer.durabilityDegraded)
    }

    @Test func closeTimeBarrierBelowFullFlipsDurabilityDegraded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .barrier })
        try writer.write(from: makeBuffer([Float](repeating: 0.2, count: 100)))
        #expect(!writer.durabilityDegraded)
        writer.close()
        #expect(writer.durabilityDegraded)
    }

    // MARK: Torn close-time size patch

    /// A power cut during close()'s 8-byte size patch can apply any prefix of
    /// the write, leaving `0xFF` padding that decodes as a huge positive chunk
    /// size — which AVFoundation trusts over physical EOF, declaring up to
    /// quadrillions of frames. Every prefix length must repair back to the
    /// crash sentinel and read as exactly the frames physically present.
    @Test func everyTornSizePatchPrefixIsRepairedToTheCrashSentinel() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".recording.caf")
        let writer = try DurableAudioJournalWriter(url: url, barrier: { _ in .full })
        try writer.write(from: makeBuffer([Float](repeating: 0.4, count: 44_100)))
        writer.close()

        let cleanFile = try Data(contentsOf: url)
        let patchedField = Array(cleanFile[56..<64])

        for appliedPrefix in 0...8 {
            var torn = cleanFile
            torn.replaceSubrange(
                56..<64,
                with: patchedField[0..<appliedPrefix]
                    + [UInt8](repeating: 0xFF, count: 8 - appliedPrefix)
            )
            let tornURL = directory.appending(path: "torn-\(appliedPrefix).caf")
            try torn.write(to: tornURL)

            let repaired = DurableAudioJournalWriter.repairDataChunkSize(at: tornURL)
            // 0 applied bytes is the crash sentinel and 8 the clean close —
            // both already valid; every partial patch must be rewritten.
            #expect(repaired == (appliedPrefix != 0 && appliedPrefix != 8))
            if repaired {
                #expect(try dataChunkSize(of: tornURL) == -1)
            }

            let file = try AVAudioFile(forReading: tornURL)
            #expect(Int(file.length) == 44_100)
            file.close()
        }
    }

    @Test func repairLeavesForeignCAFFilesUntouched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "reference.caf")
        let reference = try AVAudioFile(
            forWriting: url,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try reference.write(from: makeBuffer([Float](repeating: 0.4, count: 4_410)))
        reference.close()

        let before = try Data(contentsOf: url)
        #expect(DurableAudioJournalWriter.repairDataChunkSize(at: url) == false)
        #expect(try Data(contentsOf: url) == before)
    }
}

private final class BarrierSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [Bool] = []

    func record(onWritingThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(onWritingThread)
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}
