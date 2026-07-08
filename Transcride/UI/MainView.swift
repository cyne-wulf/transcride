import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
            RecorderBar()
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
    }
}
