import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    @State private var showingModelOffer = false
    @State private var responsiveLayout = ResponsiveSplitLayoutState()
    @State private var splitWidth: CGFloat = 0
    @State private var middleWidth: CGFloat = ResponsiveSplitLayoutState.middleMinimumWidth
    @State private var playerWidthRequirement = PlaybackWidthRequirement()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: columnVisibilityBinding) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            } content: {
                Group {
                    switch model.sidebarSelection {
                    case .recentlyDeleted:
                        RecentlyDeletedView()
                    case .folder, .favorites, .none:
                        EntryListView()
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    middleWidth = width
                    scheduleResponsiveLayoutReconciliation()
                }
                .background {
                    ResponsiveSplitViewInstaller(
                        collapsesMiddleColumn: responsiveLayout.collapsesMiddleColumn
                    )
                    .frame(width: 0, height: 0)
                }
            } detail: {
                Group {
                    if model.sidebarSelection == .recentlyDeleted {
                        TrashPreviewView(
                            onPlaybackWidthRequirementChange: updatePlayerWidthRequirement
                        )
                    } else {
                        EntryDetailView(
                            onPlaybackWidthRequirementChange: updatePlayerWidthRequirement
                        )
                    }
                }
                .frame(minWidth: protectedDetailWidth)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                splitWidth = width
                scheduleResponsiveLayoutReconciliation()
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
        .onChange(of: responsiveLayout.collapsesMiddleColumn, initial: true) { _, collapsed in
            model.setMiddleColumnCollapsed(collapsed)
        }
        .onDisappear {
            model.setMiddleColumnCollapsed(false)
        }
        .background {
            if #unavailable(macOS 26.0) {
                ToolbarFlexibleSpaceInstaller(
                    reconciliationToken: toolbarReconciliationToken
                )
                    .frame(width: 0, height: 0)
            }
        }
        .sheet(isPresented: $model.isVaultSearchPresented) {
            VaultSearchView()
                .environment(model)
        }
        .sheet(isPresented: $model.isExtensionRecoveryPresented) {
            ExtensionRecoveryView()
                .environment(model)
        }
        .sheet(isPresented: $model.isQuickMovePresented) {
            if let entry = model.quickMoveEntry,
               let root = model.snapshot?.root {
                QuickMoveView(entry: entry, root: root)
                    .environment(model)
            } else {
                VStack(spacing: 18) {
                    ContentUnavailableView(
                        "Note Unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(
                            "The note changed or was removed while Move Note was open."
                        )
                    )
                    Button("Cancel") { model.isQuickMovePresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                    .frame(width: 500, height: 430)
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

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { responsiveLayout.swiftUIVisibility },
            set: { visibility in
                guard visibility != responsiveLayout.swiftUIVisibility else { return }
                responsiveLayout = responsiveLayout.userSelected(
                    visibility == .all ? .allColumns : .middleAndDetail
                )
            }
        )
    }

    private func reconcileResponsiveLayout() {
        let metrics = ResponsiveSplitMetrics(
            splitWidth: splitWidth,
            middleWidth: middleWidth,
            player: playerWidthRequirement
        )
        let next = responsiveLayout.reconciled(with: metrics)
        if next != responsiveLayout {
            responsiveLayout = next
        }
    }

    private func scheduleResponsiveLayoutReconciliation() {
        DispatchQueue.main.async {
            reconcileResponsiveLayout()
        }
    }

    private func updatePlayerWidthRequirement(_ requirement: PlaybackWidthRequirement) {
        playerWidthRequirement = requirement
        scheduleResponsiveLayoutReconciliation()
    }

    private var protectedDetailWidth: CGFloat? {
        guard responsiveLayout.presentation != .allColumns,
              playerWidthRequirement.isPresent else { return nil }
        return playerWidthRequirement.requiredDetailWidth
    }

    private var toolbarReconciliationToken: String {
        let entry = model.selectedEntry
        let sidebar: String
        switch model.sidebarSelection {
        case .folder(let path): sidebar = "folder:\(path)"
        case .favorites: sidebar = "favorites"
        case .recentlyDeleted: sidebar = "recentlyDeleted"
        case .none: sidebar = "none"
        }
        return "\(sidebar)|\(entry?.relativePath ?? "")|audio:\(entry?.hasAudio == true)|deleted:\(entry?.audioDeleted == true)"
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
