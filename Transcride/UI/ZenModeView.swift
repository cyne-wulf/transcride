import SwiftUI

/// REC-5: chrome-free full-window recording view — waveform, elapsed time,
/// pause/stop only (plus record when idle). Esc exits while idle and asks for
/// confirmation before discarding an active capture.
struct ZenModeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var recorder: RecorderService { model.recorder }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                VStack(spacing: compact ? 16 : 24) {
                    Spacer(minLength: compact ? 0 : 12)

                    Text(formatElapsed(recorder.elapsed))
                        .font(.system(
                            size: compact ? 48 : 56,
                            weight: .light
                        ).monospacedDigit())
                        .foregroundStyle(recorder.state == .idle ? .secondary : .primary)

                    LiveWaveformView(peaks: recorder.livePeaks)
                        .frame(height: compact ? 80 : 120)
                        .frame(maxWidth: 640)
                        .opacity(recorder.state == .recording ? 1 : 0.35)

                    // Reserve a real layout region for live text. Without an
                    // explicit height, this ScrollView was the first child
                    // SwiftUI collapsed in the app's compact window size.
                    ZenLiveTranscriptView(transcriber: model.liveTranscriber)
                        .frame(maxWidth: 640)
                        .frame(height: compact ? 120 : 180)

                    controls
                        .frame(height: 64)

                    Spacer(minLength: 0)

                    Text(escHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, compact ? 4 : 16)
                }
                .padding(compact ? 20 : 32)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            model.handleExitCommand()
            return .handled
        }
        .onExitCommand { model.handleExitCommand() }
        .onAppear {
            focused = true
            model.prepareLiveTranscription()
            model.updateLiveTranscription() // entering Zen mid-recording goes live too
        }
    }

    private var escHint: String {
        recorder.state == .idle
            ? "esc to leave zen mode"
            : "esc to cancel and discard the recording"
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            Button {
                Task { await model.startRecording() }
            } label: {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Start Recording")
        case .recording, .paused:
            HStack(spacing: 40) {
                Button {
                    recorder.state == .paused ? recorder.resume() : recorder.pause()
                } label: {
                    Image(systemName: recorder.state == .paused ? "record.circle" : "pause.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(recorder.state == .paused ? .red : .primary)
                }
                .buttonStyle(.plain)
                .help(recorder.state == .paused ? "Resume" : "Pause")

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.plain)
                .help("Stop and Save")
            }
        case .finalizing:
            ProgressView()
        }
    }
}
