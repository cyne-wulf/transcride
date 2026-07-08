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
