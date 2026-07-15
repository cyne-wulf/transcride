import AppKit
import Testing
@testable import Transcride

@Suite("Responsive split layout")
@MainActor
struct ResponsiveSplitLayoutTests {
    private let overflowingPlayer = PlaybackWidthRequirement(
        availableWidth: 390,
        requiredWidth: 400,
        detailHorizontalInsets: 72
    )

    private let fittingPlayer = PlaybackWidthRequirement(
        availableWidth: 500,
        requiredWidth: 400,
        detailHorizontalInsets: 72
    )

    @Test func playerOverflowHidesSidebarFirst() {
        let next = ResponsiveSplitLayoutState().reconciled(with: metrics(
            splitWidth: 900,
            middleWidth: 320,
            player: overflowingPlayer
        ))

        #expect(next.presentation == .middleAndDetail)
        #expect(next.sidebarWasAutoHidden)
        #expect(!next.middleWasAutoHidden)
        #expect(next.sidebarCollapseWidth == 900)
    }

    @Test func middleShrinksToItsMinimumBeforeCollapsing() {
        let sidebarHidden = ResponsiveSplitLayoutState(
            presentation: .middleAndDetail,
            sidebarWasAutoHidden: true,
            sidebarCollapseWidth: 900
        )

        let stillTwoColumns = sidebarHidden.reconciled(with: metrics(
            splitWidth: 700,
            middleWidth: 300,
            player: overflowingPlayer
        ))
        #expect(stillTwoColumns.presentation == .middleAndDetail)

        let detailOnly = stillTwoColumns.reconciled(with: metrics(
            splitWidth: 650,
            middleWidth: 260,
            player: overflowingPlayer
        ))
        #expect(detailOnly.presentation == .detailOnly)
        #expect(detailOnly.sidebarWasAutoHidden)
        #expect(detailOnly.middleWasAutoHidden)
        #expect(detailOnly.middleCollapseWidth == 650)
    }

    @Test func middleCollapsesWhenItsMinimumAndPlayerWidthCannotBothFit() {
        let sidebarHidden = ResponsiveSplitLayoutState(
            presentation: .middleAndDetail,
            sidebarWasAutoHidden: true,
            sidebarCollapseWidth: 900
        )

        let detailOnly = sidebarHidden.reconciled(with: metrics(
            splitWidth: 732,
            middleWidth: 260,
            player: fittingPlayer
        ))

        #expect(detailOnly.presentation == .detailOnly)
        #expect(detailOnly.middleWasAutoHidden)
    }

    @Test func expansionRestoresMiddleThenSidebar() {
        let detailOnly = ResponsiveSplitLayoutState(
            presentation: .detailOnly,
            sidebarWasAutoHidden: true,
            middleWasAutoHidden: true,
            sidebarCollapseWidth: 900,
            middleCollapseWidth: 650
        )

        let belowMiddleFit = detailOnly.reconciled(with: metrics(
            splitWidth: 757,
            middleWidth: 260,
            player: fittingPlayer
        ))
        #expect(belowMiddleFit.presentation == .detailOnly)

        let middleRestored = detailOnly.reconciled(with: metrics(
            splitWidth: 758,
            middleWidth: 260,
            player: fittingPlayer
        ))
        #expect(middleRestored.presentation == .middleAndDetail)
        #expect(!middleRestored.middleWasAutoHidden)
        #expect(middleRestored.sidebarWasAutoHidden)

        let belowSidebarFit = middleRestored.reconciled(with: metrics(
            splitWidth: 959,
            middleWidth: 320,
            player: fittingPlayer
        ))
        #expect(belowSidebarFit.presentation == .middleAndDetail)

        let allRestored = middleRestored.reconciled(with: metrics(
            splitWidth: 960,
            middleWidth: 320,
            player: fittingPlayer
        ))
        #expect(allRestored.presentation == .allColumns)
        #expect(!allRestored.sidebarWasAutoHidden)
    }

    @Test func manuallyHiddenSidebarDoesNotReopen() {
        let manuallyHidden = ResponsiveSplitLayoutState().userSelected(.middleAndDetail)
        let detailOnly = manuallyHidden.reconciled(with: metrics(
            splitWidth: 650,
            middleWidth: 260,
            player: overflowingPlayer
        ))
        #expect(detailOnly.presentation == .detailOnly)
        #expect(!detailOnly.sidebarWasAutoHidden)
        #expect(detailOnly.middleWasAutoHidden)

        let middleRestored = detailOnly.reconciled(with: metrics(
            splitWidth: 1_200,
            middleWidth: 260,
            player: fittingPlayer
        ))
        #expect(middleRestored.presentation == .middleAndDetail)

        let remainsManuallyHidden = middleRestored.reconciled(with: metrics(
            splitWidth: 1_400,
            middleWidth: 320,
            player: fittingPlayer
        ))
        #expect(remainsManuallyHidden.presentation == .middleAndDetail)
    }

    @Test func restoreMarginPreventsBoundaryPingPong() {
        let sidebarHidden = ResponsiveSplitLayoutState(
            presentation: .middleAndDetail,
            sidebarWasAutoHidden: true,
            sidebarCollapseWidth: 1_000
        )

        let belowMargin = sidebarHidden.reconciled(with: metrics(
            splitWidth: 1_023,
            middleWidth: 320,
            player: fittingPlayer
        ))
        #expect(belowMargin.presentation == .middleAndDetail)

        let atMargin = sidebarHidden.reconciled(with: metrics(
            splitWidth: 1_024,
            middleWidth: 320,
            player: fittingPlayer
        ))
        #expect(atMargin.presentation == .allColumns)
    }

    @Test func splitItemConfigurationCollapsesOnlyMiddle() {
        let middle = NSSplitViewItem(viewController: NSViewController())
        let detail = NSSplitViewItem(viewController: NSViewController())
        let collapseBehavior = middle.collapseBehavior

        ResponsiveSplitViewInstaller.Coordinator.applyConfiguration(
            middleItem: middle,
            detailItem: detail,
            collapsesMiddleColumn: true,
            originalCollapseBehavior: collapseBehavior
        )

        #expect(middle.isCollapsed)
        #expect(!detail.isCollapsed)

        ResponsiveSplitViewInstaller.Coordinator.applyConfiguration(
            middleItem: middle,
            detailItem: detail,
            collapsesMiddleColumn: false,
            originalCollapseBehavior: collapseBehavior
        )

        #expect(!middle.isCollapsed)
        #expect(middle.collapseBehavior == collapseBehavior)
    }

    private func metrics(
        splitWidth: CGFloat,
        middleWidth: CGFloat,
        player: PlaybackWidthRequirement
    ) -> ResponsiveSplitMetrics {
        ResponsiveSplitMetrics(
            splitWidth: splitWidth,
            middleWidth: middleWidth,
            player: player
        )
    }
}
