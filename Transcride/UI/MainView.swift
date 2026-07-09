import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    @State private var showingModelOffer = false

    var body: some View {
        @Bindable var model = model
        // Read here, not in the toolbar closure: observation only tracks
        // reads made during body, and the ToolbarContentBuilder closure is
        // not re-evaluated when the queue mutates — reading `items` only
        // there leaves the button stuck until body re-runs for another
        // reason.
        let queueHasItems = model.transcriptionQueue?.items.isEmpty == false
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
        .navigationTitle(model.vaultURL?.lastPathComponent ?? "Transcride")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !model.recorder.isZenMode {
                    LiveTranscriptStrip(transcriber: model.liveTranscriber)
                }
                RecorderBar()
            }
        }
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
            if let queue = model.transcriptionQueue, queueHasItems {
                ToolbarItem {
                    TranscriptionQueueButton(queue: queue)
                }
            }
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
