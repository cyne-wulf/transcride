import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            case .needsVault:
                WelcomeView()
            case .ready:
                MainView()
            }
        }
        .background(MainWindowIdentityView())
        .background(AppSceneActionBridge())
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Cancel Recording?",
            isPresented: $model.isCancelRecordingConfirmationPresented
        ) {
            Button("Keep Recording", role: .cancel) {}
            Button("Discard Recording", role: .destructive) {
                Task { await model.discardActiveRecording() }
            }
        } message: {
            Text(model.cancelRecordingConfirmationMessage)
        }
        .alert(
            "Original Transcript Updated",
            isPresented: Binding(
                get: { model.transcriptNoticeMessage != nil },
                set: { if !$0 { model.transcriptNoticeMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.transcriptNoticeMessage ?? "")
        }
        .alert(
            "Recording Recovered",
            isPresented: Binding(
                get: { model.recordingRecoveryNoticeMessage != nil },
                set: { if !$0 { model.recordingRecoveryNoticeMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.recordingRecoveryNoticeMessage ?? "")
        }
        .onExitCommand {
            model.handleExitCommand()
        }
    }
}
