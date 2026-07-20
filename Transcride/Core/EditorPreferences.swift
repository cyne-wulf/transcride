import Foundation

extension EditorWidthPreset: CaseIterable, Identifiable {
    static let allCases: [EditorWidthPreset] = [.narrow, .wide, .full]
    var id: Self { self }

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .wide: "Wide"
        case .full: "Full"
        }
    }

    var maximumWidth: Double? {
        switch self {
        case .narrow: 620
        case .wide: 800
        case .full: nil
        }
    }
}

extension EditorAlignment: CaseIterable, Identifiable {
    static let allCases: [EditorAlignment] = [.center, .left]
    var id: Self { self }
    var title: String { self == .center ? "Center" : "Left" }
}

struct EditorPreferences: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultFontSize = 16
    static let minimumFontSize = 12
    static let maximumFontSize = 28

    var version = currentVersion
    var fontSize = defaultFontSize
    var width: EditorWidthPreset = .wide
    var editedAlignment: EditorAlignment = .center
    var focusMode = false

    mutating func normalize() {
        version = Self.currentVersion
        fontSize = min(max(fontSize, Self.minimumFontSize), Self.maximumFontSize)
    }

    mutating func stepFontSize(by delta: Int) {
        fontSize = min(max(fontSize + delta, Self.minimumFontSize), Self.maximumFontSize)
    }
}

enum EditorPreferencesStore {
    static let defaultsKey = "editorPreferencesV1"

    static func load(defaults: UserDefaults = .standard) -> EditorPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              var preferences = try? JSONDecoder().decode(EditorPreferences.self, from: data),
              (1...EditorPreferences.currentVersion).contains(preferences.version)
        else { return EditorPreferences() }
        preferences.normalize()
        return preferences
    }

    static func save(
        _ preferences: EditorPreferences,
        defaults: UserDefaults = .standard
    ) {
        var normalized = preferences
        normalized.normalize()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
