import Testing

@Suite("List selection navigation")
struct ListSelectionNavigatorTests {
    private let ids = ["one", "two", "three"]

    @Test func movesToAdjacentRows() {
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: "two", offset: 1
        ) == "three")
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: "two", offset: -1
        ) == "one")
    }

    @Test func startsAtTheDirectionalEdgeWithoutASelection() {
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: nil, offset: 1
        ) == "one")
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: nil, offset: -1
        ) == "three")
    }

    @Test func clampsAtListBoundaries() {
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: "one", offset: -1
        ) == "one")
        #expect(ListSelectionNavigator.adjacentID(
            in: ids, selectedID: "three", offset: 1
        ) == "three")
    }

    @Test func emptyListsDoNotConsumeSelection() {
        #expect(ListSelectionNavigator.adjacentID(
            in: [String](), selectedID: nil, offset: 1
        ) == nil)
    }
}
