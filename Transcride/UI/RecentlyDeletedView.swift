import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model

    // Payload separate from isPresented — SwiftUI clears the presentation
    // binding before running dialog button actions.
    @State private var showDeletePrompt = false
    @State private var permanentlyDeleting: TrashItem?

    var body: some View {
        Group {
            if model.trashItems.isEmpty {
                ContentUnavailableView {
                    Label("Recently Deleted Is Empty", systemImage: "trash")
                } description: {
                    Text("Deleted entries, folders, and audio files are kept here for \(TrashStore.retentionDays) days.")
                }
            } else {
                List {
                    ForEach(model.trashItems) { item in
                        trashRow(item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Recently Deleted")
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
            Button("Restore") {
                Task { await model.restoreTrashItem(item) }
            }
            Button(role: .destructive) {
                permanentlyDeleting = item
                showDeletePrompt = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Permanently")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Restore") { Task { await model.restoreTrashItem(item) } }
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
        case .item: item.isEntry ? "waveform" : "folder"
        }
    }

    private func locationDescription(_ item: TrashItem) -> String {
        let parent = item.originalPath.parentRelativePath
        return parent.isEmpty ? "Vault Root" : parent
    }
}
