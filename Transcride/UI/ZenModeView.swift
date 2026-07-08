import SwiftUI

/// REC-5: chrome-free full-window recording view — waveform, elapsed time,
/// pause/stop only (plus record when idle). Esc exits once recording is
/// stopped; while recording, Esc is ignored so it can't be dismissed by
/// accident mid-take.
struct ZenModeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var recorder: RecorderService { model.recorder }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Spacer()

                Text(formatElapsed(recorder.elapsed))
                    .font(.system(size: 56, weight: .light).monospacedDigit())
                    .foregroundStyle(recorder.state == .idle ? .secondary : .primary)

                LiveWaveformView(peaks: recorder.livePeaks)
                    .frame(height: 120)
                    .frame(maxWidth: 640)
                    .opacity(recorder.state == .recording ? 1 : 0.35)

                controls
                    .frame(height: 64)

                Spacer()

                Text(escHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 16)
            }
            .padding(32)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            exitIfStopped()
            return .handled
        }
        .onExitCommand { exitIfStopped() }
        .onAppear { focused = true }
    }

    private var escHint: String {
        recorder.state == .idle
            ? "esc to leave zen mode"
            : "stop the recording, then esc to leave"
    }

    private func exitIfStopped() {
        if recorder.state == .idle { recorder.isZenMode = false }
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
