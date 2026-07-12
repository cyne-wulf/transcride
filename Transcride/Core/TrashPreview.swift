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
        do {
            return (try await WaveformGenerator.generate(fromAudioAt: audioURL), nil)
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
