import SwiftUI

/// Always-visible strip at the bottom of the main window (REC-1): a record
/// button and mic quick-picker when idle; live waveform, elapsed time and
/// pause/stop while recording. The library stays fully usable throughout.
struct RecorderBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.PreferenceKey.preferredMicUID) private var preferredMicUID = ""
    @AppStorage(LiveTranscriber.enabledKey) private var liveTranscription = false

    private var recorder: RecorderService { model.recorder }

    var body: some View {
        HStack(spacing: 12) {
            switch recorder.state {
            case .idle:
                idleControls
            case .recording, .paused:
                recordingControls
            case .finalizing:
                ProgressView().controlSize(.small)
                Text("Finalizing recording…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 56)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .alert(
            "Recording Problem",
            isPresented: Binding(
                get: { recorder.alertMessage != nil },
                set: { if !$0 { recorder.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.alertMessage ?? "")
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleControls: some View {
        recordButton
        micPicker
        Spacer()
        liveToggle
        zenButton
    }

    /// M3 addendum: opt-in live transcription for main-window recordings
    /// (Zen mode is always live and ignores this).
    private var liveToggle: some View {
        Toggle("Live transcription", isOn: $liveTranscription)
            .toggleStyle(.checkbox)
            .foregroundStyle(.secondary)
            .onChange(of: liveTranscription) {
                if liveTranscription {
                    model.prepareLiveTranscription()
                    model.updateLiveTranscription()
                }
            }
            .help("Show words as you speak while recording (Parakeet, on-device)")
    }

    private var recordButton: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Start Recording")
    }

    private var micPicker: some View {
        Menu {
            Picker("Microphone", selection: $preferredMicUID) {
                Text("System Default").tag("")
                ForEach(model.inputDevices.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic")
                Text(selectedMicName)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Microphone used for new recordings")
    }

    private var selectedMicName: String {
        guard !preferredMicUID.isEmpty else { return "System Default" }
        return model.inputDevices.device(forUID: preferredMicUID)?.name
            ?? "System Default (device unavailable)"
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.state == .paused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
            Text(recorder.state == .paused ? "Paused" : "Recording")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(width: 100, alignment: .leading)

        LiveWaveformView(peaks: recorder.livePeaks)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .opacity(recorder.state == .paused ? 0.4 : 1)

        Text(formatElapsed(recorder.elapsed))
            .font(.title3.monospacedDigit())
            .frame(minWidth: 76, alignment: .trailing)

        pauseResumeButton
        stopButton
        zenButton
    }

    private var pauseResumeButton: some View {
        Button {
            recorder.state == .paused ? recorder.resume() : recorder.pause()
        } label: {
            Image(systemName: recorder.state == .paused ? "record.circle" : "pause.circle")
                .font(.system(size: 24))
                .foregroundStyle(recorder.state == .paused ? .red : .primary)
        }
        .buttonStyle(.plain)
        .help(recorder.state == .paused ? "Resume Recording" : "Pause Recording")
    }

    private var stopButton: some View {
        Button {
            Task { await model.stopRecording() }
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 24))
        }
        .buttonStyle(.plain)
        .help("Stop and Save")
    }

    private var zenButton: some View {
        Button {
            recorder.isZenMode = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .help("Zen Mode (Z) — a distraction-free recording view")
    }
}
