import AppKit
import SwiftUI

/// A transparent, non-hit-testing AppKit view that gives NSPopover a stable
/// rectangle inside SwiftUI's native toolbar button label. The button itself
/// remains entirely SwiftUI-owned so AppKit never substitutes its visuals.
struct SortPopoverAnchor: NSViewRepresentable {
    let controller: SortPopoverController

    func makeNSView(context: Context) -> SortPopoverAnchorView {
        let view = SortPopoverAnchorView()
        controller.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: SortPopoverAnchorView, context: Context) {
        controller.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: SortPopoverAnchorView, coordinator: ()) {
        nsView.controller?.detach(from: nsView)
    }
}

final class SortPopoverAnchorView: NSView {
    weak var controller: SortPopoverController?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.anchorHoverChanged(isInside: true)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.anchorHoverChanged(isInside: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class SortPopoverController: NSObject, NSPopoverDelegate {
    private weak var anchorView: SortPopoverAnchorView?
    private let popover: NSPopover
    private var hostingController: NSHostingController<SortFieldChooser>?
    private var selectedOrder: EntrySortOrder?
    private var onSelect: ((EntrySortOrder) -> Void)?
    private var sortActivationRevision = 0
    private var pointerInsideAnchor = false
    private var pointerInsideChooser = false
    private var hoverDismissal: DispatchWorkItem?
    nonisolated(unsafe) private var localEventMonitor: Any?
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    override init() {
        popover = NSPopover()
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 168, height: 112)
    }

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
    }

    func attach(to view: SortPopoverAnchorView) {
        if anchorView !== view {
            anchorView?.controller = nil
            anchorView = view
            view.controller = self
        }
    }

    func detach(from view: SortPopoverAnchorView) {
        guard anchorView === view else { return }
        view.controller = nil
        anchorView = nil
        dismiss()
    }

    func configure(
        selection: EntrySortOrder,
        onSelect: @escaping (EntrySortOrder) -> Void
    ) {
        self.onSelect = onSelect
        guard hostingController == nil || selectedOrder != selection else { return }
        selectedOrder = selection
        let chooser = makeChooser(selection: selection)
        if let hostingController {
            hostingController.rootView = chooser
        } else {
            let hostingController = NSHostingController(rootView: chooser)
            hostingController.preferredContentSize = popover.contentSize
            self.hostingController = hostingController
            popover.contentViewController = hostingController
        }
    }

    /// An already-shown application-defined popover is intentionally left
    /// alone. Repeated toolbar clicks can therefore toggle direction without
    /// entering a menu tracking loop or rebuilding the chooser.
    func presentOrKeepOpen() {
        sortActivationRevision &+= 1
        updateAnchorHoverFromCurrentPointer()
        cancelHoverDismissal()
        guard !popover.isShown else { return }
        guard let anchorView, anchorView.window != nil else { return }
        popover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxY
        )
        installDismissalObservers()
    }

    func dismiss() {
        cancelHoverDismissal()
        pointerInsideChooser = false
        guard popover.isShown else {
            removeDismissalObservers()
            return
        }
        popover.performClose(nil)
        removeDismissalObservers()
    }

    func popoverDidClose(_ notification: Notification) {
        cancelHoverDismissal()
        pointerInsideChooser = false
        removeDismissalObservers()
    }

    func anchorHoverChanged(isInside: Bool) {
        pointerInsideAnchor = isInside
        updateHoverDismissal()
    }

    private func makeChooser(selection: EntrySortOrder) -> SortFieldChooser {
        SortFieldChooser(
            selection: selection,
            onSelect: { [weak self] order in
                guard let self else { return }
                self.onSelect?(order)
                self.dismiss()
            },
            onHoverChanged: { [weak self] isInside in
                guard let self else { return }
                self.pointerInsideChooser = isInside
                self.updateHoverDismissal()
            }
        )
    }

    private func updateAnchorHoverFromCurrentPointer() {
        guard let anchorView, let window = anchorView.window else {
            pointerInsideAnchor = false
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInAnchor = anchorView.convert(pointInWindow, from: nil)
        pointerInsideAnchor = anchorView.bounds.contains(pointInAnchor)
    }

    private func updateHoverDismissal() {
        guard popover.isShown else {
            cancelHoverDismissal()
            return
        }
        if pointerInsideAnchor || pointerInsideChooser {
            cancelHoverDismissal()
        } else {
            scheduleHoverDismissal()
        }
    }

    private func scheduleHoverDismissal() {
        guard hoverDismissal == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverDismissal = nil
            guard !self.pointerInsideAnchor, !self.pointerInsideChooser else { return }
            self.dismiss()
        }
        hoverDismissal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func cancelHoverDismissal() {
        hoverDismissal?.cancel()
        hoverDismissal = nil
    }

    private func installDismissalObservers() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type == .leftMouseUp || event.type == .rightMouseUp {
                if event.window === self.popover.contentViewController?.view.window {
                    return event
                }
                // A local monitor sees mouse-up before SwiftUI dispatches the
                // native Button action. Defer dismissal by one run-loop turn:
                // Sort's action increments this revision, while Queue and all
                // other outside targets leave it unchanged and dismiss.
                let revision = self.sortActivationRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.popover.isShown,
                          self.sortActivationRevision == revision else {
                        return
                    }
                    self.dismiss()
                }
            }
            return event
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    private func removeDismissalObservers() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
    }
}

struct SortFieldChooser: View {
    let selection: EntrySortOrder
    let onSelect: (EntrySortOrder) -> Void
    let onHoverChanged: (Bool) -> Void
    @State private var hoveredOrder: EntrySortOrder?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(EntrySortOrder.allCases, id: \.self) { order in
                Button {
                    onSelect(order)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(selection == order ? 1 : 0)
                            .frame(width: 12)
                        Text(order.displayName)
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(hoveredOrder == order ? Color.white : Color.primary)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(hoveredOrder == order ? Color.accentColor : Color.clear)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { isInside in
                    hoveredOrder = isInside ? order : nil
                }
            }
        }
        .padding(6)
        .frame(width: 168, height: 108)
        .onHover { isInside in
            onHoverChanged(isInside)
        }
    }
}
