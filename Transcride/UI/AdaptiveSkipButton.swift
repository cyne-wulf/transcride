import SwiftUI

/// A transport button whose interval and visible number follow the duration of
/// the currently loaded clip.
struct AdaptiveSkipButton: View {
    enum Direction {
        case backward
        case forward

        fileprivate var word: String {
            switch self {
            case .backward: "Back"
            case .forward: "Forward"
            }
        }

        fileprivate var baseSymbol: String {
            switch self {
            case .backward: "gobackward"
            case .forward: "goforward"
            }
        }
    }

    let player: PlayerService
    let direction: Direction
    let size: CGFloat

    @State private var hovering = false

    var body: some View {
        let seconds = player.skipIntervalSeconds
        let unit = seconds == 1 ? "second" : "seconds"
        let label = "\(direction.word) \(seconds) \(unit)"

        Button {
            switch direction {
            case .backward: player.skipBackward()
            case .forward: player.skipForward()
            }
        } label: {
            AdaptiveSkipIcon(
                baseSymbol: direction.baseSymbol,
                seconds: seconds,
                size: size
            )
            .foregroundStyle(.primary)
            .frame(width: size + 16, height: size + 14)
            .background(
                Circle()
                    .fill(.primary.opacity(hovering ? 0.08 : 0))
                    .frame(width: size + 14, height: size + 14)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AdaptiveSkipIcon: View {
    let baseSymbol: String
    let seconds: Int
    let size: CGFloat

    var body: some View {
        if seconds >= 5 {
            Image(systemName: "\(baseSymbol).\(seconds)")
                .font(.system(size: size))
        } else {
            ZStack {
                Image(systemName: baseSymbol)
                    .font(.system(size: size))
                Text("\(seconds)")
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
