import SwiftUI

/// Always-visible strip at the bottom of the main window (REC-1): a record
/// button and mic quick-picker when idle; live waveform, elapsed time and
/// pause/stop while recording. The library stays fully usable throughout.
struct RecorderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppModel.PreferenceKey.preferredMicUID) private var preferredMicUID = ""
    @AppStorage(LiveTranscriber.enabledKey) private var liveTranscription = false

    private var recorder: RecorderService { model.recorder }
    private var isCaptureShelfVisible: Bool {
        recorder.state == .recording || recorder.state == .paused
    }

    var body: some View {
        Group {
            switch recorder.state {
            case .idle:
                HStack(spacing: 12) {
                    idleControls
                }
            case .recording, .paused:
                recordingControls
            case .finalizing:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                Text(recorder.extensionSession == nil
                        ? (isReplacementTake
                            ? "Finalizing replacement take…" : "Finalizing recording…")
                        : "Appending extension safely…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: isCaptureShelfVisible ? 184 : 56)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.28),
            value: isCaptureShelfVisible
        )
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("recorder-bar")
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
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(recorder.state == .paused ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                    Text(recorderLabel)
                        .foregroundStyle(.secondary)
                        .font(.callout.weight(.medium))
                }
                .frame(width: 112, alignment: .leading)

                Spacer(minLength: 12)

                Text(formatElapsed(recorder.elapsed))
                    .font(.title2.monospacedDigit())
                    .contentTransition(.numericText())
                    .frame(minWidth: 96, alignment: .trailing)

                if !isReplacementTake { pauseResumeButton }
                stopButton
                if !isReplacementTake { zenButton }
            }

            LiveWaveformView(peaks: recorder.livePeaks)
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                .opacity(recorder.state == .paused ? 0.42 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(recorder.state == .paused ? "Paused recording waveform" : "Live recording waveform")
                .accessibilityIdentifier("live-recording-waveform")
        }
    }

    private var recorderLabel: String {
        if isReplacementTake { return "Replacement Take" }
        if recorder.extensionSession != nil {
            return recorder.state == .paused ? "Extension Paused" : "Extending"
        }
        return recorder.state == .paused ? "Paused" : "Recording"
    }

    private var isReplacementTake: Bool {
        if case .replacementTake? = recorder.sessionTarget { return true }
        return false
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
            RecordingStopIndicator(
                isRecording: recorder.state == .recording,
                reduceMotion: reduceMotion
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReplacementTake ? "Stop Replacement Take Early" : "Stop and Save Recording")
        .accessibilityHint(isReplacementTake
            ? "Stops before the locked duration and keeps an incomplete take"
            : "Stops recording and saves it to the current vault")
        .accessibilityIdentifier("stop-recording-button")
        .help(isReplacementTake ? "Stop Early — keep as Incomplete Take" : "Stop and Save")
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

/// The active stop action doubles as the unmistakable recording indicator.
/// TimelineView owns no repeating task or timer, and automatically pauses when
/// capture stops or Reduce Motion is enabled. Paused recordings keep the same
/// clear stop affordance without implying that audio is still being captured.
private struct RecordingStopIndicator: View {
    let isRecording: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRecording || reduceMotion)) { context in
            let phase = isRecording && !reduceMotion
                ? (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.35) / 1.35)
                : 0
            let wave = (sin(phase * .pi * 2 - .pi / 2) + 1) / 2

            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(reduceMotion ? 0.5 : 0.18 + 0.32 * wave), lineWidth: 2)
                        .scaleEffect(reduceMotion ? 1.14 : 1.04 + 0.18 * wave)
                }

                Circle()
                    .fill(Color.red.opacity(isRecording ? 0.9 + 0.1 * wave : 0.78))

                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white)
                    .frame(width: 12, height: 12)
            }
            .frame(width: 34, height: 34)
        }
    }
}
