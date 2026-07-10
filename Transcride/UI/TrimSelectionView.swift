import SwiftUI

/// Trim-mode overlay for the playback waveform (AUD-3): the kept range stays
/// bright inside a bordered window with draggable edge handles, Voice Memos
/// style; the discarded portions are dimmed. Times are seconds into the audio.
struct TrimSelectionOverlay: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double

    /// Time (seconds) under the active handle when its drag began. Cumulative
    /// drag translations apply against this, not the live value — combining a
    /// rebuilt handle position with a cumulative translation double-counts.
    @State private var dragBaseTime: Double?

    private static let handleHitWidth: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = x(forTime: start, width: width)
            let endX = x(forTime: end, width: width)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.38))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(.black.opacity(0.38))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.yellow, lineWidth: 2)
                    .frame(width: max(4, endX - startX))
                    .offset(x: startX)
                handle(atX: startX, width: width, isStart: true)
                handle(atX: endX, width: width, isStart: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trim-selection-overlay")
    }

    private func x(forTime time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    private func handle(atX xPosition: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 5)
            .padding(.vertical, 1)
            .frame(width: Self.handleHitWidth)
            .contentShape(Rectangle())
            .offset(x: xPosition - Self.handleHitWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0, duration > 0 else { return }
                        let base = dragBaseTime ?? (isStart ? start : end)
                        dragBaseTime = base
                        let proposed = base + Double(value.translation.width / width) * duration
                        if isStart {
                            start = min(max(0, proposed), end - TrimSelection.minimumKeptSeconds)
                        } else {
                            end = max(min(duration, proposed), start + TrimSelection.minimumKeptSeconds)
                        }
                    }
                    .onEnded { _ in dragBaseTime = nil }
            )
            .help(isStart ? "Drag to set where the kept audio starts"
                          : "Drag to set where the kept audio ends")
    }
}
