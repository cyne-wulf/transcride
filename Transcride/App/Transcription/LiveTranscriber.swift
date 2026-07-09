import AVFoundation
import FluidAudio
import Foundation
import Observation

/// Live transcription while recording (M3 addendum): words appear as they
/// are spoken, via FluidAudio's Parakeet EOU streaming model. The live text
/// is display-only feedback — when the recording stops, the batch pipeline
/// still produces the authoritative transcript. Every failure here degrades
/// to a status message; it can never affect the recording itself.
@MainActor
@Observable
final class LiveTranscriber {
    enum Status: Equatable {
        case idle
        /// Downloading (fraction) or loading the streaming model.
        case preparing(Double?)
        case listening
        case unavailable(String)
    }

    /// UserDefaults toggle for the main window; Zen mode ignores it and is
    /// always live when the model allows.
    static let enabledKey = "liveTranscriptionEnabled"

    private(set) var status: Status = .idle
    private(set) var transcript = LiveTranscript()

    /// Parakeet EOU 120M, 160 ms chunks — lowest-latency variant, so words
    /// land on screen almost as they're spoken. Downloads lazily (~450 MB)
    /// into the same FluidAudio cache the batch models use.
    private let manager = StreamingEouAsrManager(chunkSize: .ms160)
    private var session: Task<Void, Never>?
    private var feed: AsyncStream<LiveAudioChunk>.Continuation?
    private var confirmedText = ""

    /// Plain-sample copy of one tap buffer — the only shape that can cross
    /// from the audio thread to the streaming actor under strict concurrency
    /// (an `AVAudioPCMBuffer` drags its shared `AVAudioFormat` along).
    private struct LiveAudioChunk: Sendable {
        var samples: [Float]
        var sampleRate: Double
    }

    /// Starts a live session and returns the audio handler to hang on the
    /// recorder's tee. Never throws — problems surface through `status`.
    func begin() -> @Sendable (AVAudioPCMBuffer) -> Void {
        cancelSession()
        status = .preparing(nil)
        transcript = LiveTranscript()
        confirmedText = ""

        let (stream, continuation) = AsyncStream.makeStream(of: LiveAudioChunk.self)
        feed = continuation
        let manager = self.manager
        session = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                await manager.reset()
                try await manager.loadModels(to: nil, configuration: nil) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self, case .preparing = self.status else { return }
                        self.status = .preparing(snapshot.fractionCompleted)
                    }
                }
                await manager.setPartialCallback { [weak self] partial in
                    Task { @MainActor [weak self] in self?.applyPartial(partial) }
                }
                await manager.setEouCallback { [weak self] confirmed in
                    Task { @MainActor [weak self] in self?.applyConfirmed(confirmed) }
                }
                await MainActor.run { [weak self] in
                    guard let self, case .preparing = self.status else { return }
                    self.status = .listening
                }
                for await chunk in stream {
                    try Task.checkCancellation()
                    guard let buffer = Self.pcmBuffer(from: chunk) else { continue }
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                }
                _ = try? await manager.finish()
                await MainActor.run { [weak self] in self?.sessionFinished() }
            } catch {
                await manager.reset()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.feed?.finish()
                    self.feed = nil
                    if !(error is CancellationError) {
                        self.status = .unavailable(
                            "Live transcription is unavailable: \(error.localizedDescription)"
                        )
                        DebugLog.append("live transcription failed: \(error)")
                    }
                }
            }
        }

        return { @Sendable buffer in
            guard let chunk = Self.chunk(from: buffer) else { return }
            continuation.yield(chunk)
        }
    }

    /// Shown when live mode is wanted but the default model isn't on disk.
    func markModelMissing() {
        guard session == nil else { return }
        status = .unavailable(
            "Download the \(ModelCatalog.parakeetV3.displayName) model in "
                + "Settings → Transcription to see live transcription."
        )
        transcript = LiveTranscript()
    }

    /// Ends the session: drains buffered audio, finalizes, and clears the
    /// display. The batch transcript replaces the live text.
    func end() {
        feed?.finish()
        feed = nil
        if session == nil || status != .listening {
            cancelSession()
        }
    }

    private func cancelSession() {
        session?.cancel()
        session = nil
        feed?.finish()
        feed = nil
        status = .idle
        transcript = LiveTranscript()
        confirmedText = ""
    }

    private func sessionFinished() {
        session = nil
        status = .idle
        transcript = LiveTranscript()
        confirmedText = ""
    }

    private func applyPartial(_ partial: String) {
        guard status == .listening else { return }
        transcript = LiveTranscript.resolve(partial: partial, confirmed: confirmedText)
    }

    private func applyConfirmed(_ confirmed: String) {
        guard status == .listening else { return }
        confirmedText = confirmed
        transcript = LiveTranscript.resolve(
            partial: transcript.display.count > confirmed.count ? transcript.display : confirmed,
            confirmed: confirmed
        )
    }

    /// The tap's buffer is recycled by AVFAudio after the block returns, so
    /// the samples are copied out on the audio thread. Channel 0 only — the
    /// recording input is mono, and ghost text doesn't need a downmix.
    private nonisolated static func chunk(from buffer: AVAudioPCMBuffer) -> LiveAudioChunk? {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        return LiveAudioChunk(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            sampleRate: buffer.format.sampleRate
        )
    }

    /// Rebuilds a mono PCM buffer for the streaming engine (which resamples
    /// to its 16 kHz internally).
    private nonisolated static func pcmBuffer(from chunk: LiveAudioChunk) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ), let channel = buffer.floatChannelData?[0]
        else { return nil }
        chunk.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        return buffer
    }
}
