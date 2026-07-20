import Foundation
import Testing

@Suite("Quick Move")
struct QuickMoveTests {
    @Test func enumeratesRootAndNestedFoldersWhileExcludingCurrentParent() {
        let root = FolderNode(
            relativePath: "",
            name: "Vault",
            subfolders: [
                FolderNode(relativePath: "Archive", name: "Archive", subfolders: [], entries: []),
                FolderNode(
                    relativePath: "Journal",
                    name: "Journal",
                    subfolders: [
                        FolderNode(
                            relativePath: "Journal/Ideas",
                            name: "Ideas",
                            subfolders: [],
                            entries: []
                        ),
                        FolderNode(
                            relativePath: "Journal/Meetings",
                            name: "Meetings",
                            subfolders: [],
                            entries: []
                        ),
                    ],
                    entries: []
                ),
            ],
            entries: []
        )

        let catalog = QuickMoveDestinationCatalog(
            root: root,
            movingEntryAt: "Journal/transcride-2026-07-17T10-00-00-note"
        )

        #expect(catalog.destinations.map(\.relativePath) == [
            "", "Archive", "Journal/Ideas", "Journal/Meetings",
        ])
        #expect(catalog.destinations.first?.displayName == "Vault Root")
    }

    @Test func emptyQueryUsesRootFirstNaturalOrderAndDeduplicates() {
        let catalog = QuickMoveDestinationCatalog(
            folderPaths: ["Folder 10", "", "Folder 2", "Folder 2", "Current"],
            excludingCurrentParent: "Current"
        )

        #expect(catalog.filteredDestinations(for: "   ").map(\.relativePath) == [
            "", "Folder 2", "Folder 10",
        ])
    }

    @Test func ranksLeafAndPathMatchesDeterministically() {
        let catalog = QuickMoveDestinationCatalog(
            folderPaths: [
                "Other/Idaes",
                "Personal/Ideas/Archive",
                "Personal/Big Ideas Folder",
                "Ideas/Archive",
                "Ideas Archive",
                "Journal/Ideas",
            ],
            excludingCurrentParent: "Unrelated"
        )

        let matches = catalog.rankedMatches(for: "ideas")
        #expect(matches.map(\.destination.relativePath) == [
            "Journal/Ideas",
            "Ideas Archive",
            "Ideas/Archive",
            "Personal/Big Ideas Folder",
            "Personal/Ideas/Archive",
            "Other/Idaes",
        ])
        #expect(matches.map(\.kind) == [
            .leafExact, .leafPrefix, .pathPrefix, .leafSubstring, .pathSubstring,
            .leafFuzzy,
        ])
    }

    @Test func fullPathSearchTreatsSlashAndSpaceEqually() throws {
        let catalog = QuickMoveDestinationCatalog(
            folderPaths: ["Journal/Ideas", "Journal/Ideas Archive"],
            excludingCurrentParent: ""
        )

        let match = try #require(catalog.rankedMatches(for: "journal ideas").first)
        #expect(match.destination.relativePath == "Journal/Ideas")
        #expect(match.kind == .pathExact)
    }

    @Test func fuzzySearchSupportsTyposAndOrderedAbbreviations() throws {
        let catalog = QuickMoveDestinationCatalog(
            folderPaths: ["Meetings", "Work/Research Notes"],
            excludingCurrentParent: ""
        )

        let typo = try #require(catalog.rankedMatches(for: "Mettings").first)
        #expect(typo.destination.relativePath == "Meetings")
        #expect(typo.kind == .leafFuzzy)

        let abbreviated = try #require(catalog.rankedMatches(for: "wrk rsrch").first)
        #expect(abbreviated.destination.relativePath == "Work/Research Notes")
        #expect(abbreviated.kind == .pathFuzzy)
        #expect(catalog.filteredDestinations(for: "zzzzzz").isEmpty)
    }

    @Test func typedFailuresClassifyVaultErrorsForInlinePresentation() throws {
        #expect(QuickMoveFailure.classify(
            VaultError.notFound("Inbox/entry"),
            sourcePath: "Inbox/entry",
            destinationFolder: "Archive"
        ) == .sourceMissing("Inbox/entry"))
        #expect(QuickMoveFailure.classify(
            VaultError.notFound("Archive"),
            sourcePath: "Inbox/entry",
            destinationFolder: "Archive"
        ) == .destinationMissing("Archive"))
        #expect(QuickMoveFailure.classify(
            VaultError.alreadyExists("entry"),
            sourcePath: "Inbox/entry",
            destinationFolder: "Archive"
        ) == .destinationCollision(entryName: "entry", destinationFolder: "Archive"))

        let success = QuickMoveSuccess(
            sourcePath: "Inbox/entry",
            destinationFolder: "Archive",
            movedPath: "Archive/entry"
        )
        let result: QuickMoveResult = .success(success)
        #expect(try result.get() == success)
    }

    @Test func selectionReconcilesAndArrowMovementClampsDeterministically() {
        let paths = ["Archive", "Journal", "Projects"]
        #expect(QuickMoveSelection.reconciled(
            current: "Journal", destinationPaths: paths
        ) == "Journal")
        #expect(QuickMoveSelection.reconciled(
            current: "Deleted", destinationPaths: paths
        ) == "Archive")
        #expect(QuickMoveSelection.reconciled(
            current: nil, destinationPaths: []
        ) == nil)

        #expect(QuickMoveSelection.moved(
            current: nil, destinationPaths: paths, offset: 1
        ) == "Archive")
        #expect(QuickMoveSelection.moved(
            current: "Deleted", destinationPaths: paths, offset: -1
        ) == "Archive")
        #expect(QuickMoveSelection.moved(
            current: "Archive", destinationPaths: paths, offset: -1
        ) == "Archive")
        #expect(QuickMoveSelection.moved(
            current: "Projects", destinationPaths: paths, offset: 1
        ) == "Projects")
        #expect(QuickMoveSelection.moved(
            current: "Journal", destinationPaths: paths, offset: 1
        ) == "Projects")
        #expect(QuickMoveSelection.moved(
            current: nil, destinationPaths: [], offset: 1
        ) == nil)
    }

    @Test func movesNestedEntryAndPreservesVisibleAndHiddenContents() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)

        let moved = try operations.moveItem(
            at: fixture.entryPath,
            toFolder: "Destinations/Deep"
        )

        #expect(moved == "Destinations/Deep/\(fixture.entryName)")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingRelativePath(fixture.entryPath).path
        ))
        let movedURL = fixture.root.appendingRelativePath(moved)
        #expect(try String(
            contentsOf: movedURL.appending(path: "transcript.md"),
            encoding: .utf8
        ) == "visible transcript")
        #expect(try Data(
            contentsOf: movedURL.appending(path: "audio.m4a")
        ) == Data([0x01, 0x02, 0x03]))
        #expect(try String(
            contentsOf: movedURL.appending(path: ".transcride-replacements/recipe-v1.json"),
            encoding: .utf8
        ) == "hidden recipe")
        #expect(try String(
            contentsOf: movedURL.appending(path: ".recording-session.json"),
            encoding: .utf8
        ) == "hidden session")
    }

    @Test func movesNestedEntryBackToVaultRoot() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)

        let moved = try operations.moveItem(at: fixture.entryPath, toFolder: "")

        #expect(moved == fixture.entryName)
        #expect(FileManager.default.fileExists(
            atPath: fixture.root
                .appendingRelativePath(moved)
                .appending(path: "transcript.md").path
        ))
    }

    @Test func sameFolderMoveIsANoopOnlyForAnExistingSource() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)

        #expect(try operations.moveItem(
            at: fixture.entryPath,
            toFolder: fixture.entryPath.parentRelativePath
        ) == fixture.entryPath)

        do {
            _ = try operations.moveItem(at: "Inbox/missing-entry", toFolder: "Inbox")
            Issue.record("A missing same-folder source must not report a successful no-op")
        } catch VaultError.notFound(let path) {
            #expect(path == "Inbox/missing-entry")
        }
    }

    @Test func missingOrNonDirectoryDestinationLeavesSourceUntouched() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)

        do {
            _ = try operations.moveItem(at: fixture.entryPath, toFolder: "Gone")
            Issue.record("A missing destination must fail")
        } catch VaultError.notFound(let path) {
            #expect(path == "Gone")
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingRelativePath(fixture.entryPath).path
        ))

        try AtomicFile.write("not a directory", to: fixture.root.appending(path: "File Target"))
        do {
            _ = try operations.moveItem(at: fixture.entryPath, toFolder: "File Target")
            Issue.record("A file must not be accepted as a destination folder")
        } catch VaultError.notFound(let path) {
            #expect(path == "File Target")
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingRelativePath(fixture.entryPath).path
        ))
    }

    @Test func sourceReplacedByARegularFileIsNeverReportedAsAMovedEntry() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)
        let sourceURL = fixture.root.appendingRelativePath(fixture.entryPath)
        try FileManager.default.removeItem(at: sourceURL)
        try AtomicFile.write("external replacement", to: sourceURL)

        do {
            _ = try operations.moveItem(
                at: fixture.entryPath,
                toFolder: "Destinations/Deep"
            )
            Issue.record("A regular file cannot stand in for an entry directory")
        } catch VaultError.notFound(let path) {
            #expect(path == fixture.entryPath)
        }
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "external replacement")
    }

    @Test func collisionNeverOverwritesEitherEntry() throws {
        let fixture = try moveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operations = VaultOperations(vaultRoot: fixture.root)
        let occupiedURL = fixture.root
            .appendingRelativePath("Destinations/Deep")
            .appending(path: fixture.entryName)
        try FileManager.default.createDirectory(at: occupiedURL, withIntermediateDirectories: false)
        try AtomicFile.write("occupant", to: occupiedURL.appending(path: "marker.txt"))

        do {
            _ = try operations.moveItem(
                at: fixture.entryPath,
                toFolder: "Destinations/Deep"
            )
            Issue.record("A destination collision must fail")
        } catch VaultError.alreadyExists(let name) {
            #expect(name == fixture.entryName)
        }

        #expect(try String(
            contentsOf: fixture.root
                .appendingRelativePath(fixture.entryPath)
                .appending(path: "transcript.md"),
            encoding: .utf8
        ) == "visible transcript")
        #expect(try String(
            contentsOf: occupiedURL.appending(path: "marker.txt"),
            encoding: .utf8
        ) == "occupant")
    }

    private struct MoveFixture {
        var root: URL
        var entryPath: RelativePath
        var entryName: String
    }

    private func moveFixture() throws -> MoveFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "quick-move-\(UUID().uuidString)")
        let entryName = "transcride-2026-07-17T10-00-00-complete"
        let entryPath = "Inbox/\(entryName)"
        let entryURL = root.appendingRelativePath(entryPath)
        try FileManager.default.createDirectory(
            at: entryURL.appending(path: ".transcride-replacements"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingRelativePath("Destinations/Deep"),
            withIntermediateDirectories: true
        )
        try AtomicFile.write("visible transcript", to: entryURL.appending(path: "transcript.md"))
        try AtomicFile.write(Data([0x01, 0x02, 0x03]), to: entryURL.appending(path: "audio.m4a"))
        try AtomicFile.write(
            "hidden recipe",
            to: entryURL.appending(path: ".transcride-replacements/recipe-v1.json")
        )
        try AtomicFile.write(
            "hidden session",
            to: entryURL.appending(path: ".recording-session.json")
        )
        return MoveFixture(root: root, entryPath: entryPath, entryName: entryName)
    }
}
