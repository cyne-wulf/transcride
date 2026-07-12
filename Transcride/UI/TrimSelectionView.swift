import SwiftUI

/// Trim-mode overlay for the playback waveform (AUD-3): the kept range stays
/// bright inside a bordered window with draggable edge handles, Voice Memos
/// style; the discarded portions are dimmed. Times are seconds into the audio.
struct AudioRangeSelectionOverlay: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double

    private struct GesturePreview: Equatable {
        var interaction: AudioRangeSelectionPointerInteraction
        var currentX: Double

        var selection: AudioRangeSelection {
            interaction.selection(at: currentX)
        }
    }

    /// GestureState resets automatically on completion and cancellation. This
    /// prevents an interrupted pointer sequence from stranding a drag base and
    /// making later handle or region drags appear frozen.
    @GestureState private var gesturePreview: GesturePreview?

    var purpose: Purpose = .trim
    var isLocked = false
    var onSeek: ((Double) -> Void)?

    enum Purpose {
        case trim
        case replace

        var noun: String { self == .trim ? "trim" : "replacement" }
    }

    private static let handleHitWidth: CGFloat = 28
    private static let visibleHandleWidth: CGFloat = 11

    private var displayedStart: Double {
        gesturePreview?.selection.start ?? start
    }

    private var displayedEnd: Double {
        gesturePreview?.selection.end ?? end
    }

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
                selectionRegion(startX: startX, endX: endX)
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.yellow, lineWidth: 2)
                    .frame(width: max(4, endX - startX))
                    .offset(x: startX)
                if !isLocked {
                    handle(atX: startX, isLeading: true)
                    handle(atX: endX, isLeading: false)
                }
            }
            // Offsets change where the selection and handles are drawn, but
            // they do not contribute to a ZStack's layout bounds. Without an
            // explicit full-width frame, the parent gesture's hit-test surface
            // can stop around the middle of the waveform even while the right
            // edge and handle remain visibly drawn beyond it.
            .frame(
                width: width,
                height: geometry.size.height,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .gesture(pointerGesture(width: width))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trim-selection-overlay")
        .transaction { $0.animation = nil }
    }

    private func x(forTime time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    private func selectionRegion(startX: CGFloat, endX: CGFloat) -> some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.11))
            .frame(width: max(4, endX - startX))
            .offset(x: startX)
            .help("Drag to move the selected range without changing its length")
            .accessibilityLabel("Move \(purpose.noun) selection")
    }

    private func handle(atX xPosition: CGFloat, isLeading: Bool) -> some View {
        ZStack(alignment: isLeading ? .leading : .trailing) {
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
            .offset(x: isLeading ? xPosition : xPosition - Self.handleHitWidth)
            .help(isLeading
                ? "Drag to set where the \(purpose.noun) starts"
                : "Drag to set where the \(purpose.noun) ends")
            .accessibilityLabel(isLeading
                ? "\(purpose.noun.capitalized) start handle"
                : "\(purpose.noun.capitalized) end handle")
    }

    private func pointerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($gesturePreview) { value, preview, _ in
                guard let interaction = interaction(for: value.startLocation.x, width: width) else {
                    preview = nil
                    return
                }
                preview = GesturePreview(
                    interaction: interaction,
                    currentX: Double(value.location.x)
                )
            }
            .onChanged { value in
                guard let interaction = interaction(for: value.startLocation.x, width: width),
                      interaction.target == .waveform,
                      let fraction = interaction.seekFraction(at: Double(value.location.x)) else {
                    return
                }
                onSeek?(fraction)
            }
            .onEnded { value in
                guard let interaction = interaction(for: value.startLocation.x, width: width) else {
                    return
                }
                let currentX = Double(value.location.x)
                switch interaction.target {
                case .firstHandle, .secondHandle:
                    if interaction.isDrag(at: currentX) {
                        commit(interaction.selection(at: currentX))
                    } else if let fraction = interaction.seekFraction(at: currentX) {
                        onSeek?(fraction)
                    }
                case .region:
                    if interaction.isDrag(at: currentX) {
                        commit(interaction.selection(at: currentX))
                    } else if let fraction = interaction.seekFraction(at: currentX) {
                        onSeek?(fraction)
                    }
                case .waveform:
                    if let fraction = interaction.seekFraction(at: currentX) {
                        onSeek?(fraction)
                    }
                }
            }
    }

    private func interaction(
        for pointerDownX: CGFloat, width: CGFloat
    ) -> AudioRangeSelectionPointerInteraction? {
        guard width > 0, duration > 0 else { return nil }
        return AudioRangeSelectionPointerInteraction(
            selection: AudioRangeSelection(start: start, end: end),
            duration: duration,
            width: Double(width),
            pointerDownX: Double(pointerDownX),
            handleHitWidth: Double(Self.handleHitWidth),
            isLocked: isLocked
        )
    }

    private func commit(_ selection: AudioRangeSelection) {
        start = selection.start
        end = selection.end
    }
}

typealias TrimSelectionOverlay = AudioRangeSelectionOverlay
