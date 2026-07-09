import SwiftUI

/// Zen mode's live transcript: big readable text streaming in as you speak,
/// auto-following the newest words. Confirmed utterances render primary;
/// the still-decoding tail is dimmed.
struct ZenLiveTranscriptView: View {
    let transcriber: LiveTranscriber

    var body: some View {
        switch transcriber.status {
        case .idle:
            EmptyView()
        case .preparing(let fraction):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(preparingLabel(fraction))
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        case .listening:
            if transcriber.transcript.isEmpty {
                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        (Text(transcriber.transcript.confirmed)
                            + Text(transcriber.transcript.volatile)
                            .foregroundStyle(.secondary))
                            .font(.title3)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("live-end")
                    }
                    .onChange(of: transcriber.transcript) {
                        proxy.scrollTo("live-end", anchor: .bottom)
                    }
                }
                .frame(maxWidth: 640, maxHeight: 200)
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
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var content: some View {
        switch transcriber.status {
        case .idle:
            EmptyView()
        case .preparing:
            Text("Preparing live transcription…")
                .foregroundStyle(.secondary)
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
