import SwiftUI

/// Custom About window: real version, engine credits with their licenses,
/// and the product promise (plain files, local-only) stated where a curious
/// user will actually look for it.
struct AboutCommands: Commands {
    static let windowID = "about"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Transcride") {
                openWindow(id: Self.windowID)
            }
        }
    }
}

struct AboutView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var receivesEscape: Bool

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 3) {
                Text("Transcride")
                    .font(.title.weight(.semibold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("A zen voice recorder and transcription workbench. The audio is the draft; the transcript is the artifact.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)

            Divider()
                .frame(width: 260)

            VStack(spacing: 5) {
                Text("Transcription runs entirely on this Mac, powered by:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                creditRow("FluidAudio", detail: "Parakeet ASR & speaker diarization · Apache License 2.0")
                creditRow("WhisperKit", detail: "Whisper models by Argmax · MIT License")
                creditRow("Apple Speech", detail: "SpeechTranscriber on macOS 26+")
            }

            Text("Your vault stays yours: every note and recording is a plain file on disk, readable without this app.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)

            Text("© 2026 Ashan Devine")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .frame(width: 420)
        .focusable()
        .focusEffectDisabled()
        .focused($receivesEscape)
        .onKeyPress(.escape) {
            dismissWindow(id: AboutCommands.windowID)
            return .handled
        }
        .onExitCommand {
            dismissWindow(id: AboutCommands.windowID)
        }
        .onAppear { receivesEscape = true }
    }

    private func creditRow(_ name: String, detail: String) -> some View {
        VStack(spacing: 1) {
            Text(name)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
