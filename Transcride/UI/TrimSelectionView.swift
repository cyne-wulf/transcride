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
    /// Dragging stays local to this overlay. Publishing through the bindings
    /// on every mouse event would invalidate PlaybackSection and redraw the
    /// full waveform repeatedly, which is visibly slow on long recordings.
    @State private var previewStart: Double?
    @State private var previewEnd: Double?
    @State private var regionDragBase: TrimSelection?

    private static let handleHitWidth: CGFloat = 28
    private static let visibleHandleWidth: CGFloat = 11

    private var displayedStart: Double { previewStart ?? start }
    private var displayedEnd: Double { previewEnd ?? end }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = x(forTime: displayedStart, width: width)
            let endX = x(forTime: displayedEnd, width: width)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.38))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(.black.opacity(0.38))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)
                selectionRegion(startX: startX, endX: endX, width: width)
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
        .transaction { $0.animation = nil }
    }

    private func x(forTime time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    private func selectionRegion(startX: CGFloat, endX: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.11))
            .frame(width: max(4, endX - startX))
            .contentShape(Rectangle())
            .offset(x: startX)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0, duration > 0 else { return }
                        let base = regionDragBase
                            ?? TrimSelection(start: displayedStart, end: displayedEnd)
                        regionDragBase = base
                        let delta = Double(value.translation.width / width) * duration
                        let nextStart = min(max(0, base.start + delta), max(0, duration - base.length))
                        previewStart = nextStart
                        previewEnd = nextStart + base.length
                    }
                    .onEnded { _ in
                        if let previewStart, let previewEnd {
                            start = previewStart
                            end = previewEnd
                        }
                        previewStart = nil
                        previewEnd = nil
                        regionDragBase = nil
                    }
            )
            .help("Drag to move the selected range without changing its length")
            .accessibilityLabel("Move trim selection")
    }

    private func handle(atX xPosition: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        ZStack(alignment: isStart ? .leading : .trailing) {
            Color.clear
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.yellow)
                .frame(width: Self.visibleHandleWidth)
                .overlay {
                    Capsule()
                        .fill(.black.opacity(0.55))
                        .frame(width: 2, height: 19)
                }
                .padding(.vertical, 3)
        }
            .frame(width: Self.handleHitWidth)
            .contentShape(Rectangle())
            // Keep the entire handle inside the clipped waveform shelf: the
            // start tab grows rightward and the end tab grows leftward.
            .offset(x: isStart ? xPosition : xPosition - Self.handleHitWidth)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0, duration > 0 else { return }
                        let base = dragBaseTime ?? (isStart ? start : end)
                        dragBaseTime = base
                        let proposed = base + Double(value.translation.width / width) * duration
                        if isStart {
                            previewStart = min(
                                max(0, proposed), displayedEnd - TrimSelection.minimumKeptSeconds
                            )
                        } else {
                            previewEnd = max(
                                min(duration, proposed), displayedStart + TrimSelection.minimumKeptSeconds
                            )
                        }
                    }
                    .onEnded { _ in
                        if isStart, let previewStart { start = previewStart }
                        if !isStart, let previewEnd { end = previewEnd }
                        previewStart = nil
                        previewEnd = nil
                        dragBaseTime = nil
                    }
            )
            .help(isStart ? "Drag to set where the kept audio starts"
                          : "Drag to set where the kept audio ends")
            .accessibilityLabel(isStart ? "Trim start handle" : "Trim end handle")
    }
}
