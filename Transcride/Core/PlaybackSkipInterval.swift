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
