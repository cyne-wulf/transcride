import Foundation
import Testing

@Suite("Waveform peak generation")
struct WaveformTests {
    @Test func builderEmitsMaxPerWindowAndFlushesTail() {
        var builder = WaveformBuilder(samplesPerPeak: 4)
        builder.append([0.1, -0.5, 0.2, 0.3, 0.05, 0.05, 0.05, 0.05, 0.9])
        #expect(builder.peaks == [0.5, 0.05])
        builder.finish()
        #expect(builder.peaks == [0.5, 0.05, 0.9])
        #expect(builder.sampleCount == 9)
    }

    @Test func builderClampsAndRoundsPeaks() {
        var builder = WaveformBuilder(samplesPerPeak: 2)
        builder.append([1.7, -2.0, 0.12345, 0.0])
        #expect(builder.peaks == [1.0, 0.123])
    }

    @Test func builderHandlesArbitraryChunkBoundaries() {
        var chunked = WaveformBuilder(samplesPerPeak: 3)
        chunked.append([0.1])
        chunked.append([0.2, 0.3, 0.4])
        chunked.append([0.5, 0.6])
        var whole = WaveformBuilder(samplesPerPeak: 3)
        whole.append([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        #expect(chunked.peaks == whole.peaks)
    }

    @Test func displayColumnsKeepContrastOnHourLongAudio() {
        // 1 hour at 20 peaks/s of speech-like audio: 30 s talk spans (peaks
        // near 0.9) alternating with 30 s quiet spans (0.1). Max-aggregation
        // renders this as a solid block — every ~270-peak column contains a
        // loud window — which is the long-file regression this guards.
        var peaks: [Float] = []
        for second in 0..<3600 {
            let loud = (second / 30) % 2 == 0
            peaks.append(contentsOf: [Float](repeating: loud ? 0.9 : 0.1, count: 20))
        }
        let values = WaveformDisplay.columnValues(peaks: peaks, columns: 260)
        #expect(values.count == 260)
        #expect(values.max()! > 0.99)
        #expect(values.min()! < 0.3)
        #expect(values.filter { $0 > 0.95 }.count < values.count / 2)
    }

    @Test func displayColumnsNormalizeQuietAudioWithFloor() {
        let values = WaveformDisplay.columnValues(
            peaks: [Float](repeating: 0.1, count: 100), columns: 10
        )
        // Mean 0.1 against the 0.25 noise floor → 0.4 everywhere.
        #expect(values.count == 10)
        #expect(values.allSatisfy { abs($0 - 0.4) < 0.001 })
    }

    @Test func displayColumnsHandleFewerPeaksThanColumns() {
        let values = WaveformDisplay.columnValues(peaks: [0.5, 1.0], columns: 8)
        #expect(values.count == 8)
        #expect(values.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func displayColumnsHandleDegenerateInput() {
        #expect(WaveformDisplay.columnValues(peaks: [], columns: 10).isEmpty)
        #expect(WaveformDisplay.columnValues(peaks: [0.5], columns: 0).isEmpty)
    }

    @Test func generatorMatchesKnownWAV() async throws {
        let url = try TestAudio.makeWAV(seconds: 2.0, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let waveform = try await WaveformGenerator.generate(fromAudioAt: url)
        #expect(waveform.peaksPerSecond == WaveformData.standardPeaksPerSecond)
        #expect(abs(waveform.duration - 2.0) < 0.05)
        // 2 s at 20 peaks/s of a constant 0.5 signal.
        #expect(waveform.peaks.count == 40)
        for peak in waveform.peaks {
            #expect(abs(peak - 0.5) < 0.01)
        }
    }

    @Test func generatorRejectsNonAudio() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-wf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: "fake.wav")
        try AtomicFile.write("not audio at all", to: fake)

        await #expect(throws: (any Error).self) {
            _ = try await WaveformGenerator.generate(fromAudioAt: fake)
        }
    }

    @Test func waveformDataRoundTripsAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "transcride-wfjson-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = WaveformData.url(inEntry: dir)
        #expect(url.lastPathComponent == "waveform.json")

        let original = WaveformData(duration: 12.5, peaks: [0.1, 0.9, 0.35])
        try original.write(to: url)
        let loaded = try #require(WaveformData.load(from: url))
        #expect(loaded == original)

        // Corrupt/unknown content is treated as missing (regenerate).
        try AtomicFile.write("{}", to: url)
        #expect(WaveformData.load(from: url) == nil)
        #expect(WaveformData.load(from: dir.appending(path: "absent.json")) == nil)
    }

    @Test func replacementPreviewSplicesTakePeaksWithoutChangingTimeline() {
        let original = WaveformData(
            peaksPerSecond: 2,
            duration: 5,
            peaks: [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4, 0.5, 0.5]
        )
        let take = WaveformData(peaksPerSecond: 2, duration: 2, peaks: [0.9, 0.8])

        let preview = original.previewReplacing(start: 1, end: 3, with: take)

        #expect(preview.duration == original.duration)
        #expect(preview.peaksPerSecond == original.peaksPerSecond)
        #expect(preview.peaks.count == original.peaks.count)
        #expect(preview.peaks == [0.1, 0.1, 0.9, 0.9, 0.8, 0.8, 0.4, 0.4, 0.5, 0.5])
        #expect(original.peaks[2] == 0.2)
    }
}
