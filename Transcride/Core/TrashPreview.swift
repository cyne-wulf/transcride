import Foundation

enum TrashPreviewKind: Equatable, Sendable {
    case entry
    case audio
    case folder
    case file
    case unavailable
}

/// Read-only projection of one Recently Deleted payload. URLs always point
/// inside `.trash`; callers must never route them through live-entry mutation
/// APIs.
struct TrashPreview: Equatable, Sendable {
    var item: TrashItem
    var kind: TrashPreviewKind
    var title: String
    var created: Date?
    var duration: Double?
    var document: FrontmatterDocument?
    var original: TranscriptOriginal?
    var audioURL: URL?
    var waveform: WaveformData?
    var summary: String?
    var transcriptUnavailableReason: String?
    var audioUnavailableReason: String?
}

/// Resolves trash contents without writing caches or otherwise modifying the
/// deleted payload. Missing waveforms are generated in memory only.
struct TrashPreviewResolver: Sendable {
    let vaultRoot: URL
    /// Deleted payloads carry no `waveform.json` of their own unless one was
    /// trashed with them, so without this every re-selection re-decoded the
    /// whole audio file. Process-lifetime and self-invalidating; the resolver
    /// still never writes into `.trash`.
    let waveformCache: TrashWaveformCache

    init(vaultRoot: URL, waveformCache: TrashWaveformCache = .shared) {
        self.vaultRoot = vaultRoot
        self.waveformCache = waveformCache
    }

    private var trashDirectory: URL {
        vaultRoot.appending(path: TrashStore.directoryName, directoryHint: .isDirectory)
    }

    func resolve(_ item: TrashItem) async -> TrashPreview {
        let payloadURL = trashDirectory.appending(path: item.trashedName)
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            return basePreview(
                item: item,
                kind: .unavailable,
                summary: "This deleted item is no longer available on disk."
            )
        }

        if item.kind.isAudio {
            return await audioPreview(item: item, payloadURL: payloadURL)
        }
        if item.isEntry {
            return await entryPreview(item: item, entryURL: payloadURL)
        }

        let isDirectory = (try? payloadURL.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true
        if isDirectory {
            let count = descendantCount(in: payloadURL)
            let noun = count == 1 ? "item" : "items"
            return basePreview(
                item: item,
                kind: .folder,
                summary: count == 0
                    ? "This deleted folder is empty."
                    : "This deleted folder contains \(count) \(noun)."
            )
        }
        return basePreview(
            item: item,
            kind: .file,
            summary: "This deleted file does not have an in-app preview."
        )
    }

    private func entryPreview(item: TrashItem, entryURL: URL) async -> TrashPreview {
        let names = visibleNames(in: entryURL)
        let transcriptName = TranscriptFile.find(in: names)
        let transcriptURL = transcriptName.map { entryURL.appending(path: $0) }
        let document: FrontmatterDocument? = transcriptURL.flatMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return FrontmatterDocument.parse(text)
        }
        let original = TranscriptOriginal.load(from: TranscriptOriginal.url(inEntry: entryURL))
        let audioURL = VaultScanner.audioFile(in: names).map { entryURL.appending(path: $0) }
        let waveformResult = await waveform(for: audioURL, in: entryURL)
        let folderName = EntryFolderName(parsing: item.originalPath.lastComponent)
            ?? EntryFolderName(parsing: item.trashedName)
        let title: String
        if let documentTitle = document?.title, !documentTitle.isEmpty {
            title = documentTitle
        } else if let slug = folderName?.slug {
            title = displayTitle(fromSlug: slug)
        } else {
            title = item.displayName
        }

        return TrashPreview(
            item: item,
            kind: .entry,
            title: title,
            created: document?.created ?? folderName?.date,
            duration: waveformResult.waveform?.duration ?? document?.duration,
            document: document,
            original: original,
            audioURL: audioURL,
            waveform: waveformResult.waveform,
            summary: nil,
            transcriptUnavailableReason: transcriptName == nil
                ? "This deleted entry does not contain a transcript."
                : (document == nil && original == nil
                    ? "The deleted transcript could not be read." : nil),
            audioUnavailableReason: audioURL == nil
                ? "This deleted entry does not contain audio."
                : waveformResult.error
        )
    }

    private func audioPreview(item: TrashItem, payloadURL: URL) async -> TrashPreview {
        let names = visibleNames(in: payloadURL)
        let audioURL = VaultScanner.audioFile(in: names).map { payloadURL.appending(path: $0) }
        let waveformResult = await waveform(for: audioURL, in: payloadURL)
        return TrashPreview(
            item: item,
            kind: .audio,
            title: item.displayName,
            created: nil,
            duration: waveformResult.waveform?.duration,
            document: nil,
            original: nil,
            audioURL: audioURL,
            waveform: waveformResult.waveform,
            summary: "This deleted audio version does not include a transcript.",
            transcriptUnavailableReason: nil,
            audioUnavailableReason: audioURL == nil
                ? "The deleted audio file is missing."
                : waveformResult.error
        )
    }

    private func basePreview(
        item: TrashItem, kind: TrashPreviewKind, summary: String
    ) -> TrashPreview {
        TrashPreview(
            item: item,
            kind: kind,
            title: item.displayName,
            created: nil,
            duration: nil,
            document: nil,
            original: nil,
            audioURL: nil,
            waveform: nil,
            summary: summary,
            transcriptUnavailableReason: nil,
            audioUnavailableReason: nil
        )
    }

    private func waveform(
        for audioURL: URL?, in containerURL: URL
    ) async -> (waveform: WaveformData?, error: String?) {
        guard let audioURL else { return (nil, nil) }
        if let cached = WaveformData.load(from: WaveformData.url(inEntry: containerURL)) {
            return (cached, nil)
        }
        let key = TrashWaveformCache.Key(audioAt: audioURL)
        if let key, let memoized = await waveformCache.value(for: key) {
            return (memoized, nil)
        }
        do {
            let generated = try await WaveformGenerator.generate(fromAudioAt: audioURL)
            if let key { await waveformCache.store(generated, for: key) }
            return (generated, nil)
        } catch is CancellationError {
            return (nil, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func visibleNames(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    private func descendantCount(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case _ as URL in enumerator { count += 1 }
        return count
    }

    private func displayTitle(fromSlug slug: String) -> String {
        slug.split(separator: "-").joined(separator: " ").capitalized
    }
}

/// In-memory LRU of waveforms generated for deleted payloads, which cannot be
/// cached on disk (nothing may be written inside `.trash`).
///
/// The key is derived from the audio file's identity *and* its size and
/// modification date, never from `trashedName` alone: `TrashStore` reuses a
/// trashed name once its previous holder is restored or emptied, so a
/// name-only key could serve one deleted recording's peaks for another's
/// audio. Content-derived keys make the cache self-invalidating — an emptied
/// or restored item's entry is simply never read again and ages out.
actor TrashWaveformCache {
    static let shared = TrashWaveformCache()

    struct Key: Hashable, Sendable {
        var path: String
        var size: Int64
        var modified: TimeInterval

        init(path: String, size: Int64, modified: TimeInterval) {
            self.path = path
            self.size = size
            self.modified = modified
        }

        /// Nil when the file cannot be stat'd, in which case the caller
        /// generates without caching rather than risking a stale hit.
        init?(audioAt url: URL) {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            self.init(
                path: url.standardizedFileURL.path,
                size: Int64(size),
                modified: modified.timeIntervalSinceReferenceDate
            )
        }
    }

    /// A `WaveformData` costs ~12 bytes per peak (the peaks plus the display
    /// cache's prefix sums), i.e. ~240 bytes per second of audio at the
    /// standard 20 peaks/s. The budget caps the cache near 24 MB / ~28 hours
    /// of audio; the entry count keeps a handful of ordinary previews warm.
    private let maxEntries: Int
    private let maxPeaks: Int
    private var entries: [Key: WaveformData] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var totalPeaks = 0

    init(maxEntries: Int = 6, maxPeaks: Int = 2_000_000) {
        self.maxEntries = max(1, maxEntries)
        self.maxPeaks = max(1, maxPeaks)
    }

    var count: Int { entries.count }

    func value(for key: Key) -> WaveformData? {
        guard let waveform = entries[key] else { return nil }
        touch(key)
        return waveform
    }

    func store(_ waveform: WaveformData, for key: Key) {
        if let existing = entries[key] {
            totalPeaks -= existing.peaks.count
        }
        entries[key] = waveform
        totalPeaks += waveform.peaks.count
        touch(key)
        // The most recent entry is always retained, even if it alone exceeds
        // the budget: re-selecting one very long recording must stay fast.
        while order.count > 1, entries.count > maxEntries || totalPeaks > maxPeaks {
            evictLeastRecentlyUsed()
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalPeaks = 0
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictLeastRecentlyUsed() {
        guard !order.isEmpty else { return }
        let key = order.removeFirst()
        if let removed = entries.removeValue(forKey: key) {
            totalPeaks -= removed.peaks.count
        }
    }
}
