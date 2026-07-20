import AppKit
import SwiftUI

/// A reusable physical-key recorder for both in-app and Carbon shortcuts.
/// Clearing is deliberately kept outside this control so Delete can itself
/// be recorded when paired with a valid modifier.
struct ShortcutCaptureField: NSViewRepresentable {
    var chord: ShortcutChord?
    var accessibilityLabel: String
    var onCaptureStateChange: (Bool) -> Void
    var onCapture: (ShortcutChord) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCaptureStateChange: onCaptureStateChange,
            onCapture: onCapture
        )
    }

    func makeNSView(context: Context) -> ShortcutCaptureFieldNSView {
        let view = ShortcutCaptureFieldNSView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(
        _ nsView: ShortcutCaptureFieldNSView,
        context: Context
    ) {
        context.coordinator.onCaptureStateChange = onCaptureStateChange
        context.coordinator.onCapture = onCapture
        configure(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ nsView: ShortcutCaptureFieldNSView,
        coordinator: Coordinator
    ) {
        nsView.finishCapture()
    }

    private func configure(
        _ view: ShortcutCaptureFieldNSView,
        coordinator: Coordinator
    ) {
        view.chord = chord
        view.captureAccessibilityLabel = accessibilityLabel
        view.onCaptureStateChange = coordinator.captureStateChanged
        view.onCapture = coordinator.capture
    }

    @MainActor
    final class Coordinator {
        var onCaptureStateChange: (Bool) -> Void
        var onCapture: (ShortcutChord) -> Void

        init(
            onCaptureStateChange: @escaping (Bool) -> Void,
            onCapture: @escaping (ShortcutChord) -> Void
        ) {
            self.onCaptureStateChange = onCaptureStateChange
            self.onCapture = onCapture
        }

        func captureStateChanged(_ isCapturing: Bool) {
            onCaptureStateChange(isCapturing)
        }

        func capture(_ chord: ShortcutChord) {
            onCapture(chord)
        }
    }
}

@MainActor
final class ShortcutCaptureFieldNSView: NSView {
    var chord: ShortcutChord? { didSet { updateLabel() } }
    var captureAccessibilityLabel = "Record shortcut" {
        didSet { setAccessibilityLabel(captureAccessibilityLabel) }
    }
    var onCaptureStateChange: ((Bool) -> Void)?
    var onCapture: ((ShortcutChord) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isCapturing = false
    private var modifierOnlyCandidate: ShortcutModifiers?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
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
        setAccessibilityLabel(captureAccessibilityLabel)
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        setCapturing(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        modifierOnlyCandidate = nil
        setCapturing(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    /// Command-key events normally go through the main menu before AppKit
    /// sends `keyDown` to the first responder. Capture them here so a reserved
    /// chord such as Command-C is recorded and validated instead of silently
    /// invoking Copy.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        // Escape cancels capture without changing the stored assignment.
        guard event.keyCode != 53 else {
            finishCapture()
            return
        }

        let chord = ShortcutChord(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.shortcutModifiers(from: event.modifierFlags)
        )
        onCapture?(chord)
        finishCapture()
    }

    override func flagsChanged(with event: NSEvent) {
        let modifiers = Self.shortcutModifiers(from: event.modifierFlags)
        if !modifiers.isEmpty {
            modifierOnlyCandidate = modifiers
        } else if let modifierOnlyCandidate {
            onCapture?(
                ShortcutChord(
                    keyCode: ShortcutChord.modifierOnlyKeyCode,
                    modifiers: modifierOnlyCandidate
                )
            )
            finishCapture()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (
            isCapturing ? NSColor.controlAccentColor : NSColor.separatorColor
        ).cgColor
        super.draw(dirtyRect)
    }

    func finishCapture() {
        modifierOnlyCandidate = nil
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        } else {
            setCapturing(false)
        }
    }

    private func setCapturing(_ newValue: Bool) {
        guard isCapturing != newValue else { return }
        isCapturing = newValue
        onCaptureStateChange?(newValue)
        updateLabel()
    }

    private func updateLabel() {
        label.stringValue = isCapturing
            ? "Press shortcut…"
            : (chord?.glyphDescription ?? "Not Set")
        setAccessibilityValue(label.stringValue)
        needsDisplay = true
    }

    private static func shortcutModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> ShortcutModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
