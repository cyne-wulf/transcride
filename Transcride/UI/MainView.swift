import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    @State private var showingModelOffer = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            } content: {
                Group {
                    switch model.sidebarSelection {
                    case .recentlyDeleted:
                        RecentlyDeletedView()
                    case .folder, .none:
                        EntryListView()
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                EntryDetailView()
            }

            if !model.recorder.isZenMode {
                LiveTranscriptStrip(transcriber: model.liveTranscriber)
            }
            RecorderBar()
        }
        .navigationTitle(model.vaultURL?.lastPathComponent ?? "Transcride")
        // Drag-and-drop import: anywhere on the window makes a new entry per file.
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.importFiles(urls) }
            return true
        }
        .overlay {
            if model.recorder.isZenMode {
                ZenModeView()
            }
        }
        .toolbar(model.recorder.isZenMode ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            // Keep the queue discoverable even when it is empty. The popover
            // explains the idle state and the same ring becomes live progress
            // as soon as transcription work appears.
            if let queue = model.transcriptionQueue {
                ToolbarItem {
                    TranscriptionQueueButton(queue: queue)
                }
            }
        }
        .sheet(isPresented: $model.isVaultSearchPresented) {
            VaultSearchView()
                .environment(model)
        }
        // First run with a vault open: offer the default model download once.
        .task { await offerDefaultModelIfNeeded() }
        .alert("Download the Transcription Model?", isPresented: $showingModelOffer) {
            Button("Download") {
                model.modelManager.download(ModelCatalog.parakeetV3.id)
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("""
            Recordings and imports are transcribed on this Mac with \
            \(ModelCatalog.parakeetV3.displayName) \
            (about \(ModelCatalog.parakeetV3.downloadSizeDescription)). \
            You can manage models anytime in Settings → Transcription.
            """)
        }
    }

    /// Shows the one-time Parakeet download offer (ENG-2). The flag is set as
    /// soon as the offer appears, so declining never re-prompts.
    private func offerDefaultModelIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: ModelManager.didOfferDefaultDownloadKey) else { return }
        let defaultID = ModelCatalog.parakeetV3.id
        await model.modelManager.refreshModel(defaultID)
        defaults.set(true, forKey: ModelManager.didOfferDefaultDownloadKey)
        guard model.modelManager.state(forModelInfoID: defaultID) == .notDownloaded else { return }
        showingModelOffer = true
    }
}
