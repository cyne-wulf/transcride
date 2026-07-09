import Foundation
import Testing

@Suite("Live transcript display state")
struct LiveTranscriptTests {
    @Test func partialExtendsConfirmedPrefix() {
        let state = LiveTranscript.resolve(
            partial: "hello world and more", confirmed: "hello world"
        )
        #expect(state.confirmed == "hello world")
        #expect(state.volatile == " and more")
        #expect(state.display == "hello world and more")
    }

    @Test func emptyConfirmedIsAllVolatile() {
        let state = LiveTranscript.resolve(partial: "first words", confirmed: "")
        #expect(state.confirmed.isEmpty)
        #expect(state.volatile == "first words")
    }

    @Test func partialEqualToConfirmedHasNoVolatileTail() {
        let state = LiveTranscript.resolve(partial: "all done.", confirmed: "all done.")
        #expect(state.confirmed == "all done.")
        #expect(state.volatile.isEmpty)
        #expect(!state.isEmpty)
    }

    @Test func nonPrefixConfirmedFallsBackToCommonPrefix() {
        // Engines shouldn't revise confirmed text, but if one does, nothing
        // is duplicated or dropped from the display.
        let state = LiveTranscript.resolve(
            partial: "hello there friend", confirmed: "hello then"
        )
        #expect(state.confirmed == "hello the")
        #expect(state.volatile == "re friend")
        #expect(state.display == "hello there friend")
    }

    @Test func tailKeepsNewestTextAndBoundary() {
        let state = LiveTranscript(confirmed: "0123456789", volatile: "abcde")

        let unclipped = state.tail(100)
        #expect(unclipped == state)

        let clipped = state.tail(8)
        #expect(clipped.confirmed == "789")
        #expect(clipped.volatile == "abcde")

        let volatileOnly = state.tail(3)
        #expect(volatileOnly.confirmed.isEmpty)
        #expect(volatileOnly.volatile == "cde")
    }

    @Test func emptyStateIsEmpty() {
        #expect(LiveTranscript().isEmpty)
        #expect(LiveTranscript().display.isEmpty)
    }
}
