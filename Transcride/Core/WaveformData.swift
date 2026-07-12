import Foundation

/// The `waveform.json` peaks cache stored inside an entry folder.
///
/// Schema (version 1):
/// ```json
/// {
///   "version": 1,
///   "peaksPerSecond": 20,
///   "duration": 63.25,
///   "peaks": [0.021, 0.512, ...]
/// }
/// ```
/// `peaks[i]` is the maximum absolute sample value (0…1) over the i-th
/// window of `1 / peaksPerSecond` seconds of audio, mixed down to mono.
/// Values are rounded to 3 decimals to keep the JSON compact. The file is a
/// rebuildable cache: delete it and it is regenerated from the audio on the
/// next open.
struct WaveformData: Codable, Equatable, Sendable {
    static let fileName = "waveform.json"
    /// Canonical resolution for generated caches (~50 ms of audio per peak).
    static let standardPeaksPerSecond = 20

    var version: Int
    var peaksPerSecond: Int
    var duration: Double
    var peaks: [Float]

    init(peaksPerSecond: Int = WaveformData.standardPeaksPerSecond, duration: Double, peaks: [Float]) {
        self.version = 1
        self.peaksPerSecond = peaksPerSecond
        self.duration = duration
        self.peaks = peaks
    }

    static func url(inEntry entryURL: URL) -> URL {
        entryURL.appending(path: fileName)
    }

    /// Loads and validates the cache; nil when missing, unreadable, or from a
    /// future schema version (caller regenerates).
    static func load(from url: URL) -> WaveformData? {
        guard let data = try? Data(contentsOf: url),
              let wf = try? JSONDecoder().decode(WaveformData.self, from: data),
              wf.version == 1, wf.peaksPerSecond > 0, !wf.peaks.isEmpty else { return nil }
        return wf
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try AtomicFile.write(data, to: url)
    }

    /// Returns a display-only composite whose selected timeline interval uses
    /// peaks from a replacement take. The canonical cache is never mutated or
    /// written; the take is resampled to the exact number of timeline peak
    /// windows so the waveform remains duration preserving.
    func previewReplacing(
        start: Double, end: Double, with replacement: WaveformData
    ) -> WaveformData {
        guard duration > 0, peaksPerSecond > 0, !peaks.isEmpty,
              !replacement.peaks.isEmpty, end > start else { return self }
        let clampedStart = min(max(0, start), duration)
        let clampedEnd = min(max(clampedStart, end), duration)
        let startIndex = min(peaks.count, max(0, Int(floor(clampedStart * Double(peaksPerSecond)))))
        let endIndex = min(
            peaks.count,
            max(startIndex, Int(ceil(clampedEnd * Double(peaksPerSecond))))
        )
        let targetCount = endIndex - startIndex
        guard targetCount > 0 else { return self }

        var composite = peaks
        for offset in 0..<targetCount {
            let sourceIndex = min(
                replacement.peaks.count - 1,
                offset * replacement.peaks.count / targetCount
            )
            composite[startIndex + offset] = replacement.peaks[sourceIndex]
        }
        return WaveformData(
            peaksPerSecond: peaksPerSecond,
            duration: duration,
            peaks: composite
        )
    }
}

/// Downsampling for display: one value (0…1 of the view height) per drawn
/// bar. Each column averages its slice of peaks — aggregating with max
/// saturates on long files, where a single column spans hundreds of windows
/// of normal speech and virtually every column's max is ~1.0, rendering a
/// solid full-height block. Values are then normalized so the loudest column
/// fills the height; the 0.25 floor avoids amplifying pure noise to full
/// scale.
enum WaveformDisplay {
    static func columnValues(peaks: [Float], columns: Int) -> [Float] {
        guard columns > 0, !peaks.isEmpty else { return [] }
        var values = [Float](repeating: 0, count: columns)
        for column in 0..<columns {
            let start = column * peaks.count / columns
            let end = min(max(start + 1, (column + 1) * peaks.count / columns), peaks.count)
            var sum: Float = 0
            for index in start..<end { sum += peaks[index] }
            values[column] = sum / Float(end - start)
        }
        let scale = 1 / max(0.25, values.max() ?? 1)
        return values.map { min(1, $0 * scale) }
    }
}

/// Streaming peak accumulator: feed mono samples in any chunk sizes, get one
/// peak (max absolute value, clamped 0…1) per `samplesPerPeak` window. Used
/// both by the live recorder tap and the offline file generator so the two
/// always agree on the schema.
struct WaveformBuilder {
    let samplesPerPeak: Int
    private(set) var peaks: [Float] = []
    private var windowMax: Float = 0
    private var windowCount: Int = 0
    /// Total mono samples consumed.
    private(set) var sampleCount: Int64 = 0

    init(samplesPerPeak: Int) {
        precondition(samplesPerPeak > 0)
        self.samplesPerPeak = samplesPerPeak
    }

    init(sampleRate: Double, peaksPerSecond: Int = WaveformData.standardPeaksPerSecond) {
        self.init(samplesPerPeak: max(1, Int(sampleRate) / peaksPerSecond))
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > windowMax { windowMax = magnitude }
            windowCount += 1
            if windowCount == samplesPerPeak {
                emitWindow()
            }
        }
        sampleCount += Int64(samples.count)
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Flushes a trailing partial window (call once, at end of audio).
    mutating func finish() {
        if windowCount > 0 { emitWindow() }
    }

    private mutating func emitWindow() {
        peaks.append(Self.round3(min(1, windowMax)))
        windowMax = 0
        windowCount = 0
    }

    static func round3(_ value: Float) -> Float {
        (value * 1000).rounded() / 1000
    }
}
