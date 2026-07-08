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

    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var loadFailed = false
    var speed: Float = 1.0 {
        didSet {
            if isPlaying { player?.rate = speed }
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    /// Loads `url` stopped at 0:00. Reloading the same URL is a no-op so the
    /// view can call this freely; pass a different URL (or `unload()`) to
    /// switch. `knownDuration` (from frontmatter) is shown until the asset
    /// reports its own.
    func load(url: URL, knownDuration: Double?) {
        guard url != self.url else { return }
        unload()
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
                if seconds.isFinite { self.currentTime = seconds }
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

    private func handlePlayedToEnd() {
        isPlaying = false
        if duration > 0 { currentTime = duration }
    }
}
