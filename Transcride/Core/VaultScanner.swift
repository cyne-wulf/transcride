import Foundation

/// Scans the vault directory tree into a `VaultSnapshot`. Entry metadata reads
/// are cached by modification date so repeated scans (FSEvents refreshes)
/// only re-read what actually changed. Runs off the main thread (inside
/// `VaultService`); purely read-only — it never writes to the vault.
struct VaultScanner {
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus", "caf", "mp4", "mov",
    ]
    private struct CachedEntry {
        var folderModified: Date
        var transcriptModified: Date?
        var entry: Entry
    }

    private var cache: [RelativePath: CachedEntry] = [:]
    private var availability = AvailabilityCache()
    private let availabilityCacheURL: URL?

    /// `availabilityCacheURL` overrides the per-vault default; tests pass a
    /// temporary location so a scan never touches Application Support.
    init(availabilityCacheURL: URL? = nil) {
        self.availabilityCacheURL = availabilityCacheURL
    }

    mutating func scan(root: URL) -> VaultSnapshot {
        availability.open(at: availabilityCacheURL ?? Self.defaultAvailabilityCacheURL(forVault: root))
        var seen = Set<RelativePath>()
        let rootNode = scanFolder(at: root, relativePath: "", name: root.lastPathComponent, seen: &seen)
        cache = cache.filter { seen.contains($0.key) }
        availability.prune(to: seen)
        availability.saveIfDirty()
        return VaultSnapshot(root: rootNode)
    }

    /// Stable per-vault location outside the vault's own files, matching what
    /// the search cache does. Nothing is ever written into an entry folder.
    static func defaultAvailabilityCacheURL(forVault vaultURL: URL) -> URL {
        let canonical = vaultURL.standardizedFileURL.path
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Transcride/Scan", directoryHint: .isDirectory)
            .appending(path: String(hash, radix: 16) + ".json")
    }

    private mutating func scanFolder(
        at url: URL, relativePath: RelativePath, name: String, seen: inout Set<RelativePath>
    ) -> FolderNode {
        var subfolders: [FolderNode] = []
        var entries: [Entry] = []

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )) ?? []

        for itemURL in contents {
            let itemName = itemURL.lastPathComponent
            if itemName.hasPrefix(".") { continue }
            let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }

            let itemRelPath = relativePath.appendingComponent(itemName)
            if let folderName = EntryFolderName(parsing: itemName) {
                seen.insert(itemRelPath)
                entries.append(loadEntry(at: itemURL, relativePath: itemRelPath, folderName: folderName))
            } else {
                subfolders.append(scanFolder(at: itemURL, relativePath: itemRelPath, name: itemName, seen: &seen))
            }
        }

        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries.sort { $0.created > $1.created }
        return FolderNode(relativePath: relativePath, name: name, subfolders: subfolders, entries: entries)
    }

    private mutating func loadEntry(
        at url: URL, relativePath: RelativePath, folderName: EntryFolderName
    ) -> Entry {
        let folderModified = modificationDate(of: url) ?? .distantPast
        // Hidden files (in-progress recordings, atomic-write temps) are invisible
        // to the library: they must not count as transcript or audio.
        let fileNames = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        let transcriptFileName = TranscriptFile.find(in: fileNames)
        let transcriptURL = transcriptFileName.map { url.appending(path: $0) }
        let transcriptModified = transcriptURL.flatMap(modificationDate)

        if let cached = cache[relativePath],
           cached.folderModified == folderModified,
           cached.transcriptModified == transcriptModified {
            return cached.entry
        }

        var title: String?
        var created = folderName.date ?? folderModified
        var duration: Double?
        var snippet = ""
        var favorite = false
        var audioDeleted = false
        var silenceDetectionMode = SilenceDetectionMode.waveform
        var hasTranscript = false

        if let transcriptURL, transcriptModified != nil,
           let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            hasTranscript = true
            let doc = FrontmatterDocument.parse(text)
            title = doc.title
            if let fmCreated = doc.created { created = fmCreated }
            duration = doc.duration
            favorite = doc.favorite
            audioDeleted = doc.audioDeleted
            silenceDetectionMode = doc.silenceDetectionMode
            snippet = Self.snippet(fromBody: doc.body)
        }

        let audioFileName = Self.audioFile(in: fileNames)
        let speechAvailability = speechAvailability(
            entryURL: url, relativePath: relativePath, duration: duration
        )
        let entry = Entry(
            relativePath: relativePath,
            folderName: folderName,
            title: title,
            created: created,
            modified: transcriptModified ?? folderModified,
            duration: duration,
            snippet: snippet,
            favorite: favorite,
            audioDeleted: audioDeleted,
            silenceDetectionMode: silenceDetectionMode,
            speechTranscriptAvailability: speechAvailability,
            audioFileName: audioFileName,
            hasTranscript: hasTranscript,
            transcriptFileName: hasTranscript ? transcriptFileName : nil
        )
        cache[relativePath] = CachedEntry(
            folderModified: folderModified,
            transcriptModified: transcriptModified,
            entry: entry
        )
        return entry
    }

    /// Speech availability is the only part of a scan that has to decode
    /// `transcript.original.json`, and that file is the largest thing in the
    /// vault — a 12-hour entry is ~15 MB of JSON. Two of the answers never
    /// depended on the words at all (stale alignment, no transcript file) and
    /// are settled from file metadata; the remaining answer is memoized across
    /// launches by the identity of the JSON that produced it, so a cold start
    /// re-decodes only what actually changed.
    private mutating func speechAvailability(
        entryURL: URL, relativePath: RelativePath, duration: Double?
    ) -> SpeechTranscriptAvailability {
        if TranscriptAlignmentState.isStale(inEntry: entryURL) { return .stale }
        let originalURL = TranscriptOriginal.url(inEntry: entryURL)
        guard let values = try? originalURL.resourceValues(
                  forKeys: [.contentModificationDateKey, .fileSizeKey]
              ),
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return .missing }

        let stamp = modified.timeIntervalSince1970
        if let cached = availability.value(
            for: relativePath, modified: stamp, size: size, duration: duration
        ) { return cached }

        let resolved = SpeechSilencePlanner.availability(
            transcript: TranscriptOriginal.load(from: originalURL),
            audioDuration: duration,
            alignmentIsStale: false
        )
        availability.store(
            resolved, for: relativePath, modified: stamp, size: size, duration: duration
        )
        return resolved
    }

    /// Cross-launch memo for the decode-derived half of
    /// `speechTranscriptAvailability`. A pure cache: the vault stays the source
    /// of truth, an unreadable or stale-keyed cache is simply ignored, and
    /// losing the file costs one slow launch and nothing else. Keys are
    /// (modification date, byte size, the duration the answer was computed
    /// against), so an entry edited outside the app re-decodes.
    private struct AvailabilityCache {
        private struct Record: Codable {
            var modified: Double
            var size: Int
            var duration: Double?
            var availability: String
        }

        private struct Payload: Codable {
            var version: Int
            var records: [RelativePath: Record]
        }

        private static let version = 1

        private var url: URL?
        private var records: [RelativePath: Record] = [:]
        private var dirty = false

        /// Reads the cache the first time a given vault is scanned. Later
        /// scans of the same vault reuse what is already in memory.
        mutating func open(at url: URL) {
            guard self.url != url else { return }
            self.url = url
            records = [:]
            dirty = false
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.version == Self.version else { return }
            records = payload.records
        }

        func value(
            for relativePath: RelativePath, modified: Double, size: Int, duration: Double?
        ) -> SpeechTranscriptAvailability? {
            guard let record = records[relativePath],
                  record.modified == modified,
                  record.size == size,
                  record.duration == duration else { return nil }
            return Self.availability(named: record.availability)
        }

        mutating func store(
            _ availability: SpeechTranscriptAvailability,
            for relativePath: RelativePath, modified: Double, size: Int, duration: Double?
        ) {
            guard let name = Self.name(of: availability) else { return }
            records[relativePath] = Record(
                modified: modified, size: size, duration: duration, availability: name
            )
            dirty = true
        }

        mutating func prune(to seen: Set<RelativePath>) {
            let kept = records.filter { seen.contains($0.key) }
            guard kept.count != records.count else { return }
            records = kept
            dirty = true
        }

        mutating func saveIfDirty() {
            guard dirty, let url else { return }
            dirty = false
            guard !records.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard let data = try? JSONEncoder().encode(
                Payload(version: Self.version, records: records)
            ) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? AtomicFile.write(data, to: url)
        }

        /// Only the answers that cost a decode are worth persisting; `.stale`
        /// and `.regenerating` are decided elsewhere and never stored.
        private static func name(of value: SpeechTranscriptAvailability) -> String? {
            switch value {
            case .available: "available"
            case .malformed: "malformed"
            case .missing: "missing"
            case .stale, .regenerating: nil
            }
        }

        private static func availability(named name: String) -> SpeechTranscriptAvailability? {
            switch name {
            case "available": .available
            case "malformed": .malformed
            case "missing": .missing
            default: nil
            }
        }
    }

    /// Picks the entry's audio file: prefers the canonical `audio.*`, else the
    /// first audio-extension file by name.
    static func audioFile(in fileNames: [String]) -> String? {
        let audio = fileNames.filter {
            audioExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        if let canonical = audio.first(where: {
            ($0 as NSString).deletingPathExtension.lowercased() == "audio"
        }) {
            return canonical
        }
        return audio.min { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// First ~160 characters of meaningful body text, markdown markers stripped.
    static func snippet(fromBody body: String, limit: Int = 160) -> String {
        var out = ""
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "---" { continue }
            while let first = text.first, "#>-*".contains(first) {
                text.removeFirst()
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += text
            if out.count >= limit { break }
        }
        return String(out.prefix(limit))
    }
}
