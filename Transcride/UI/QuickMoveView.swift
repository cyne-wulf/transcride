import SwiftUI

/// Compact Obsidian-style destination picker for the selected note. Search
/// keeps focus while Up/Down change the highlighted folder, Return confirms,
/// and a failed filesystem move remains visible for correction or retry.
struct QuickMoveView: View {
    @Environment(AppModel.self) private var model

    let entry: Entry
    private let initialRoot: FolderNode

    @State private var query = ""
    @State private var selectedDestination: RelativePath?
    @State private var inlineError: String?
    @State private var isSubmitting = false
    @FocusState private var searchFieldFocused: Bool

    init(entry: Entry, root: FolderNode) {
        self.entry = entry
        initialRoot = root
        let catalog = QuickMoveDestinationCatalog(
            root: root,
            movingEntryAt: entry.relativePath
        )
        _selectedDestination = State(initialValue: catalog.destinations.first?.relativePath)
    }

    private var catalog: QuickMoveDestinationCatalog {
        QuickMoveDestinationCatalog(
            root: model.snapshot?.root ?? initialRoot,
            movingEntryAt: entry.relativePath
        )
    }

    private var results: [QuickMoveDestination] {
        catalog.filteredDestinations(for: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            destinations
            Divider()
            footer
        }
        .frame(width: 500, height: 430)
        .onAppear {
            reconcileSelection()
            Task { @MainActor in searchFieldFocused = true }
        }
        .onChange(of: query) { _, _ in
            inlineError = nil
            reconcileSelection()
        }
        .onChange(of: results.map(\.relativePath)) { _, _ in
            reconcileSelection()
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            moveSelectedDestination()
            return .handled
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(entry.displayTitle)”")
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit { moveSelectedDestination() }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    @ViewBuilder
    private var destinations: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { destination in
                            destinationRow(destination)
                                .id(destination.relativePath)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedDestination) { _, path in
                    guard let path else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(path, anchor: .center)
                    }
                }
            }
        }
    }

    private func destinationRow(_ destination: QuickMoveDestination) -> some View {
        let isSelected = selectedDestination == destination.relativePath
        return Button {
            selectedDestination = destination.relativePath
            move(to: destination.relativePath)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.relativePath.isEmpty ? "tray.full" : "folder")
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 18)
                Text(destination.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(isBusy)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inlineError {
                Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Move failed: \(inlineError)")
            }

            HStack {
                Text("↑↓ Select   ↩ Move   esc Cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { cancel() }
                    .disabled(isBusy)
                Button("Move") { moveSelectedDestination() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDestination == nil || isBusy)
            }
        }
        .padding(16)
    }

    private func reconcileSelection() {
        let paths = results.map(\.relativePath)
        selectedDestination = QuickMoveSelection.reconciled(
            current: selectedDestination,
            destinationPaths: paths
        )
    }

    private func moveSelection(by offset: Int) {
        guard !isBusy else { return }
        selectedDestination = QuickMoveSelection.moved(
            current: selectedDestination,
            destinationPaths: results.map(\.relativePath),
            offset: offset
        )
    }

    private func moveSelectedDestination() {
        guard let selectedDestination else { return }
        move(to: selectedDestination)
    }

    private func move(to destination: RelativePath) {
        guard !isBusy else { return }
        isSubmitting = true
        inlineError = nil
        Task {
            defer { isSubmitting = false }
            let result = await model.moveEntry(
                atRelativePath: entry.relativePath,
                toFolder: destination
            )
            switch result {
            case .success:
                model.isQuickMovePresented = false
            case .failure(let failure):
                if case .destinationMissing = failure {
                    await model.refresh()
                    reconcileSelection()
                }
                inlineError = failure.localizedDescription
            }
        }
    }

    private func cancel() {
        guard !isBusy else { return }
        model.isQuickMovePresented = false
    }

    private var isBusy: Bool {
        isSubmitting || model.isQuickMoveInFlight
    }
}
