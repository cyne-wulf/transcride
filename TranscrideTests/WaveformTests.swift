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
}
