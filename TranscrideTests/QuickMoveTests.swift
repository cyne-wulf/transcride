import Foundation
import Testing

@Suite("Quick Move destination model")
struct QuickMoveTests {
    private let folders = [
        "Projects", "Projects/Archive", "Projects/Active", "Journal",
        "Folder 2", "Folder 10", "Meetings",
    ]

    @Test func destinationsPutVaultRootFirstAndSortNaturally() throws {
        let destinations = QuickMoveModel.destinations(
            folderPaths: folders,
            excludingParentOf: "Journal/transcride-20260701-090000-note"
        )
        #expect(destinations.first?.isVaultRoot == true)
        #expect(destinations.first?.title == "Vault Root")
        let paths = destinations.map(\.path)
        #expect(!paths.contains("Journal"))
        // Natural sort: Folder 2 before Folder 10.
        let folder2 = try #require(paths.firstIndex(of: "Folder 2"))
        let folder10 = try #require(paths.firstIndex(of: "Folder 10"))
        #expect(folder2 < folder10)
        #expect(paths.contains("Projects/Archive"))
    }

    @Test func destinationsExcludeCurrentParent() {
        let nested = QuickMoveModel.destinations(
            folderPaths: folders,
            excludingParentOf: "Projects/Archive/transcride-20260701-090000-note"
        )
        #expect(!nested.map(\.path).contains("Projects/Archive"))
        #expect(nested.map(\.path).contains("Projects"))
        #expect(nested.first?.isVaultRoot == true)

        // An entry already at the vault root cannot move to the root again.
        let atRoot = QuickMoveModel.destinations(
            folderPaths: folders,
            excludingParentOf: "transcride-20260701-090000-note"
        )
        #expect(!atRoot.contains { $0.isVaultRoot })
        #expect(atRoot.count == folders.count)
    }

    @Test func destinationsDeduplicateAndHandleEmptyVault() {
        let deduped = QuickMoveModel.destinations(
            folderPaths: ["A", "A", "B"],
            excludingParentOf: "B/transcride-x"
        )
        #expect(deduped.map(\.path) == ["", "A"])

        let empty = QuickMoveModel.destinations(
            folderPaths: [],
            excludingParentOf: "transcride-x"
        )
        #expect(empty.isEmpty)
    }

    @Test func emptyQueryKeepsNaturalOrder() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: folders, excludingParentOf: "x/entry"
        )
        #expect(QuickMoveModel.filtered(destinations, query: "") == destinations)
        #expect(QuickMoveModel.filtered(destinations, query: "   ") == destinations)
    }

    @Test func filterRanksLeafMatchesOverPathMatchesDeterministically() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: [
                "Archive", "Projects/Archive", "Archive Old", "Projects/Old Archive",
            ],
            excludingParentOf: "x/entry"
        )
        let results = QuickMoveModel.filtered(destinations, query: "archive").map(\.path)
        // Leaf exact matches first (natural order among equals), then leaf
        // prefix, then leaf substring.
        #expect(results.first == "Archive")
        #expect(results.contains("Projects/Archive"))
        let leafExactSecond = results[1]
        #expect(leafExactSecond == "Projects/Archive") // also an exact leaf match
        #expect(results.firstIndex(of: "Archive Old")! < results.firstIndex(of: "Projects/Old Archive")!)
        #expect(results.count == 4)
    }

    @Test func filterMatchesFullPathsAndPrefixes() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: ["Projects/Active", "Journal"],
            excludingParentOf: "x/entry"
        )
        let byPath = QuickMoveModel.filtered(destinations, query: "projects/ac").map(\.path)
        #expect(byPath == ["Projects/Active"])
    }

    @Test func filterFallsBackToFuzzySubsequence() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: ["Projects", "Journal", "Meetings"],
            excludingParentOf: "x/entry"
        )
        let fuzzy = QuickMoveModel.filtered(destinations, query: "prj").map(\.path)
        #expect(fuzzy == ["Projects"])
        // Substring beats fuzzy when both exist.
        let mixed = QuickMoveModel.filtered(
            QuickMoveModel.destinations(
                folderPaths: ["Praj", "Parajun"], excludingParentOf: "x/entry"
            ),
            query: "praj"
        ).map(\.path)
        #expect(mixed == ["Praj", "Parajun"])
    }

    @Test func filterIsCaseInsensitiveAndExcludesNonMatches() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: ["Projects", "Journal"],
            excludingParentOf: "x/entry"
        )
        #expect(QuickMoveModel.filtered(destinations, query: "JOURNAL").map(\.path) == ["Journal"])
        #expect(QuickMoveModel.filtered(destinations, query: "zzz").isEmpty)
    }

    @Test func vaultRootMatchesItsDisplayName() {
        let destinations = QuickMoveModel.destinations(
            folderPaths: ["Projects"], excludingParentOf: "Projects/entry"
        )
        let results = QuickMoveModel.filtered(destinations, query: "vault")
        #expect(results.map(\.path) == [""])
    }

    @Test func outcomeMessagesExplainFailuresAndSuccessIsSilent() {
        #expect(QuickMoveOutcome.moved("A/entry").isSuccess)
        #expect(QuickMoveOutcome.moved("A/entry").errorDescription == nil)
        #expect(QuickMoveOutcome.destinationMissing.errorDescription?.contains("no longer exists") == true)
        #expect(QuickMoveOutcome.collision("entry").errorDescription?.contains("already exists") == true)
        #expect(QuickMoveOutcome.failed("boom").errorDescription == "boom")
        #expect(!QuickMoveOutcome.destinationMissing.isSuccess)
    }
}
