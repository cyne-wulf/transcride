import AppKit
import SwiftUI

struct GlobalShortcutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var validationMessages: [GlobalShortcutAction: String] = [:]

    var body: some View {
        Form {
            Section("Global Controls") {
                Toggle("Enable Global Controls", isOn: enabledBinding)
                Text("Global controls work while Transcride is running, even when its window is closed. They stop when you quit Transcride.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keybinds") {
                ForEach(GlobalShortcutAction.allCases) { action in
                    shortcutRow(action)
                }
            }
            .disabled(!model.globalShortcutPreferences.isEnabled)

            Section("Background Access") {
                Toggle(
                    "Show Transcride in menu bar",
                    isOn: menuBarItemBinding
                )
                Toggle(
                    "Show indicator while Transcride is in the background",
                    isOn: indicatorBinding
                )
                Picker("Keep visible after recording", selection: retentionBinding) {
                    ForEach(BackgroundIndicatorRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .disabled(!model.globalShortcutPreferences.showsBackgroundIndicator)
                Text("The indicator stays available for follow-up recordings, or until you hide it from its hover control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Indicator Position") {
                    NotificationCenter.default.post(name: .resetGlobalIndicatorPosition, object: nil)
                }
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    validationMessages.removeAll()
                    model.resetGlobalShortcutPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(action.title)
                Spacer()
                ShortcutCaptureView(
                    chord: model.globalShortcutPreferences.bindings[action] ?? nil,
                    onCapture: { setChord($0, for: action) }
                )
                .frame(width: 150, height: 28)
                Button("Clear") { setChord(nil, for: action) }
                    .disabled((model.globalShortcutPreferences.bindings[action] ?? nil) == nil)
            }
            if let validation = validationMessages[action] {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                registrationLabel(for: action)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func registrationLabel(for action: GlobalShortcutAction) -> some View {
        switch model.globalShortcutService.statuses[action] ?? .disabled {
        case .registered:
            Label("Registered", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .cleared:
            Text("No global shortcut assigned")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .disabled:
            Text("Global controls are disabled")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.isEnabled },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.isEnabled = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var indicatorBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.showsBackgroundIndicator },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.showsBackgroundIndicator = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var menuBarItemBinding: Binding<Bool> {
        Binding(
            get: { model.globalShortcutPreferences.showsMenuBarItem },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.showsMenuBarItem = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private var retentionBinding: Binding<BackgroundIndicatorRetention> {
        Binding(
            get: { model.globalShortcutPreferences.backgroundIndicatorRetention },
            set: { value in
                var preferences = model.globalShortcutPreferences
                preferences.backgroundIndicatorRetention = value
                model.updateGlobalShortcutPreferences(preferences)
            }
        )
    }

    private func setChord(_ chord: GlobalShortcutChord?, for action: GlobalShortcutAction) {
        var preferences = model.globalShortcutPreferences
        if let chord {
            let validation = preferences.validation(for: action, chord: chord)
            guard validation == .valid else {
                validationMessages[action] = validation.message
                return
            }
        }
        validationMessages[action] = nil
        preferences.bindings[action] = chord
        model.updateGlobalShortcutPreferences(preferences)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    var chord: GlobalShortcutChord?
    var onCapture: (GlobalShortcutChord?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = context.coordinator.capture
        view.chord = chord
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        context.coordinator.onCapture = onCapture
        nsView.onCapture = context.coordinator.capture
        nsView.chord = chord
    }

    @MainActor
    final class Coordinator {
        var onCapture: (GlobalShortcutChord?) -> Void

        init(onCapture: @escaping (GlobalShortcutChord?) -> Void) {
            self.onCapture = onCapture
        }

        func capture(_ chord: GlobalShortcutChord?) {
            onCapture(chord)
        }
    }
}

@MainActor
private final class ShortcutCaptureNSView: NSView {
    var chord: GlobalShortcutChord? { didSet { updateLabel() } }
    var onCapture: ((GlobalShortcutChord?) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isCapturing = false

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
        setAccessibilityLabel("Record global shortcut")
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: GlobalShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        onCapture?(GlobalShortcutChord(keyCode: UInt32(event.keyCode), modifiers: modifiers))
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

extension Notification.Name {
    static let resetGlobalIndicatorPosition = Notification.Name("resetGlobalIndicatorPosition")
}
