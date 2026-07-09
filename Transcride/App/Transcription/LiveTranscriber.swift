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

    /// True only while a recording is feeding audio. Model preparation may
    /// continue independently between recordings.
    var isSessionActive: Bool { session != nil }

    /// Parakeet EOU 120M, 160 ms chunks — lowest-latency variant, so words
    /// land on screen almost as they're spoken. Downloads lazily (~450 MB)
    /// into the same FluidAudio cache the batch models use.
    private let manager = StreamingEouAsrManager(chunkSize: .ms160)
    private var preparation: Task<PreparationOutcome, Never>?
    private var modelsReady = false
    private var session: Task<Void, Never>?
    private var feed: AsyncStream<LiveAudioChunk>.Continuation?
    private var confirmedText = ""
    private var sessionGeneration = 0

    private enum PreparationOutcome: Sendable {
        case ready
        case failed(String)
    }

    /// Plain-sample copy of one tap buffer — the only shape that can cross
    /// from the audio thread to the streaming actor under strict concurrency
    /// (an `AVAudioPCMBuffer` drags its shared `AVAudioFormat` along).
    private struct LiveAudioChunk: Sendable {
        var samples: [Float]
        var sampleRate: Double
    }

    /// Downloads and loads the streaming model independently of a recording.
    /// Entering Zen calls this while idle so a short recording cannot cancel
    /// the one-time model preparation before any words appear.
    func prepare() {
        guard !modelsReady, preparation == nil else { return }
        status = .preparing(nil)

        let manager = self.manager
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await manager.loadModels(to: nil, configuration: nil) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.applyPreparationProgress(snapshot.fractionCompleted)
                    }
                }
                return PreparationOutcome.ready
            } catch {
                return PreparationOutcome.failed(error.localizedDescription)
            }
        }
        preparation = task

        Task { [weak self] in
            let outcome = await task.value
            self?.finishPreparation(outcome)
        }
    }

    /// Starts a live session and returns the audio handler to hang on the
    /// recorder's tee. Never throws — problems surface through `status`.
    func begin() -> @Sendable (AVAudioPCMBuffer) -> Void {
        cancelAudioSession()
        prepare()
        status = .preparing(nil)
        transcript = LiveTranscript()
        confirmedText = ""

        let (stream, continuation) = AsyncStream.makeStream(of: LiveAudioChunk.self)
        feed = continuation
        let manager = self.manager
        let preparation = self.preparation
        sessionGeneration += 1
        let generation = sessionGeneration
        session = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if let preparation {
                    let outcome = await preparation.value
                    try Task.checkCancellation()
                    guard case .ready = outcome else {
                        await MainActor.run { [weak self] in
                            self?.preparationFailedSession(generation: generation)
                        }
                        return
                    }
                }
                await manager.reset()
                await manager.setPartialCallback { [weak self] partial in
                    Task { @MainActor [weak self] in
                        self?.applyPartial(partial, generation: generation)
                    }
                }
                await manager.setEouCallback { [weak self] confirmed in
                    Task { @MainActor [weak self] in
                        self?.applyConfirmed(confirmed, generation: generation)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.status = .listening
                    DebugLog.append("live transcription listening")
                }
                for await chunk in stream {
                    try Task.checkCancellation()
                    guard let buffer = Self.pcmBuffer(from: chunk) else { continue }
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                }
                _ = try? await manager.finish()
                await MainActor.run { [weak self] in
                    self?.sessionFinished(generation: generation)
                }
            } catch {
                await manager.reset()
                await MainActor.run { [weak self] in
                    self?.sessionFailed(error, generation: generation)
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
        guard session == nil, preparation == nil else { return }
        status = .unavailable(
            "Download the \(ModelCatalog.parakeetV3.displayName) model in "
                + "Settings → Transcription to see live transcription."
        )
        transcript = LiveTranscript()
    }

    /// Ends the display session immediately. The authoritative batch
    /// transcript takes over after stop; shared model preparation remains
    /// alive for the next recording.
    func end() {
        cancelAudioSession()
    }

    private func cancelAudioSession() {
        sessionGeneration += 1
        session?.cancel()
        session = nil
        feed?.finish()
        feed = nil
        transcript = LiveTranscript()
        confirmedText = ""
        if preparation != nil {
            status = .preparing(nil)
        } else if modelsReady {
            status = .idle
        }
    }

    private func applyPreparationProgress(_ fraction: Double) {
        guard !modelsReady, preparation != nil else { return }
        status = .preparing(fraction)
    }

    private func finishPreparation(_ outcome: PreparationOutcome) {
        preparation = nil
        switch outcome {
        case .ready:
            modelsReady = true
            if session == nil { status = .idle }
            DebugLog.append("live transcription model ready")
        case .failed(let message):
            modelsReady = false
            status = .unavailable("Live transcription is unavailable: \(message)")
            DebugLog.append("live transcription preparation failed: \(message)")
        }
    }

    private func preparationFailedSession(generation: Int) {
        guard sessionGeneration == generation else { return }
        session = nil
        feed?.finish()
        feed = nil
    }

    private func sessionFinished(generation: Int) {
        guard sessionGeneration == generation else { return }
        session = nil
        status = .idle
        transcript = LiveTranscript()
        confirmedText = ""
    }

    private func sessionFailed(_ error: Error, generation: Int) {
        guard sessionGeneration == generation else { return }
        session = nil
        feed?.finish()
        feed = nil
        if !(error is CancellationError) {
            status = .unavailable(
                "Live transcription is unavailable: \(error.localizedDescription)"
            )
            DebugLog.append("live transcription failed: \(error)")
        }
    }

    private func applyPartial(_ partial: String, generation: Int) {
        guard sessionGeneration == generation, status == .listening else { return }
        transcript = LiveTranscript.resolve(partial: partial, confirmed: confirmedText)
    }

    private func applyConfirmed(_ confirmed: String, generation: Int) {
        guard sessionGeneration == generation, status == .listening else { return }
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
