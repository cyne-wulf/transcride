import SwiftUI

/// Zen mode's live transcript: big readable text streaming in as you speak,
/// auto-following the newest words. Confirmed utterances render primary;
/// the still-decoding tail is dimmed.
struct ZenLiveTranscriptView: View {
    let transcriber: LiveTranscriber

    /// The visible box is 640 × 200 at `.title3` — roughly 8 lines of ~85
    /// characters. Rendering the whole session instead makes every partial
    /// (~6/s) re-lay out an O(session) string on the main actor, so the text
    /// is windowed to a few viewports of scrollback: what is on screen is
    /// identical, the layout cost is constant.
    private static let windowCharacters = 4000

    var body: some View {
        switch transcriber.status {
        case .idle:
            Text("Live transcription ready")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("zen-live-transcript-ready")
        case .preparing(let fraction):
            VStack(spacing: 8) {
                if let fraction, fraction > 0, fraction < 1 {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(preparingLabel(fraction))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("zen-live-transcript-preparing")
        case .unavailable(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .accessibilityIdentifier("zen-live-transcript-unavailable")
        case .listening:
            if transcriber.transcript.isEmpty {
                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("zen-live-transcript-listening")
            } else {
                let windowed = transcriber.transcript.tail(Self.windowCharacters)
                ScrollViewReader { proxy in
                    ScrollView {
                        (Text(windowed.confirmed)
                            + Text(windowed.volatile)
                            .foregroundStyle(.secondary))
                            .font(.title3)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("zen-live-end")
                    }
                    .defaultScrollAnchor(.bottom)
                    // Run after the new text has participated in layout.
                    // `onChange` fired in the same update transaction and
                    // often scrolled using the previous content height.
                    .task(id: windowed) {
                        try? await Task.sleep(for: .milliseconds(20))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo("zen-live-end", anchor: .bottom)
                    }
                }
                .frame(maxWidth: 640, maxHeight: 200)
                .accessibilityIdentifier("zen-live-transcript-text")
            }
        }
    }

    private func preparingLabel(_ fraction: Double?) -> String {
        guard let fraction, fraction > 0, fraction < 1 else {
            return "Preparing live transcription…"
        }
        return "Preparing live transcription… \(Int(fraction * 100))%"
    }
}

/// Main-window companion to the recorder bar: a one-strip ticker of the
/// newest live words while recording with live transcription on.
struct LiveTranscriptStrip: View {
    let transcriber: LiveTranscriber

    var body: some View {
        if transcriber.status != .idle {
            HStack(spacing: 10) {
                statusIcon
                content
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// Turns amber only when live transcription fell behind far enough to
    /// skip audio. Display-only feedback: the recording keeps every sample.
    @ViewBuilder
    private var statusIcon: some View {
        if transcriber.isAudioBacklogDropping {
            Image(systemName: "waveform.and.mic")
                .foregroundStyle(.orange)
                .help("Live text skipped ahead to keep up. The recording is unaffected.")
        } else {
            Image(systemName: "waveform.and.mic")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch transcriber.status {
        case .idle:
            EmptyView()
        case .preparing(let fraction):
            Text("Preparing live transcription…")
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            if let fraction, fraction > 0, fraction < 1 {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
            } else {
                ProgressView().controlSize(.small)
            }
        case .unavailable(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .listening:
            if transcriber.transcript.isEmpty {
                Text("Listening…").foregroundStyle(.tertiary)
            } else {
                let tail = transcriber.transcript.tail(220)
                (Text(tail.confirmed)
                    + Text(tail.volatile).foregroundStyle(.secondary))
                    .lineLimit(2)
            }
        }
    }
}
