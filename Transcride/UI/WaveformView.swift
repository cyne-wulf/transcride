import SwiftUI

/// Scrubbable waveform for playback (PLY-3): full file rendered as centered
/// bars, played portion tinted, playhead line, drag anywhere to scrub.
///
/// The bars are drawn in two identical Canvas layers (base + accent) with the
/// accent layer masked to the played width. Canvas may redraw as the playhead
/// moves, so both layers consume cached column means instead of rescanning the
/// full peak array on every frame.
struct WaveformView: View {
    var displayCache: WaveformDisplayCache
    /// 0…1 played fraction.
    var progress: Double
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                bars(color: .secondary.opacity(0.45))
                bars(color: .accentColor)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, width * progress))
                    }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5)
                    .offset(x: max(0, min(width - 1.5, width * progress)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        onScrub(min(1, max(0, value.location.x / width)))
                    }
            )
        }
    }

    private func bars(color: Color) -> some View {
        Canvas { context, size in
            Self.drawBars(cache: displayCache, context: &context, size: size, color: color)
        }
    }

    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1

    /// One bar per (barWidth+barGap) column; bar heights come from
    /// the prefix-sum display cache (mean per column, loudest column fills the
    /// height — see `WaveformDisplay` for why max-aggregation is wrong).
    static func drawBars(
        cache: WaveformDisplayCache,
        context: inout GraphicsContext,
        size: CGSize,
        color: Color
    ) {
        guard cache.peakCount > 0, size.width > 0, size.height > 0 else { return }
        let step = barWidth + barGap
        let columns = max(1, Int(size.width / step))
        let values = cache.columnValues(columns: columns)
        let midY = size.height / 2

        var path = Path()
        for column in 0..<columns {
            let barHeight = max(2, CGFloat(values[column]) * size.height)
            path.addRoundedRect(
                in: CGRect(
                    x: CGFloat(column) * step,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                ),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        context.fill(path, with: .color(color))
    }
}

/// Scrolling live waveform while recording (REC-2): the most recent
/// `windowSeconds` of peaks, right-aligned, newest at the right edge.
struct LiveWaveformView: View {
    /// Tail of live peaks, newest last (canonical resolution).
    var peaks: [Float]
    var peaksPerSecond: Int = WaveformData.standardPeaksPerSecond
    var windowSeconds: Double = 8
    var color: Color = .red

    var body: some View {
        Canvas { context, size in
            let step = WaveformView.barWidth + WaveformView.barGap
            let visibleCount = Int(windowSeconds * Double(peaksPerSecond))
            let tail = peaks.suffix(visibleCount)
            guard !tail.isEmpty else { return }
            let midY = size.height / 2
            let pointsPerPeak = size.width / CGFloat(visibleCount)

            var path = Path()
            var x = size.width - CGFloat(tail.count) * pointsPerPeak
            for peak in tail {
                let barHeight = max(2, CGFloat(min(1, peak * 2.5)) * size.height)
                if pointsPerPeak >= step * 0.75 {
                    path.addRoundedRect(
                        in: CGRect(
                            x: x, y: midY - barHeight / 2,
                            width: WaveformView.barWidth, height: barHeight
                        ),
                        cornerSize: CGSize(width: 1, height: 1)
                    )
                } else {
                    path.addRect(CGRect(x: x, y: midY - barHeight / 2, width: 1, height: barHeight))
                }
                x += pointsPerPeak
            }
            context.fill(path, with: .color(color))
        }
    }
}

/// Elapsed-time text for the recorder: `0:07.4`, `12:34.5`, `1:02:03.4`.
func formatElapsed(_ seconds: Double) -> String {
    let total = Int(seconds)
    let tenths = Int((seconds - Double(total)) * 10)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d.%d", h, m, s, tenths) }
    return String(format: "%d:%02d.%d", m, s, tenths)
}
