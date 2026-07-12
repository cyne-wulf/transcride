import AVFoundation
import Foundation
import Observation

/// Audio playback for the detail view. AVPlayer-based so imported mp4/mov
/// videos play their audio track too. Speed changes are pitch-preserved
/// (time-domain algorithm, tuned for speech).
@MainActor
@Observable
final class PlayerService {
    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
    static let skipSilencePreferenceKey = "skipSilence"

    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var loadFailed = false
    /// Incremented by user-driven seeks (word clicks, waveform scrubs and
    /// transport skips). Transcript views use it to resume auto-follow.
    private(set) var seekRevision = 0
    var skipSilence: Bool {
        didSet { UserDefaults.standard.set(skipSilence, forKey: Self.skipSilencePreferenceKey) }
    }
    /// Session-scoped looping for the currently loaded audio. This is not a
    /// persisted preference: relaunching the app always returns to normal
    /// one-shot playback.
    var loopAudio = false
    var speed: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = speed }
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var silenceRouter = SilenceGapRouter()

    init() {
        skipSilence = UserDefaults.standard.bool(forKey: Self.skipSilencePreferenceKey)
    }

    var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    /// Loads `url` stopped at 0:00. Reloading the same URL is a no-op so the
    /// view can call this freely; pass a different URL (or `unload()`) to
    /// switch. `knownDuration` (from frontmatter) is shown until the asset
    /// reports its own.
    func load(url: URL, knownDuration: Double?) {
        guard url != self.url else { return }
        // The detail task may load transcript timing just before the playback
        // task loads its asset. Keep those prepared gaps across this reset.
        let preparedSilenceRouter = silenceRouter
        unload()
        silenceRouter = preparedSilenceRouter
        self.url = url

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        duration = knownDuration ?? 0

        Task { [weak self] in
            if let loaded = try? await item.asset.load(.duration).seconds,
               loaded.isFinite, loaded > 0 {
                if self?.player === player { self?.duration = loaded }
            } else if knownDuration == nil {
                if self?.player === player { self?.loadFailed = true }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if self.isPlaying, self.skipSilence,
                   self.silenceRouter.selectedSourceIsReady,
                   let destination = SilenceGap.skipDestination(
                       at: seconds, in: self.silenceRouter.activeGaps
                   ),
                   destination - seconds > 0.01 {
                    self.seekInternally(to: destination)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.handlePlayedToEnd() }
        }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        url = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadFailed = false
        speed = 1.0
        silenceRouter.clear()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.rate = speed
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(toFraction fraction: Double) {
        seek(to: fraction * duration)
    }

    func seek(to seconds: Double) {
        seekRevision &+= 1
        seekInternally(to: seconds)
    }

    var silenceDetectionMode: SilenceDetectionMode { silenceRouter.mode }
    var silenceDetectionSourceIsReady: Bool { silenceRouter.selectedSourceIsReady }

    /// Selects the exact source for this entry and clears all sources when the
    /// entry identity changes. There is deliberately no cross-mode fallback.
    func configureSilenceDetection(entryID: String, mode: SilenceDetectionMode) {
        silenceRouter.configure(entryID: entryID, mode: mode)
    }

    /// Installs validated timing gaps only for the entry whose async detail
    /// load is still current. Duration enables leading/trailing detection.
    func setTranscriptForSilenceSkipping(
        _ transcript: TranscriptOriginal?,
        duration: TimeInterval? = nil,
        availability: SpeechTranscriptAvailability,
        entryID: String
    ) {
        let gaps: [SilenceGap]?
        if availability == .available, let transcript, let duration {
            gaps = try? SpeechSilencePlanner.makePlan(
                transcript: transcript, audioDuration: duration
            ).removedIntervals.map {
                SilenceGap(start: $0.start, end: $0.end, previousWordIndex: 0, nextWordIndex: 0)
            }
        } else {
            gaps = nil
        }
        silenceRouter.installSpeech(gaps, forEntryID: entryID)
    }

    /// Installs amplitude-derived gaps from the decoded audio waveform. These
    /// take precedence over transcript timing so non-speech audio is not
    /// mistaken for silence. Passing nil restores the transcript fallback.
    func setWaveformForSilenceSkipping(_ waveform: WaveformData, entryID: String) {
        silenceRouter.installWaveform(
            SilenceGap.compute(from: waveform), forEntryID: entryID
        )
    }

    private func seekInternally(to seconds: Double) {
        guard let player else { return }
        let clamped = min(max(0, seconds), duration > 0 ? duration : seconds)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    /// Steps to the adjacent entry in `speeds`; +1 faster, -1 slower
    /// (the [ and ] shortcuts). Clamps at the ends of the list.
    func stepSpeed(_ direction: Int) {
        guard let index = Self.speeds.firstIndex(of: speed) else {
            speed = 1.0
            return
        }
        speed = Self.speeds[min(max(index + direction, 0), Self.speeds.count - 1)]
    }

    private func handlePlayedToEnd() {
        if loopAudio, let player {
            seekInternally(to: 0)
            player.rate = speed
            isPlaying = true
            return
        }
        isPlaying = false
        if duration > 0 { currentTime = duration }
    }
}
