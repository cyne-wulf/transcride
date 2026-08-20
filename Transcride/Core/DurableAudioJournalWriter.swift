import AVFoundation
import Foundation

/// Writes the crash-tolerant microphone journal — Int16 little-endian PCM in a
/// CAF container, per `CrashTolerantAudioJournal.fileSettings` — through a file
/// descriptor the app owns, so the capture path can issue real durability
/// barriers. `AVAudioFile` never exposes its descriptor, which is why it cannot
/// bound what a power loss destroys: without `F_FULLFSYNC` the loss window is
/// whatever the page cache holds.
///
/// The header's data-chunk size is written as -1 ("extends to EOF" — legal for
/// the final chunk, and exactly what Core Audio's own writer leaves on disk
/// until close), so a journal severed at any byte remains readable: recovery
/// derives frames and duration from file size. `close()` patches the real size
/// in place for maximal tool compatibility of finished files; a patch severed
/// by power loss is undone by `repairDataChunkSize(at:)` before recovery reads
/// the file.
///
/// Threading: `write(from:)` is called from the audio tap callback and must
/// stay cheap — it performs one `write(2)` and never blocks on a barrier.
/// Barriers (`F_FULLFSYNC`, tens of milliseconds) run coalesced on a private
/// serial queue against the same descriptor, which is safe alongside `write(2)`
/// from another thread: a racing append simply rides the next barrier.
final class DurableAudioJournalWriter: @unchecked Sendable {
    /// The power-loss bound: how much recorded audio may sit between barriers.
    static let durabilityBarrierInterval: TimeInterval = 5

    /// Mono 44.1 kHz — fixed by `CrashTolerantAudioJournal.fileSettings`.
    private static let sampleRate = 44_100.0
    private static let bytesPerFrame = MemoryLayout<Int16>.size

    static let defaultBarrierIntervalBytes =
        Int(durabilityBarrierInterval * sampleRate) * bytesPerFrame

    /// Byte offset of the data chunk's size field: 8 (file header) + 12 (desc
    /// chunk header) + 32 (desc payload) + 4 (data chunk type). The payload's
    /// leading 4-byte `mEditCount` follows the 8-byte size, so audio begins at
    /// byte 68 and the patched size is `4 + audioBytes`.
    private static let dataChunkSizeOffset: off_t = 56
    static let headerByteCount = 68

    enum WriteError: Error {
        case unsupportedBufferFormat
        case ioFailed(errno: Int32)
    }

    let url: URL
    /// What the tap/normalizer must deliver: deinterleaved Float32 mono at the
    /// journal rate — identical to what `AVAudioFile.processingFormat` reported
    /// for the previous writer, so downstream consumers are unaffected.
    let processingFormat: AVAudioFormat

    private let descriptor: Int32
    private let barrierIntervalBytes: Int
    private let barrier: (Int32) -> FileDurability.AchievedLevel?
    private let barrierQueue = DispatchQueue(
        label: "transcride.journal.durability", qos: .utility
    )

    private let lock = NSLock()
    private var audioBytesWritten: Int = 0
    private var bytesSinceBarrier: Int = 0
    private var barrierPending = false
    private var closed = false
    private var conversionScratch: [Int16] = []
    private var degradedBelowFull = false

    /// True once any barrier — the initial one, a cadence barrier, or the
    /// close-time pair — achieved less than `F_FULLFSYNC`. Surfaced so the app
    /// layer can log that this volume cannot promise power-loss durability;
    /// tracked live because a volume that accepted the first barrier can still
    /// start failing mid-recording.
    var durabilityDegraded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return degradedBelowFull
    }

    var framesWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(audioBytesWritten / Self.bytesPerFrame)
    }

    init(
        url: URL,
        barrierIntervalBytes: Int = DurableAudioJournalWriter.defaultBarrierIntervalBytes,
        barrier: @escaping (Int32) -> FileDurability.AchievedLevel? = {
            FileDurability.barrier(fileDescriptor: $0)
        }
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WriteError.unsupportedBufferFormat
        }
        self.url = url
        self.processingFormat = format
        self.barrierIntervalBytes = max(1, barrierIntervalBytes)

        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard fd >= 0 else { throw WriteError.ioFailed(errno: errno) }
        self.descriptor = fd
        self.barrier = barrier

        do {
            try Self.writeFully(Self.header(), to: fd)
        } catch {
            closed = true
            _ = Darwin.close(fd)
            throw error
        }
        // The header and the file's very existence must survive power loss
        // from the first moment of a recording, or an early cut leaves nothing
        // discoverable for recovery.
        if FileDurability.barrier(fileDescriptor: fd) != .full {
            degradedBelowFull = true
        }
        FileDurability.syncDirectory(at: url.deletingLastPathComponent())
    }

    deinit {
        // Owners call close()/closeDiscarding(); this only prevents a leaked
        // descriptor if they never do.
        if !closed { _ = Darwin.close(descriptor) }
    }

    /// Appends one normalized capture buffer. Called from the tap thread,
    /// externally serialized by the recording sink's lock.
    func write(from buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 1,
              buffer.format.sampleRate == Self.sampleRate,
              let channel = buffer.floatChannelData?[0] else {
            throw WriteError.unsupportedBufferFormat
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        if conversionScratch.count < frameCount {
            conversionScratch = [Int16](repeating: 0, count: frameCount)
        }
        for index in 0..<frameCount {
            let sample = channel[index]
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            conversionScratch[index] = Int16((clamped * 32_767).rounded())
        }
        let byteCount = frameCount * Self.bytesPerFrame
        try conversionScratch.withUnsafeBytes { raw in
            try Self.writeFully(
                UnsafeRawBufferPointer(start: raw.baseAddress, count: byteCount),
                to: descriptor
            )
        }
        audioBytesWritten += byteCount
        bytesSinceBarrier += byteCount
        if bytesSinceBarrier >= barrierIntervalBytes {
            scheduleBarrierLocked()
        }
    }

    /// Requests an off-thread durability barrier soon — used at pause and
    /// system sleep, when the byte-driven trigger would otherwise stall with
    /// un-flushed tail audio.
    func scheduleDurabilityBarrier() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, bytesSinceBarrier > 0 else { return }
        scheduleBarrierLocked()
    }

    /// Final barrier, patch the real data-chunk size, release the descriptor.
    /// Idempotent. After this the file is a cleanly finished CAF.
    func close() {
        barrierQueue.sync {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            closed = true
            let chunkSize = Int64(4 + audioBytesWritten)
            lock.unlock()

            recordBarrierResult(barrier(descriptor))
            var bigEndian = chunkSize.bigEndian
            let patched = withUnsafeBytes(of: &bigEndian) { raw in
                Self.pwriteFully(raw, to: descriptor, at: Self.dataChunkSizeOffset)
            }
            if !patched {
                // A partially applied patch would declare a bogus positive
                // size, which AVFoundation trusts over physical EOF. Restore
                // the -1 sentinel so the file keeps the crash shape every
                // recovery consumer is built for.
                var sentinel = Int64(-1).bigEndian
                _ = withUnsafeBytes(of: &sentinel) { raw in
                    Self.pwriteFully(raw, to: descriptor, at: Self.dataChunkSizeOffset)
                }
            }
            recordBarrierResult(barrier(descriptor))
            _ = Darwin.close(descriptor)
        }
    }

    /// Restores the -1 ("extends to EOF") data-chunk size in a journal whose
    /// close-time patch was severed by power loss. A torn 8-byte patch leaves
    /// `0xFF` padding behind the applied prefix — a huge bogus positive size
    /// that `AVAudioFile` trusts over physical EOF, declaring up to quadrillions
    /// of frames. Recovery calls this before any consumer opens a journal.
    ///
    /// Only files carrying this writer's exact 56-byte header prefix are
    /// eligible; the field is rewritten only when it is neither the crash
    /// sentinel nor exactly what the file's physical length implies. Returns
    /// true when a repair was written.
    @discardableResult
    static func repairDataChunkSize(at url: URL) -> Bool {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR)
        }
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        let fileSize = Int64(status.st_size)
        guard fileSize >= Int64(headerByteCount) else { return false }

        let prefixLength = Int(dataChunkSizeOffset) + 8
        var prefix = [UInt8](repeating: 0, count: prefixLength)
        guard pread(fd, &prefix, prefixLength, 0) == prefixLength,
              prefix[..<Int(dataChunkSizeOffset)]
                  .elementsEqual(header().prefix(Int(dataChunkSizeOffset))) else {
            return false
        }
        let stored = prefix[Int(dataChunkSizeOffset)...]
            .reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        // mEditCount (4 bytes) plus the audio bytes physically present.
        let expected = fileSize - Int64(headerByteCount) + 4
        guard stored != -1, stored != expected else { return false }

        var sentinel = Int64(-1).bigEndian
        let repaired = withUnsafeBytes(of: &sentinel) { raw in
            pwriteFully(raw, to: fd, at: dataChunkSizeOffset)
        }
        if repaired { _ = FileDurability.barrier(fileDescriptor: fd) }
        return repaired
    }

    private func recordBarrierResult(_ level: FileDurability.AchievedLevel?) {
        guard level != .full else { return }
        lock.lock()
        degradedBelowFull = true
        lock.unlock()
    }

    private static func pwriteFully(
        _ bytes: UnsafeRawBufferPointer, to fd: Int32, at offset: off_t
    ) -> Bool {
        guard var base = bytes.baseAddress else { return true }
        var remaining = bytes.count
        var position = offset
        while remaining > 0 {
            let written = pwrite(fd, base, remaining, position)
            if written > 0 {
                base += written
                remaining -= written
                position += off_t(written)
            } else if errno != EINTR {
                return false
            }
        }
        return true
    }

    /// Releases the descriptor without a final barrier or size patch, leaving
    /// the on-disk bytes exactly as a crash would — the file stays readable to
    /// EOF with a -1 data-chunk size. For rejected startup attempts whose file
    /// is deleted immediately after (and, in tests, the crash simulator).
    func closeDiscarding() {
        barrierQueue.sync {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            _ = Darwin.close(descriptor)
        }
    }

    private func scheduleBarrierLocked() {
        guard !barrierPending else { return }
        barrierPending = true
        bytesSinceBarrier = 0
        barrierQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillOpen = !self.closed
            self.lock.unlock()
            if stillOpen { self.recordBarrierResult(self.barrier(self.descriptor)) }
            self.lock.lock()
            self.barrierPending = false
            self.lock.unlock()
        }
    }

    private static func writeFully(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { try writeFully($0, to: fd) }
    }

    private static func writeFully(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        guard var base = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let written = Darwin.write(fd, base, remaining)
            if written > 0 {
                base += written
                remaining -= written
            } else if errno != EINTR {
                throw WriteError.ioFailed(errno: errno)
            }
        }
    }

    /// The complete 68-byte header. CAF is a big-endian container — every
    /// header field below, including the Float64 sample rate's bit pattern, is
    /// big-endian — while the samples themselves are little-endian Int16, as
    /// declared by format flag bit 1 (`kCAFLinearPCMFormatFlagIsLittleEndian`).
    static func header() -> Data {
        var data = Data(capacity: headerByteCount)
        // File header: 'caff', version 1, flags 0.
        data.append(contentsOf: Array("caff".utf8))
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(0))
        // Audio Description chunk: fixed 32-byte payload.
        data.append(contentsOf: Array("desc".utf8))
        data.appendBigEndian(Int64(32))
        data.appendBigEndian(sampleRate.bitPattern)
        data.append(contentsOf: Array("lpcm".utf8))
        data.appendBigEndian(UInt32(2)) // format flags: little-endian, integer
        data.appendBigEndian(UInt32(bytesPerFrame)) // bytes per packet
        data.appendBigEndian(UInt32(1)) // frames per packet
        data.appendBigEndian(UInt32(1)) // channels per frame
        data.appendBigEndian(UInt32(16)) // bits per channel
        // Data chunk: size -1 = "to EOF", then the 4-byte mEditCount, then
        // audio. Legal only because no chunk ever follows.
        data.append(contentsOf: Array("data".utf8))
        data.appendBigEndian(Int64(-1))
        data.appendBigEndian(UInt32(0)) // mEditCount
        return data
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
