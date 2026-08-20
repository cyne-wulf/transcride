import SwiftUI

/// Obsidian-style Move Note picker (⌥M / Entry → Move Note…): a compact
/// centered panel with an immediately focused search field, arrow-key
/// selection, Return/click to move, Escape to cancel. Failures keep the
/// picker open with an inline explanation; it never creates folders and
/// never overwrites an existing destination entry.
struct QuickMoveView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var selectedPath: RelativePath?
    @State private var isMoving = false
    @FocusState private var searchFocused: Bool

    private var results: [QuickMoveDestination] {
        QuickMoveModel.filtered(model.quickMoveDestinations, query: query)
    }

    private var selectedDestination: QuickMoveDestination? {
        results.first { $0.path == selectedPath } ?? results.first
    }

    private var entryTitle: String {
        guard let path = model.quickMoveEntryPath,
              let entry = model.snapshot?.entry(withID: path)
        else { return "Note" }
        return entry.displayTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Move “\(entryTitle)” to…")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(moveToSelection)
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        model.isQuickMovePresented = false
                        return .handled
                    }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)

            if let error = model.quickMoveErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            Group {
                if results.isEmpty {
                    Text(model.quickMoveDestinations.isEmpty
                         ? "There are no other folders in this vault."
                         : "No folders match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    destinationList
                }
            }
            .frame(height: 240)
            .padding(.top, 8)

            Divider()

            HStack {
                Text("↑↓ select · ↩ move · esc cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if isMoving { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { searchFocused = true }
        .onExitCommand { model.isQuickMovePresented = false }
        .onChange(of: query) { _, _ in
            selectedPath = results.first?.path
        }
    }

    private var destinationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results) { destination in
                        destinationRow(destination)
                            .id(destination.path)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: selectedDestination?.path) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
    }

    private func destinationRow(_ destination: QuickMoveDestination) -> some View {
        let isSelected = destination.path == selectedDestination?.path
        return Button {
            move(to: destination)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.isVaultRoot ? "shippingbox" : "folder")
                    .foregroundStyle(isSelected ? .white : .secondary)
                Text(destination.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedPath = destination.path }
        }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let paths = results.map(\.path)
        let currentIndex = selectedDestination.flatMap { paths.firstIndex(of: $0.path) } ?? 0
        let next = min(max(currentIndex + offset, 0), paths.count - 1)
        selectedPath = paths[next]
    }

    private func moveToSelection() {
        guard let destination = selectedDestination else { return }
        move(to: destination)
    }

    private func move(to destination: QuickMoveDestination) {
        guard !isMoving else { return }
        isMoving = true
        Task {
            await model.performQuickMove(to: destination)
            isMoving = false
        }
    }
}
