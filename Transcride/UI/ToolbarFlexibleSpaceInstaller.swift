import AppKit
import SwiftUI

/// Compatibility shim for macOS 15–25, before SwiftUI exposed
/// `ToolbarSpacer`. It inserts one native flexible space at the boundary
/// between the middle-pane controls and the persistent detail-pane anchor.
struct ToolbarFlexibleSpaceInstaller: NSViewRepresentable {
    let reconciliationToken: String

    func makeNSView(context: Context) -> ToolbarInstallerHostView {
        let view = ToolbarInstallerHostView()
        configure(view)
        view.onWindowChange = { [weak view] in
            guard let view else { return }
            Self.scheduleReconciliation(from: view)
        }
        Self.scheduleReconciliation(from: view)
        return view
    }

    func updateNSView(_ nsView: ToolbarInstallerHostView, context: Context) {
        configure(nsView)
        Self.scheduleReconciliation(from: nsView)
    }

    private func configure(_ view: ToolbarInstallerHostView) {
        view.reconciliationToken = reconciliationToken
    }

    private static func scheduleReconciliation(from view: ToolbarInstallerHostView) {
        let token = view.reconciliationToken
        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard view.reconciliationToken == token else { return }
                reconcile(from: view)
            }
        }
    }

    private static func reconcile(from view: ToolbarInstallerHostView) {
        guard let toolbar = view.window?.toolbar,
              let firstMiddleIndex = firstMiddleControlIndex(in: toolbar.items),
              let lastMiddleIndex = lastMiddleControlIndex(in: toolbar.items),
              let actionBoundaryIndex = firstActionBoundaryIndex(in: toolbar.items) else { return }

        let leadingSpacerIndex = toolbar.items.indices.first {
            $0 < firstMiddleIndex && toolbar.items[$0].itemIdentifier == .flexibleSpace
        }
        let boundarySpacerIndex = toolbar.items.indices.first {
            $0 > lastMiddleIndex
                && $0 < actionBoundaryIndex
                && toolbar.items[$0].itemIdentifier == .flexibleSpace
        }

        // NSToolbar flexible spaces cannot carry a custom identifier. Preserve
        // the leading and pane-boundary spaces by position and remove only
        // duplicates left behind by a SwiftUI toolbar rebuild.
        let duplicateIndices = toolbar.items.indices.filter { index in
            guard toolbar.items[index].itemIdentifier == .flexibleSpace else { return false }
            return index != leadingSpacerIndex && index != boundarySpacerIndex
        }
        for index in duplicateIndices.reversed() {
            toolbar.removeItem(at: index)
        }

        guard boundarySpacerIndex == nil,
              let insertionIndex = firstActionBoundaryIndex(in: toolbar.items) else { return }
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: insertionIndex)
    }

    private static func firstActionBoundaryIndex(in items: [NSToolbarItem]) -> Int? {
        items.firstIndex {
            ["detailAnchor", "detailFavorite"].contains($0.itemIdentifier.rawValue)
                || itemMatches($0, any: ["favorite", "unfavorite"])
        }
    }

    private static func lastMiddleControlIndex(in items: [NSToolbarItem]) -> Int? {
        items.indices.last { itemMatches(items[$0], any: middleControlLabels) }
    }

    private static func firstMiddleControlIndex(in items: [NSToolbarItem]) -> Int? {
        items.firstIndex { itemMatches($0, any: middleControlLabels) }
    }

    private static let middleControlLabels = [
        "middlequeue", "middlesort", "transcription queue", "sort entries", "sort",
    ]

    private static func itemMatches(_ item: NSToolbarItem, any needles: [String]) -> Bool {
        let searchable = itemSearchText(item).lowercased()
        return needles.contains { searchable.contains($0) }
    }

    private static func itemSearchText(_ item: NSToolbarItem) -> String {
        var fields = [
            item.itemIdentifier.rawValue,
            item.label,
            item.paletteLabel,
            item.toolTip ?? "",
        ]
        if let itemView = item.view {
            fields.append(contentsOf: accessibilityLabels(in: itemView))
        }
        return fields.joined(separator: " | ")
    }

    private static func accessibilityLabels(in view: NSView) -> [String] {
        var labels = [view.accessibilityLabel()].compactMap { label in
            label?.isEmpty == false ? label : nil
        }
        for subview in view.subviews {
            labels.append(contentsOf: accessibilityLabels(in: subview))
        }
        return labels
    }
}

final class ToolbarInstallerHostView: NSView {
    var onWindowChange: (() -> Void)?
    var reconciliationToken = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
