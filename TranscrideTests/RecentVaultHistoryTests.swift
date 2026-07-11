import Testing

@Suite("Recent vault history")
struct RecentVaultHistoryTests {
    @Test func recordsMostRecentFirstAndLimitsToThree() {
        var paths: [String] = []
        paths = RecentVaultHistory.recording("/Vaults/One", in: paths)
        paths = RecentVaultHistory.recording("/Vaults/Two", in: paths)
        paths = RecentVaultHistory.recording("/Vaults/Three", in: paths)
        paths = RecentVaultHistory.recording("/Vaults/Four", in: paths)

        #expect(paths == ["/Vaults/Four", "/Vaults/Three", "/Vaults/Two"])
    }

    @Test func reopeningMovesVaultToFrontWithoutDuplicatingIt() {
        let paths = RecentVaultHistory.recording(
            "/Vaults/One",
            in: ["/Vaults/Three", "/Vaults/Two", "/Vaults/One"]
        )

        #expect(paths == ["/Vaults/One", "/Vaults/Three", "/Vaults/Two"])
    }

    @Test func forgettingRemovesOnlyTheChosenVault() {
        let paths = RecentVaultHistory.forgetting(
            "/Vaults/Two",
            in: ["/Vaults/Three", "/Vaults/Two", "/Vaults/One"]
        )

        #expect(paths == ["/Vaults/Three", "/Vaults/One"])
    }
}
