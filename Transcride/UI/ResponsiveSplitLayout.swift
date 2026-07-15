import AppKit
import SwiftUI

struct PlaybackWidthRequirement: Equatable {
    var availableWidth: CGFloat = 0
    var requiredWidth: CGFloat = 0
    var detailHorizontalInsets: CGFloat = 0

    var isPresent: Bool { requiredWidth > 0 }
    var isOverflowing: Bool { isPresent && availableWidth + 1 < requiredWidth }
    var requiredDetailWidth: CGFloat { requiredWidth + detailHorizontalInsets }
}

enum ResponsiveSplitPresentation: Equatable {
    case allColumns
    case middleAndDetail
    case detailOnly
}

struct ResponsiveSplitMetrics: Equatable {
    var splitWidth: CGFloat
    var middleWidth: CGFloat
    var player: PlaybackWidthRequirement
}

struct ResponsiveSplitLayoutState: Equatable {
    static let sidebarMinimumWidth: CGFloat = 200
    static let middleMinimumWidth: CGFloat = 260
    static let restoreMargin: CGFloat = 24
    private static let dividerAllowance: CGFloat = 2

    var presentation: ResponsiveSplitPresentation = .allColumns
    var sidebarWasAutoHidden = false
    var middleWasAutoHidden = false
    var sidebarCollapseWidth: CGFloat?
    var middleCollapseWidth: CGFloat?

    var swiftUIVisibility: NavigationSplitViewVisibility {
        presentation == .allColumns ? .all : .doubleColumn
    }

    var collapsesMiddleColumn: Bool {
        presentation == .detailOnly
    }

    func userSelected(_ presentation: ResponsiveSplitPresentation) -> Self {
        var next = self
        next.presentation = presentation
        next.sidebarWasAutoHidden = false
        next.middleWasAutoHidden = false
        next.sidebarCollapseWidth = nil
        next.middleCollapseWidth = nil
        return next
    }

    func reconciled(with metrics: ResponsiveSplitMetrics) -> Self {
        var next = self

        switch presentation {
        case .allColumns:
            if metrics.player.isOverflowing {
                next.presentation = .middleAndDetail
                next.sidebarWasAutoHidden = true
                next.sidebarCollapseWidth = metrics.splitWidth
            }

        case .middleAndDetail:
            if middleAndDetailCannotFit(metrics),
               metrics.middleWidth <= Self.middleMinimumWidth + 1 {
                next.presentation = .detailOnly
                next.middleWasAutoHidden = true
                next.middleCollapseWidth = metrics.splitWidth
            } else if sidebarWasAutoHidden, canShowAllColumns(metrics) {
                next.presentation = .allColumns
                next.sidebarWasAutoHidden = false
                next.sidebarCollapseWidth = nil
            }

        case .detailOnly:
            if middleWasAutoHidden, canShowMiddleColumn(metrics) {
                next.presentation = .middleAndDetail
                next.middleWasAutoHidden = false
                next.middleCollapseWidth = nil
            }
        }

        return next
    }

    private func canShowMiddleColumn(_ metrics: ResponsiveSplitMetrics) -> Bool {
        guard metrics.player.isPresent else { return true }
        let fitWidth = metrics.player.requiredDetailWidth
            + Self.middleMinimumWidth
            + Self.dividerAllowance
            + Self.restoreMargin
        let hysteresisWidth = (middleCollapseWidth ?? 0) + Self.restoreMargin
        return metrics.splitWidth >= max(fitWidth, hysteresisWidth)
    }

    private func middleAndDetailCannotFit(_ metrics: ResponsiveSplitMetrics) -> Bool {
        guard metrics.player.isPresent else { return false }
        let minimumFitWidth = metrics.player.requiredDetailWidth
            + Self.middleMinimumWidth
            + Self.dividerAllowance
        return metrics.player.isOverflowing || metrics.splitWidth + 1 < minimumFitWidth
    }

    private func canShowAllColumns(_ metrics: ResponsiveSplitMetrics) -> Bool {
        guard metrics.player.isPresent else { return true }
        let fitWidth = metrics.player.requiredDetailWidth
            + Self.middleMinimumWidth
            + Self.sidebarMinimumWidth
            + (Self.dividerAllowance * 2)
            + Self.restoreMargin
        let hysteresisWidth = (sidebarCollapseWidth ?? 0) + Self.restoreMargin
        return metrics.splitWidth >= max(fitWidth, hysteresisWidth)
    }
}

/// Reaches through SwiftUI's NavigationSplitView only for behavior that its
/// macOS API does not expose reliably: collapsing the middle content-list
/// item at the extreme narrow end while keeping the detail item visible.
struct ResponsiveSplitViewInstaller: NSViewRepresentable {
    let collapsesMiddleColumn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ResponsiveSplitInstallerHostView {
        let view = ResponsiveSplitInstallerHostView()
        context.coordinator.configure(collapsesMiddleColumn: collapsesMiddleColumn)
        view.onWindowChange = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.scheduleReconciliation(from: view)
        }
        context.coordinator.scheduleReconciliation(from: view)
        return view
    }

    func updateNSView(_ nsView: ResponsiveSplitInstallerHostView, context: Context) {
        context.coordinator.configure(collapsesMiddleColumn: collapsesMiddleColumn)
        context.coordinator.scheduleReconciliation(from: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var middleItem: NSSplitViewItem?
        private weak var detailItem: NSSplitViewItem?
        private var originalCollapseBehavior: NSSplitViewItem.CollapseBehavior?
        private var collapsesMiddleColumn = false

        func configure(collapsesMiddleColumn: Bool) {
            self.collapsesMiddleColumn = collapsesMiddleColumn
            applyConfigurationIfResolved()
        }

        func scheduleReconciliation(from view: ResponsiveSplitInstallerHostView) {
            for delay in [0.0, 0.05, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.resolveItems(from: view)
                    self.applyConfigurationIfResolved()
                }
            }
        }

        private func resolveItems(from view: NSView) {
            guard let splitView = enclosingSplitView(from: view),
                  let controller = splitViewController(for: splitView),
                  let middleIndex = splitView.arrangedSubviews.firstIndex(where: { pane in
                      view === pane || view.isDescendant(of: pane)
                  }),
                  controller.splitViewItems.indices.contains(middleIndex),
                  let detailIndex = controller.splitViewItems.indices.last,
                  detailIndex > middleIndex else { return }

            let resolvedMiddle = controller.splitViewItems[middleIndex]
            let resolvedDetail = controller.splitViewItems[detailIndex]
            if middleItem !== resolvedMiddle || detailItem !== resolvedDetail {
                middleItem = resolvedMiddle
                detailItem = resolvedDetail
                originalCollapseBehavior = resolvedMiddle.collapseBehavior
            }
        }

        private func applyConfigurationIfResolved() {
            guard let middleItem, let detailItem else { return }
            Self.applyConfiguration(
                middleItem: middleItem,
                detailItem: detailItem,
                collapsesMiddleColumn: collapsesMiddleColumn,
                originalCollapseBehavior: originalCollapseBehavior ?? middleItem.collapseBehavior
            )
        }

        private func enclosingSplitView(from view: NSView) -> NSSplitView? {
            var candidate = view.superview
            while let current = candidate {
                if let splitView = current as? NSSplitView,
                   splitView.isVertical,
                   splitView.arrangedSubviews.count >= 3 {
                    return splitView
                }
                candidate = current.superview
            }
            return nil
        }

        private func splitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
            if let controller = splitView.delegate as? NSSplitViewController {
                return controller
            }
            var responder = splitView.nextResponder
            while let current = responder {
                if let controller = current as? NSSplitViewController {
                    return controller
                }
                responder = current.nextResponder
            }
            return nil
        }

        static func applyConfiguration(
            middleItem: NSSplitViewItem,
            detailItem: NSSplitViewItem,
            collapsesMiddleColumn: Bool,
            originalCollapseBehavior: NSSplitViewItem.CollapseBehavior
        ) {
            let collapseBehavior: NSSplitViewItem.CollapseBehavior = collapsesMiddleColumn
                ? .preferResizingSiblingsWithFixedSplitView
                : originalCollapseBehavior
            if middleItem.collapseBehavior != collapseBehavior {
                middleItem.collapseBehavior = collapseBehavior
            }
            if middleItem.isCollapsed != collapsesMiddleColumn {
                middleItem.isCollapsed = collapsesMiddleColumn
            }
        }
    }
}

final class ResponsiveSplitInstallerHostView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
