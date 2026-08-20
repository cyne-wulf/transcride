import AppKit
import SwiftUI

/// Click-to-record shortcut capture control shared by the App Shortcuts and
/// Global Controls settings. While it is first responder it owns the keyboard:
/// `onCaptureStateChange(true)` lets the app suppress normal command dispatch
/// so a captured chord never fires the command it is being assigned to.
/// Delete/forward-delete clears the binding; Escape cancels capture.
struct ShortcutCaptureField: NSViewRepresentable {
    var chord: ShortcutChord?
    var onCapture: (ShortcutChord?) -> Void
    var onCaptureStateChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCaptureStateChange: onCaptureStateChange)
    }

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = context.coordinator.capture
        view.onCaptureStateChange = context.coordinator.captureStateChanged
        view.chord = chord
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onCaptureStateChange = onCaptureStateChange
        nsView.onCapture = context.coordinator.capture
        nsView.onCaptureStateChange = context.coordinator.captureStateChanged
        nsView.chord = chord
    }

    /// A SwiftUI teardown that never moves the view between windows must not
    /// strand `isShortcutCaptureActive` at true.
    static func dismantleNSView(_ nsView: ShortcutCaptureNSView, coordinator: Coordinator) {
        nsView.teardown()
    }

    @MainActor
    final class Coordinator {
        var onCapture: (ShortcutChord?) -> Void
        var onCaptureStateChange: ((Bool) -> Void)?

        init(
            onCapture: @escaping (ShortcutChord?) -> Void,
            onCaptureStateChange: ((Bool) -> Void)?
        ) {
            self.onCapture = onCapture
            self.onCaptureStateChange = onCaptureStateChange
        }

        func capture(_ chord: ShortcutChord?) {
            onCapture(chord)
        }

        func captureStateChanged(_ capturing: Bool) {
            onCaptureStateChange?(capturing)
        }
    }
}

@MainActor
final class ShortcutCaptureNSView: NSView {
    var chord: ShortcutChord? { didSet { updateLabel() } }
    var onCapture: ((ShortcutChord?) -> Void)?
    var onCaptureStateChange: ((Bool) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var windowKeyObserver: NSObjectProtocol?
    private var isCapturing = false {
        didSet {
            guard isCapturing != oldValue else { return }
            onCaptureStateChange?(isCapturing)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record shortcut")
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isCapturing = true
        updateLabel()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isCapturing = false
        updateLabel()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeWindowKeyObserver()
        if newWindow == nil { isCapturing = false }
    }

    /// First-responder status is per window: AppKit leaves this view as the
    /// Settings window's first responder when that window merely stops being
    /// key (the user clicks the main window, switches apps, ⌘-tabs). Without
    /// this observer, capture mode — and the app-wide command suppression it
    /// drives through `isShortcutCaptureActive` — would stay armed until the
    /// user returned to Settings and clicked elsewhere.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCapture() }
        }
    }

    /// A tab switch can hide this view without removing it from the window.
    override func viewDidHide() {
        super.viewDidHide()
        endCapture()
    }

    /// Routes through the responder chain so the normal `resignFirstResponder`
    /// path runs; the assignment is idempotent (the `didSet` guards on change)
    /// and covers the windowless case.
    func endCapture() {
        guard isCapturing else { return }
        window?.makeFirstResponder(nil)
        isCapturing = false
        updateLabel()
    }

    func teardown() {
        removeWindowKeyObserver()
        endCapture()
    }

    private func removeWindowKeyObserver() {
        guard let windowKeyObserver else { return }
        NotificationCenter.default.removeObserver(windowKeyObserver)
        self.windowKeyObserver = nil
    }

    /// AppKit offers every key-down to the key window's view tree and then the
    /// menu bar as a key equivalent *before* normal `keyDown` dispatch, so a
    /// chord that matches a menu item (⌘N, ⌘E, ⌥M, …) would fire that command
    /// instead of being recorded. While capturing, claim the event here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Unmodified Delete clears the slot; a modified delete chord (⌘⌫, ⇧⌫)
        // is a recordable binding.
        if event.keyCode == 51 || event.keyCode == 117,
           flags.intersection([.command, .option, .control, .shift]).isEmpty {
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = ShortcutModifiers(cocoaFlags: UInt(
            flags.subtracting([.numericPad, .function]).rawValue
        ))
        onCapture?(ShortcutChord(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (isCapturing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        super.draw(dirtyRect)
    }

    private func updateLabel() {
        label.stringValue = isCapturing ? "Press shortcut…" : (chord?.glyphDescription ?? "Not Set")
        setAccessibilityValue(label.stringValue)
        needsDisplay = true
    }
}
