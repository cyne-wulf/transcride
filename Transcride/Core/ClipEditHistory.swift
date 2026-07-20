import Foundation

/// Durable audio mutations that can be reversed by swapping a complete
/// canonical version from Recently Deleted. The history stores wrapper names,
/// never audio bytes, so an arbitrarily long clip does not grow app memory.
enum ClipEditOperation: String, Codable, CaseIterable, Sendable {
    case trim
    case extend
    case replace
    case compress
    case restoreVersion

    var displayName: String {
        switch self {
        case .trim: "Trim Audio"
        case .extend: "Extend Recording"
        case .replace: "Replace Audio"
        case .compress: "Compress Audio"
        case .restoreVersion: "Restore Audio Version"
        }
    }

    var transcriptionSource: String {
        switch self {
        case .trim: "trim-undo-redo"
        case .extend: "extension-undo-redo"
        case .replace: "replacement-undo-redo"
        case .compress: "compression-undo-redo"
        case .restoreVersion: "audio-version-undo-redo"
        }
    }
}

struct ClipEditCommand: Codable, Equatable, Sendable {
    var operation: ClipEditOperation
    var versionTrashedName: String
    var createdAt: Date
}

struct ClipEditEntryHistory: Codable, Equatable, Sendable {
    var undo: [ClipEditCommand] = []
    var redo: [ClipEditCommand] = []
}

enum ClipEditDirection: Equatable, Sendable {
    case undo
    case redo
}

/// Per-vault persistent undo/redo ledger. Commands are entry-local and remain
/// valid across relaunch while their referenced Recently Deleted versions
/// still exist. Missing/purged wrappers are pruned on every read.
struct ClipEditHistoryStore: Sendable {
    static let fileName = "clip-edit-history.json"

    private struct FileFormat: Codable {
        var version: Int
        var entries: [RelativePath: ClipEditEntryHistory]
    }

    let vaultRoot: URL

    private var fileURL: URL {
        vaultRoot.appending(path: TranscriptionQueueStore.directoryName, directoryHint: .isDirectory)
            .appending(path: Self.fileName)
    }

    func history(
        for entryPath: RelativePath,
        existingTrashNames: Set<String>
    ) -> ClipEditEntryHistory {
        reconciled(load().entries[entryPath] ?? .init(), existingTrashNames: existingTrashNames)
    }

    func record(
        operation: ClipEditOperation,
        entryPath: RelativePath,
        versionTrashedName: String,
        existingTrashNames: Set<String>,
        createdAt: Date = .now
    ) throws {
        var file = load()
        var entry = reconciled(
            file.entries[entryPath] ?? .init(), existingTrashNames: existingTrashNames
        )
        guard !entry.undo.contains(where: { $0.versionTrashedName == versionTrashedName }),
              !entry.redo.contains(where: { $0.versionTrashedName == versionTrashedName }) else {
            return
        }
        entry.undo.append(.init(
            operation: operation,
            versionTrashedName: versionTrashedName,
            createdAt: createdAt
        ))
        // A mutation after Undo starts a new branch. The old redo files remain
        // recoverable in Recently Deleted but are no longer keyboard-redoable.
        entry.redo.removeAll()
        file.entries[entryPath] = entry
        try save(file)
    }

    func completeSwap(
        direction: ClipEditDirection,
        entryPath: RelativePath,
        restoredVersionName: String,
        displacedVersionName: String,
        existingTrashNames: Set<String>
    ) throws -> ClipEditCommand? {
        var file = load()
        var entry = reconciled(
            file.entries[entryPath] ?? .init(), existingTrashNames: existingTrashNames
        )
        let command: ClipEditCommand?
        switch direction {
        case .undo:
            guard let candidate = entry.undo.last,
                  candidate.versionTrashedName == restoredVersionName else { return nil }
            command = entry.undo.removeLast()
            entry.redo.append(.init(
                operation: candidate.operation,
                versionTrashedName: displacedVersionName,
                createdAt: .now
            ))
        case .redo:
            guard let candidate = entry.redo.last,
                  candidate.versionTrashedName == restoredVersionName else { return nil }
            command = entry.redo.removeLast()
            entry.undo.append(.init(
                operation: candidate.operation,
                versionTrashedName: displacedVersionName,
                createdAt: .now
            ))
        }
        file.entries[entryPath] = entry
        try save(file)
        return command
    }

    func reconcile(existingTrashNames: Set<String>) throws {
        var file = load()
        file.entries = file.entries.compactMapValues { history in
            let value = reconciled(history, existingTrashNames: existingTrashNames)
            return value.undo.isEmpty && value.redo.isEmpty ? nil : value
        }
        try save(file)
    }

    /// Re-keys histories belonging to an entry or folder after it moves.
    /// Destination keys are replaced because a successful filesystem move
    /// guarantees that no live item occupied the destination path.
    func repointEntries(under oldPath: RelativePath, to newPath: RelativePath) throws {
        guard oldPath != newPath, !oldPath.isEmpty else { return }
        var file = load()
        let movedEntries = file.entries.compactMap { path, history -> (RelativePath, ClipEditEntryHistory)? in
            guard let repointed = Self.repointed(path, from: oldPath, to: newPath) else {
                return nil
            }
            return (repointed, history)
        }

        let sourceKeys = file.entries.keys.filter {
            Self.repointed($0, from: oldPath, to: newPath) != nil
        }
        let destinationKeys = file.entries.keys.filter {
            Self.contains($0, under: newPath)
        }
        guard !sourceKeys.isEmpty || !destinationKeys.isEmpty else { return }

        for key in sourceKeys + destinationKeys {
            file.entries.removeValue(forKey: key)
        }
        for (path, history) in movedEntries {
            file.entries[path] = history
        }
        try save(file)
    }

    private func reconciled(
        _ history: ClipEditEntryHistory,
        existingTrashNames: Set<String>
    ) -> ClipEditEntryHistory {
        .init(
            undo: history.undo.filter { existingTrashNames.contains($0.versionTrashedName) },
            redo: history.redo.filter { existingTrashNames.contains($0.versionTrashedName) }
        )
    }

    private func load() -> FileFormat {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder().decode(FileFormat.self, from: data),
              file.version == 1 else {
            return FileFormat(version: 1, entries: [:])
        }
        return file
    }

    private func save(_ file: FileFormat) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(file), to: fileURL)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func contains(_ path: RelativePath, under parent: RelativePath) -> Bool {
        path == parent || path.hasPrefix(parent + "/")
    }

    private static func repointed(
        _ path: RelativePath,
        from oldPath: RelativePath,
        to newPath: RelativePath
    ) -> RelativePath? {
        guard contains(path, under: oldPath) else { return nil }
        let suffix = path.dropFirst(oldPath.count)
        if newPath.isEmpty {
            return suffix.first == "/" ? String(suffix.dropFirst()) : String(suffix)
        }
        return newPath + suffix
    }
}
