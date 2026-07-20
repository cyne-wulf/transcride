import Foundation
import Testing

@Suite("Editor preferences")
struct EditorPreferencesTests {
    @Test func defaultsAndFontBoundsMatchTheEditorContract() {
        var preferences = EditorPreferences()
        #expect(preferences.fontSize == 16)
        #expect(preferences.width == .wide)
        #expect(preferences.editedAlignment == .center)
        #expect(!preferences.focusMode)

        preferences.fontSize = 100
        preferences.normalize()
        #expect(preferences.fontSize == 28)
        preferences.fontSize = 1
        preferences.normalize()
        #expect(preferences.fontSize == 12)
    }

    @Test func storeRoundTripsAndRejectsFutureVersions() throws {
        let suite = "EditorPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let expected = EditorPreferences(
            fontSize: 21,
            width: .narrow,
            editedAlignment: .left,
            focusMode: true
        )
        EditorPreferencesStore.save(expected, defaults: defaults)
        #expect(EditorPreferencesStore.load(defaults: defaults) == expected)

        var future = expected
        future.version = 99
        defaults.set(try JSONEncoder().encode(future), forKey: EditorPreferencesStore.defaultsKey)
        #expect(EditorPreferencesStore.load(defaults: defaults) == EditorPreferences())
    }
}
