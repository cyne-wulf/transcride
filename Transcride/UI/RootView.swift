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
    }
}
