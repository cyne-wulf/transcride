import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Welcome to Transcride")
                    .font(.largeTitle.bold())
                Text("Your recordings and transcripts live in a vault — a normal folder of plain files you can browse in Finder and open in Obsidian.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            VStack(spacing: 12) {
                Button {
                    model.createNewVault()
                } label: {
                    Text("Create New Vault…")
                        .frame(width: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.chooseExistingVault()
                } label: {
                    Text("Open Existing Folder as Vault…")
                        .frame(width: 220)
                }
                .controlSize(.large)
            }
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 420)
    }
}
