import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model

    // Payload separate from isPresented — SwiftUI clears the presentation
    // binding before running dialog button actions.
    @State private var showDeletePrompt = false
    @State private var permanentlyDeleting: TrashItem?
    @State private var showRestorePreTrimPrompt = false
    @State private var restoringPreTrim: TrashItem?
    @State private var showEmptyTrashPrompt = false
    @FocusState private var trashListHasFocus: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if model.trashItems.isEmpty {
                ContentUnavailableView {
                    Label("Recently Deleted Is Empty", systemImage: "trash")
                } description: {
                    Text("Deleted entries, folders, and audio files are kept here for \(model.trashRetentionDays) days.")
                }
            } else {
                List(selection: $model.selectedTrashItemID) {
                    ForEach(model.trashItems) { item in
                        trashRow(item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .focused($trashListHasFocus)
                .defaultFocus($trashListHasFocus, true)
                .task {
                    await Task.yield()
                    trashListHasFocus = true
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem {
                Button("Empty Trash…") {
                    showEmptyTrashPrompt = true
                }
                .disabled(model.trashItems.isEmpty)
                .help("Permanently delete everything in Recently Deleted")
            }
        }
        .confirmationDialog(
            model.trashItems.count == 1
                ? "Permanently delete 1 item?"
                : "Permanently delete all \(model.trashItems.count) items?",
            isPresented: $showEmptyTrashPrompt,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in Recently Deleted is deleted immediately. This cannot be undone.")
        }
        .confirmationDialog(
            "Permanently delete “\(permanentlyDeleting?.displayName ?? "")”?",
            isPresented: $showDeletePrompt,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let item = permanentlyDeleting {
                    Task { await model.deleteTrashItemPermanently(item) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Restore “\(restoringPreTrim?.displayName ?? "")”?",
            isPresented: $showRestorePreTrimPrompt,
            titleVisibility: .visible
        ) {
            Button("Restore Audio Version") {
                if let item = restoringPreTrim {
                    Task { await model.restoreTrashItem(item) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The retained audio replaces the entry's current trim or compression. "
                + "The derived version is discarded and the entry is re-transcribed.")
        }
    }

    /// Restoring a retained original discards a reproducible trim/compression,
    /// so it confirms first; every other kind restores immediately.
    private func requestRestore(_ item: TrashItem) {
        if item.kind == .audioVersion || item.kind == .preTrimAudio
            || item.kind == .preCompressionAudio {
            restoringPreTrim = item
            showRestorePreTrimPrompt = true
        } else {
            Task { await model.restoreTrashItem(item) }
        }
    }

    @ViewBuilder
    private func trashRow(_ item: TrashItem) -> some View {
        HStack {
            Image(systemName: iconName(for: item))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Deleted \(item.deletedAt.formatted(date: .abbreviated, time: .shortened)) · was in \(locationDescription(item))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { requestRestore(item) }
            Button(role: .destructive) {
                permanentlyDeleting = item
                showDeletePrompt = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Permanently")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { requestRestore(item) }
            Button("Reveal in Finder") { model.revealTrashItemInFinder(item) }
            Divider()
            Button("Delete Permanently…", role: .destructive) {
                permanentlyDeleting = item
                showDeletePrompt = true
            }
        }
    }

    private func iconName(for item: TrashItem) -> String {
        switch item.kind {
        case .entryAudio: "waveform.badge.minus"
        case .audioVersion: "arrow.trianglehead.2.clockwise.rotate.90"
        case .preTrimAudio: "scissors"
        case .preExtensionAudio: "record.circle"
        case .preCompressionAudio: "arrow.down.right.and.arrow.up.left"
        case .item: item.isEntry ? "waveform" : "folder"
        }
    }

    private func locationDescription(_ item: TrashItem) -> String {
        let parent = item.originalPath.parentRelativePath
        return parent.isEmpty ? "Vault Root" : parent
    }
}
