import SwiftUI

/// Prominent vault-wide search surface (SRCH-1...4). Results remain grouped
/// by entry while each matching layer keeps its own explicit label and jump.
struct VaultSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFieldFocused: Bool

    private struct ResultGroup: Identifiable {
        var entryPath: RelativePath
        var title: String
        var hits: [SearchHit]
        var id: RelativePath { entryPath }
    }

    private var groups: [ResultGroup] {
        var order: [RelativePath] = []
        var grouped: [RelativePath: ResultGroup] = [:]
        for hit in model.vaultSearchResults {
            if grouped[hit.entryPath] == nil {
                order.append(hit.entryPath)
                grouped[hit.entryPath] = ResultGroup(
                    entryPath: hit.entryPath, title: hit.title, hits: []
                )
            }
            if hit.layer == .original,
               grouped[hit.entryPath]?.hits.contains(where: {
                   $0.layer == .edited
                       && normalizedSnippet($0.snippet) == normalizedSnippet(hit.snippet)
               }) == true {
                continue
            }
            grouped[hit.entryPath]?.hits.append(hit)
        }
        return order.compactMap { grouped[$0] }
    }

    private func normalizedSnippet(_ snippet: String) -> String {
        snippet.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultsContent
        }
        .frame(
            minWidth: 720,
            idealWidth: 780,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: 580,
            maxHeight: .infinity,
            alignment: .top
        )
        .onAppear { searchFieldFocused = true }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField(
                    "Search every transcript",
                    text: Binding(
                        get: { model.vaultSearchQuery },
                        set: { model.updateVaultSearchQuery($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFieldFocused)

                if !model.vaultSearchQuery.isEmpty {
                    Button {
                        model.updateVaultSearchQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                }

                Divider().frame(height: 24)

                Toggle("Fuzzy", isOn: Binding(
                    get: { model.fuzzyVaultSearch },
                    set: { model.fuzzyVaultSearch = $0 }
                ))
                .toggleStyle(.switch)
                .help("Allow close spellings and small typos")

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(model.fuzzyVaultSearch
                 ? "Fuzzy matching is on — close spellings may match."
                 : "Exact match — case-insensitive substring search.")
                .font(.caption)
                .foregroundStyle(.secondary)

            filterRow
        }
        .padding(18)
        .background(.bar)
    }

    // MARK: - Filters (SRCH-5)

    private var filterRow: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Folder", selection: $model.vaultSearchFilters.folder) {
                    Text("All Folders").tag(RelativePath?.none)
                    ForEach(filterableFolders, id: \.relativePath) { node in
                        Text(node.relativePath).tag(RelativePath?.some(node.relativePath))
                    }
                }
                .fixedSize()
                .help("Only entries inside this folder")

                Picker("Date", selection: datePresetBinding) {
                    ForEach(VaultSearchFilters.DatePreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .fixedSize()
                .help("Only entries created in this period")

                Picker("Audio", selection: $model.vaultSearchFilters.audio) {
                    ForEach(VaultSearchFilters.AudioPresence.allCases, id: \.self) { presence in
                        Text(presence.displayName).tag(presence)
                    }
                }
                .fixedSize()
                .help("Whether the entry still has its audio")

                Toggle("Favorites", isOn: $model.vaultSearchFilters.favoritesOnly)
                    .toggleStyle(.checkbox)
                    .help("Only favorited entries")

                Menu {
                    ForEach(availableTags, id: \.canonical) { tag in
                        Button {
                            toggleTag(tag.canonical)
                        } label: {
                            Label(
                                "#\(tag.display)",
                                systemImage: model.vaultSearchFilters.selectedTags
                                    .contains(tag.canonical)
                                    ? "checkmark" : "tag"
                            )
                        }
                    }
                } label: {
                    Label(
                        model.vaultSearchFilters.selectedTags.isEmpty
                            ? "Tags"
                            : "Tags (\(model.vaultSearchFilters.selectedTags.count))",
                        systemImage: "tag"
                    )
                }
                .disabled(availableTags.isEmpty)
                .help("Match any selected tag; parent tags include descendants")

                Spacer()

                if model.vaultSearchFilters.isActive {
                    Button("Clear Filters") {
                        model.vaultSearchFilters = VaultSearchFilters()
                    }
                }
            }

            if model.vaultSearchFilters.datePreset == .custom {
                HStack(spacing: 10) {
                    DatePicker(
                        "From",
                        selection: $model.vaultSearchFilters.customStart,
                        displayedComponents: .date
                    )
                    .fixedSize()
                    DatePicker(
                        "To",
                        selection: $model.vaultSearchFilters.customEnd,
                        displayedComponents: .date
                    )
                    .fixedSize()
                }
            }
        }
        .controlSize(.small)
    }

    /// Non-root folders, depth-first, as shown in the folder filter.
    private var filterableFolders: [FolderNode] {
        guard let root = model.snapshot?.root else { return [] }
        return Array(root.allFolders.dropFirst())
    }

    private var availableTags: [EditorTag] {
        var displayByCanonical: [String: String] = [:]
        for tag in model.snapshot?.allEntries.flatMap(\.tags) ?? [] {
            if displayByCanonical[tag.canonical] == nil {
                displayByCanonical[tag.canonical] = tag.display
            }
        }
        return displayByCanonical.map {
            EditorTag(canonical: $0.key, display: $0.value)
        }.sorted {
            $0.display.localizedStandardCompare($1.display) == .orderedAscending
        }
    }

    private func toggleTag(_ canonical: String) {
        var filters = model.vaultSearchFilters
        if filters.selectedTags.remove(canonical) == nil {
            filters.selectedTags.insert(canonical)
        }
        model.vaultSearchFilters = filters
    }

    /// Choosing "Custom Range…" seeds the pickers with a sane recent window
    /// instead of the sentinel epoch/distant-future defaults.
    private var datePresetBinding: Binding<VaultSearchFilters.DatePreset> {
        Binding {
            model.vaultSearchFilters.datePreset
        } set: { preset in
            var filters = model.vaultSearchFilters
            if preset == .custom, filters.customStart == Date(timeIntervalSince1970: 0) {
                filters.customStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
                filters.customEnd = .now
            }
            filters.datePreset = preset
            model.vaultSearchFilters = filters
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        switch model.searchIndexState {
        case .unavailable, .indexing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Indexing this vault…")
                    .font(.headline)
                Text("You can keep working. Search will begin automatically when the cache is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Search Index Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Rebuild Index") { model.retrySearchIndex() }
            }

        case .ready:
            if model.vaultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.vaultSearchFilters.selectedTags.isEmpty {
                ContentUnavailableView(
                    "Search the Vault",
                    systemImage: "text.magnifyingglass",
                    description: Text("Original transcripts and truly edited Markdown layers are searchable.")
                )
            } else if let error = model.vaultSearchError {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { model.retryVaultSearch() }
                }
            } else if model.vaultSearchIsRunning, groups.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label(noMatchesTitle, systemImage: "magnifyingglass")
                } description: {
                    Text(model.vaultSearchFilters.isActive
                         ? "No filtered entries match. Try clearing the filters."
                         : (model.fuzzyVaultSearch
                            ? "Try a shorter word or turn off Fuzzy for literal phrases."
                            : "Try a shorter phrase, or turn on Fuzzy for a close spelling."))
                } actions: {
                    if model.vaultSearchFilters.isActive {
                        Button("Clear Filters") {
                            model.vaultSearchFilters = VaultSearchFilters()
                        }
                    }
                }
            } else {
                resultList
            }
        }
    }

    private var resultList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.hits, id: \.self) { hit in
                        Button {
                            model.selectSearchHit(hit)
                        } label: {
                            resultRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(group.title.isEmpty ? group.entryPath.lastComponent : group.title)
                            .font(.headline)
                            .textCase(nil)
                        Spacer()
                        if group.hits.count > 1 {
                            Text("\(group.hits.count) layers")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .topTrailing) {
            if model.vaultSearchIsRunning {
                ProgressView().controlSize(.small).padding(12)
            }
        }
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(resultKindLabel(hit))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hit.matchKind == .title || hit.matchKind == .metadata
                                 ? AnyShapeStyle(.secondary)
                                 : hit.layer == .edited
                                 ? AnyShapeStyle(.tint)
                                 : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .frame(width: 66)

            highlightedSnippet(hit)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func highlightedSnippet(_ hit: SearchHit) -> Text {
        if hit.matchKind == .metadata { return Text(hit.snippet) }
        let source = hit.snippet as NSString
        let lower = min(max(0, hit.snippetMatchRange.lowerBound), source.length)
        let upper = min(max(lower, hit.snippetMatchRange.upperBound), source.length)
        let before = source.substring(with: NSRange(location: 0, length: lower))
        let match = source.substring(with: NSRange(location: lower, length: upper - lower))
        let after = source.substring(from: upper)
        return Text(before)
            + Text(match).bold().foregroundColor(.accentColor)
            + Text(after)
    }

    private var noMatchesTitle: String {
        let query = model.vaultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "No Entries Match the Selected Tags" : "No Matches for “\(query)”"
    }

    private func resultKindLabel(_ hit: SearchHit) -> String {
        switch hit.matchKind {
        case .title: "Title"
        case .metadata: "Tags"
        case .content: hit.layer == .edited ? "Edited" : "Original"
        }
    }
}
