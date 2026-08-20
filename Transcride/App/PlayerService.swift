import AVFoundation
import CoreAudio
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
    /// Media time the listener is currently hearing: `currentTime` less the
    /// output device's latency, which is a few milliseconds when wired and
    /// hundreds over Bluetooth. Karaoke highlighting reads this; the transport
    /// (scrubber, playhead label, seeks, ranges) stays on `currentTime`, which
    /// remains the single source of truth for where playback *is*.
    var highlightTime: Double {
        PlaybackLatencyCompensation.audibleTime(
            transport: currentTime,
            anchor: playbackAnchor,
            latency: outputLatency,
            rate: Double(speed),
            isPlaying: isPlaying
        )
    }
    var skipIntervalSeconds: Int {
        PlaybackSkipInterval.seconds(forClipDuration: duration)
    }
    var skipIntervalMenuLabel: String {
        let unit = skipIntervalSeconds == 1 ? "Second" : "Seconds"
        return "\(skipIntervalSeconds) \(unit)"
    }
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
    private var playbackRangeEndObserver: Any?
    private(set) var playbackRange: ClosedRange<Double>?
    private var silenceRouter = SilenceGapRouter()

    /// Media time of the last seek or resume. Nothing before it has reached the
    /// audio device yet, so latency compensation never rewinds past it.
    private var playbackAnchor: Double = 0
    private var outputLatency: TimeInterval = 0
    // Per-tick bookkeeping: nothing observes it, and it must not add
    // observation traffic at playback cadence.
    @ObservationIgnored private var ticksSinceLatencyRefresh = 0
    /// Set while a seek is in flight so pre-seek observer ticks are dropped.
    @ObservationIgnored private var pendingSeekTarget: Double?
    @ObservationIgnored private var pendingSeekGeneration = 0
    @ObservationIgnored private var ticksSincePendingSeek = 0

    /// An observed time this close to the pending target already reflects the
    /// seek, so the suppression can end without waiting for the callback.
    private static let seekSettleTolerance: Double = 0.05
    /// Backstop for a seek whose completion never fires and whose target the
    /// render clock never reaches: about a second of ticks, then resume.
    private static let pendingSeekTickLimit = 30
    /// Device latency changes when the user switches output (AirPods
    /// connecting mid-playback), so re-read it roughly every two seconds.
    private static let latencyRefreshTickInterval = 60

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
        refreshOutputLatency()

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
                guard seconds.isFinite, self.acceptsObservedTime(seconds) else { return }
                self.currentTime = seconds
                self.refreshOutputLatencyIfDue()
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
        removePlaybackRangeEndObserver()
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
        playbackRange = nil
        playbackAnchor = 0
        clearPendingSeek()
        ticksSinceLatencyRefresh = 0
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if let playbackRange {
            if currentTime < playbackRange.lowerBound
                || currentTime >= playbackRange.upperBound - 0.05 {
                seekInternally(to: playbackRange.lowerBound)
            }
        } else if duration > 0, currentTime >= duration - 0.05 {
            seekInternally(to: 0)
        }
        // Nothing before the resume point is in the device's buffers yet, and
        // the output may have changed while playback was stopped.
        playbackAnchor = currentTime
        refreshOutputLatency()
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

    /// Restricts transport and playback to a temporary audition range. Trim
    /// uses this to make Play represent the retained result, without changing
    /// the canonical audio or leaking the range into ordinary playback.
    func setPlaybackRange(start: Double, end: Double) {
        guard duration > 0 else { return }
        let lower = min(max(0, start), duration)
        let upper = min(max(lower, end), duration)
        guard upper - lower > 0.001 else {
            clearPlaybackRange()
            return
        }

        playbackRange = lower...upper
        installPlaybackRangeEndObserver(at: upper)
        if currentTime < lower || currentTime >= upper {
            seekInternally(to: lower)
        }
    }

    func clearPlaybackRange() {
        removePlaybackRangeEndObserver()
        playbackRange = nil
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
        let wholeFileClamped = min(max(0, seconds), duration > 0 ? duration : seconds)
        let clamped: Double
        if let playbackRange {
            clamped = min(max(playbackRange.lowerBound, wholeFileClamped), playbackRange.upperBound)
        } else {
            clamped = wholeFileClamped
        }
        currentTime = clamped
        playbackAnchor = clamped
        pendingSeekTarget = clamped
        ticksSincePendingSeek = 0
        pendingSeekGeneration &+= 1
        let generation = pendingSeekGeneration
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSeekGeneration == generation else { return }
                self.clearPendingSeek()
            }
        }
    }

    /// Observer ticks produced before an in-flight seek lands still carry the
    /// pre-seek position. Applying one snaps the karaoke highlight back to the
    /// word we just left — the visible flash around a silence skip or a word
    /// click — so they are dropped until the seek is known to have taken.
    private func acceptsObservedTime(_ seconds: Double) -> Bool {
        guard let target = pendingSeekTarget else { return true }
        ticksSincePendingSeek += 1
        guard abs(seconds - target) <= Self.seekSettleTolerance
                || ticksSincePendingSeek >= Self.pendingSeekTickLimit else { return false }
        clearPendingSeek()
        return true
    }

    private func clearPendingSeek() {
        pendingSeekTarget = nil
        ticksSincePendingSeek = 0
    }

    private func refreshOutputLatencyIfDue() {
        ticksSinceLatencyRefresh += 1
        guard ticksSinceLatencyRefresh >= Self.latencyRefreshTickInterval else { return }
        refreshOutputLatency()
    }

    private func refreshOutputLatency() {
        ticksSinceLatencyRefresh = 0
        let measured = Self.outputLatencySeconds()
        if measured != outputLatency { outputLatency = measured }
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func skipBackward() {
        skip(-Double(skipIntervalSeconds))
    }

    func skipForward() {
        skip(Double(skipIntervalSeconds))
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

    private func installPlaybackRangeEndObserver(at end: Double) {
        removePlaybackRangeEndObserver()
        guard let player else { return }
        playbackRangeEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
            queue: .main
        ) { [weak self, weak player] in
            Task { @MainActor [weak self, weak player] in
                guard let self, self.player === player,
                      let playbackRange = self.playbackRange else { return }
                player?.pause()
                self.isPlaying = false
                self.currentTime = playbackRange.upperBound
            }
        }
    }

    private func removePlaybackRangeEndObserver() {
        if let playbackRangeEndObserver, let player {
            player.removeTimeObserver(playbackRangeEndObserver)
        }
        playbackRangeEndObserver = nil
    }

    // MARK: - Output latency

    /// Latency of the current default output device, in seconds. AVPlayer's
    /// clock reports what has been handed to the device, so this is the only
    /// signal available for how long the device holds it before it is heard.
    /// Every read is best-effort: any failure returns 0, which is exactly the
    /// uncompensated behavior this replaces.
    private static func outputLatencySeconds() -> TimeInterval {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return 0 }

        var sampleRate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &rateAddress, 0, nil, &rateSize, &sampleRate
        ) == noErr, sampleRate > 0 else { return 0 }

        let frames = frameCount(deviceID, kAudioDevicePropertyLatency)
            + frameCount(deviceID, kAudioDevicePropertySafetyOffset)
            + frameCount(deviceID, kAudioDevicePropertyBufferFrameSize)
            + outputStreamLatencyFrames(deviceID)
        return Double(frames) / sampleRate
    }

    private static func frameCount(
        _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr else { return 0 }
        return value
    }

    /// Some devices report their real transport delay on the stream rather than
    /// the device, so the first output stream's latency is added too.
    private static func outputStreamLatencyFrames(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }
        var streams = [AudioStreamID](
            repeating: AudioStreamID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioStreamID>.size
        )
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &streams
        ) == noErr, let stream = streams.first,
              stream != AudioStreamID(kAudioObjectUnknown) else { return 0 }

        var value = UInt32(0)
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        var latencyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyLatency,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            stream, &latencyAddress, 0, nil, &valueSize, &value
        ) == noErr else { return 0 }
        return value
    }
}
