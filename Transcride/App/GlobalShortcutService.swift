import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class GlobalShortcutService {
    typealias ActionHandler = @MainActor (GlobalShortcutAction) -> Void

    private(set) var statuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus] = [:]
    var onAction: ActionHandler?

    private var registrations: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var activePreferences: GlobalShortcutPreferences?
    private var eventHandler: EventHandlerRef?
    private var pressedActions: Set<GlobalShortcutAction> = []

    init() {
        installEventHandler()
    }

    func apply(_ preferences: GlobalShortcutPreferences) {
        guard preferences.isEnabled else {
            unregisterAll()
            activePreferences = preferences
            statuses = Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map {
                ($0, .disabled)
            })
            return
        }

        let previous = activePreferences
        unregisterAll()
        let result = register(preferences)
        if result.failedAction == nil {
            activePreferences = preferences
            statuses = result.statuses
            return
        }

        unregisterAll()
        if let previous, previous.isEnabled {
            _ = register(previous)
            activePreferences = previous
        }
        statuses = result.statuses
    }

    func shutdown() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        activePreferences = nil
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard readStatus == noErr,
                      hotKeyID.signature == GlobalShortcutService.signature,
                      let action = GlobalShortcutService.action(for: hotKeyID.id)
                else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<GlobalShortcutService>
                    .fromOpaque(userData).takeUnretainedValue()
                let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                Task { @MainActor in
                    service.receiveHotKeyEvent(action: action, isPressed: isPressed)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            statuses = Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map {
                ($0, .failed("The system hotkey handler could not start (OSStatus \(status))."))
            })
        }
    }

    func receiveHotKeyEvent(action: GlobalShortcutAction, isPressed: Bool) {
        if isPressed {
            guard pressedActions.insert(action).inserted else { return }
            onAction?(action)
        } else {
            pressedActions.remove(action)
        }
    }

    private func register(
        _ preferences: GlobalShortcutPreferences
    ) -> (statuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus], failedAction: GlobalShortcutAction?) {
        var newStatuses: [GlobalShortcutAction: GlobalShortcutRegistrationStatus] = [:]
        var failedAction: GlobalShortcutAction?

        for action in GlobalShortcutAction.allCases {
            guard let chord = preferences.bindings[action] ?? nil else {
                newStatuses[action] = .cleared
                continue
            }
            guard preferences.validation(for: action, chord: chord) == .valid else {
                newStatuses[action] = .failed(
                    preferences.validation(for: action, chord: chord).message ?? "Invalid shortcut."
                )
                failedAction = failedAction ?? action
                continue
            }

            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                chord.keyCode,
                carbonModifiers(chord.modifiers),
                EventHotKeyID(signature: Self.signature, id: Self.identifier(for: action)),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registrations[action] = reference
                newStatuses[action] = .registered
            } else {
                newStatuses[action] = .failed(Self.failureMessage(for: status))
                failedAction = failedAction ?? action
            }
        }
        return (newStatuses, failedAction)
    }

    private func unregisterAll() {
        for registration in registrations.values { UnregisterEventHotKey(registration) }
        registrations.removeAll()
        pressedActions.removeAll()
    }

    private func carbonModifiers(_ modifiers: GlobalShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let signature: OSType = 0x54524344 // TRCD

    private static func identifier(for action: GlobalShortcutAction) -> UInt32 {
        switch action {
        case .toggleRecording: 1
        case .pauseResumeRecording: 2
        }
    }

    private static func action(for identifier: UInt32) -> GlobalShortcutAction? {
        switch identifier {
        case 1: .toggleRecording
        case 2: .pauseResumeRecording
        default: nil
        }
    }

    private static func failureMessage(for status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "That shortcut is reserved by macOS or another application."
        }
        return "The shortcut could not be registered (OSStatus \(status))."
    }
}

enum GlobalShortcutPreferencesStore {
    static let defaultsKey = "globalShortcutPreferencesV2"

    static func load(defaults: UserDefaults = .standard) -> GlobalShortcutPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(
                GlobalShortcutPreferences.self, from: data
              ),
              preferences.version == GlobalShortcutPreferences.currentVersion
        else { return .defaults }
        return preferences
    }

    static func save(
        _ preferences: GlobalShortcutPreferences,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
