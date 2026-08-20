import Foundation

/// Chooses a transport skip interval that stays useful across very short and
/// long recordings. The value is based on the clip's total duration and does
/// not change as playback advances.
enum PlaybackSkipInterval {
    static func seconds(forClipDuration duration: TimeInterval) -> Int {
        // AVPlayer reports an unresolved/zero duration briefly while loading.
        // Keep the former 15-second behavior until a real duration is known.
        guard duration.isFinite, duration > 0 else { return 15 }

        switch duration {
        case ..<5:
            return 1
        case ..<15:
            return 2
        case ..<20:
            return 3
        case ..<30:
            return 5
        case ..<60:
            return 10
        case ..<300:
            return 15
        case ..<600:
            return 30
        default:
            return 60
        }
    }
}

/// Converts the player's transport clock into the media time the listener is
/// actually hearing, so karaoke highlighting tracks the speakers rather than
/// the decoder.
///
/// The transport clock reports what has been handed to the audio device; the
/// device then holds it for its own latency (a few milliseconds when wired,
/// hundreds over Bluetooth) before it becomes sound. Playback that started or
/// seeked to `anchor` has nothing audible before `anchor`, which is what keeps
/// the compensation from yanking the highlight backwards at every seek.
enum PlaybackLatencyCompensation {
    /// Anything beyond this is treated as a nonsense device report rather than
    /// a reason to drag the highlight a second behind the voice.
    static let maximumLatency: TimeInterval = 1.0

    /// - Parameters:
    ///   - transport: the player's own clock (what has been rendered).
    ///   - anchor: media time of the last seek or resume; nothing earlier than
    ///     this has reached the device yet.
    ///   - latency: output device latency in wall-clock seconds.
    ///   - rate: playback rate, since one second of device latency covers
    ///     `rate` seconds of media time.
    ///   - isPlaying: paused playback has no pipeline to compensate for, and
    ///     the transport position is where Play will resume.
    static func audibleTime(
        transport: TimeInterval,
        anchor: TimeInterval,
        latency: TimeInterval,
        rate: Double,
        isPlaying: Bool
    ) -> TimeInterval {
        guard transport.isFinite else { return transport }
        guard isPlaying, latency.isFinite, latency > 0, rate.isFinite, rate > 0 else {
            return transport
        }
        let compensation = min(latency, maximumLatency) * rate
        let floor = anchor.isFinite ? max(0, min(anchor, transport)) : 0
        return max(floor, transport - compensation)
    }
}
