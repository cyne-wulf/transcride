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
    }
}
