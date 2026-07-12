import AVFoundation
import Foundation

enum AudioReplacementError: LocalizedError {
    case missingAudioTrack(String)
    case invalidRecipe
    case missingSource(String)
    case exporterUnavailable
    case sourceChanged
    case durationMismatch(expected: Double, actual: Double)
    case diskSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack(let name): return "\(name) does not contain readable audio."
        case .invalidRecipe: return "The replacement edit history is invalid."
        case .missingSource(let name): return "The retained replacement source \(name) is missing."
        case .exporterUnavailable: return "The replacement audio could not be rendered on this system."
        case .sourceChanged: return "The entry audio changed before the replacement could be installed."
        case .durationMismatch(let expected, let actual):
            return "The rendered audio duration was \(actual) seconds; expected \(expected) seconds."
        case .diskSpace(let required, let available):
            return "Replacing this region needs about \(required) bytes, but only \(available) bytes are available."
        }
    }
}

struct PreparedReplacementEdit: Sendable {
    var directoryURL: URL
    var recipe: ReplacementRecipe
    var takeSource: ReplacementSource
}

enum AudioReplacementStore {
    static func loadRecipe(in entryURL: URL) -> ReplacementRecipe? {
        let url = entryURL
            .appending(path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory)
            .appending(path: AudioReplacementArtifacts.recipeFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReplacementRecipe.self, from: data)
    }

    /// Builds a complete next-generation history directory. Existing retained
    /// sources are copied; if history was removed externally, the current
    /// canonical file becomes a new stable master.
    static func prepare(
        entryURL: URL,
        canonicalAudioURL: URL,
        canonicalDuration: Double,
        takeURL: URL,
        take: ReplacementTake,
        region: ReplacementRegion
    ) throws -> PreparedReplacementEdit {
        let fm = FileManager.default
        let currentDirectory = entryURL.appending(
            path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory
        )
        let nextDirectory = entryURL.appending(
            path: AudioReplacementArtifacts.nextDirectoryName, directoryHint: .isDirectory
        )
        try? fm.removeItem(at: nextDirectory)
        if fm.fileExists(atPath: currentDirectory.path),
           let recipe = loadRecipe(in: entryURL), recipe.isDurationPreserving,
           ReplacementRenderPlan.make(recipe: recipe) != nil,
           recipe.sources.allSatisfy({
               fm.fileExists(atPath: currentDirectory.appending(path: $0.fileName).path)
           }) {
            try fm.copyItem(at: currentDirectory, to: nextDirectory)
        } else {
            try fm.createDirectory(at: nextDirectory, withIntermediateDirectories: true)
            let ext = canonicalAudioURL.pathExtension.isEmpty ? "m4a" : canonicalAudioURL.pathExtension
            let masterName = "master-\(UUID().uuidString.lowercased()).\(ext)"
            try fm.copyItem(at: canonicalAudioURL, to: nextDirectory.appending(path: masterName))
            let recipe = ReplacementRecipe.master(
                fileName: masterName,
                duration: canonicalDuration,
                sampleRate: region.sampleRate
            )
            try write(recipe, to: nextDirectory)
        }

        guard let baseData = try? Data(contentsOf: nextDirectory.appending(
            path: AudioReplacementArtifacts.recipeFileName
        )), let base = try? JSONDecoder().decode(ReplacementRecipe.self, from: baseData) else {
            throw AudioReplacementError.invalidRecipe
        }
        let takeName = AudioReplacementArtifacts.takeFileName(
            id: take.id,
            fileExtension: takeURL.pathExtension.isEmpty ? "m4a" : takeURL.pathExtension
        )
        let retainedTakeURL = nextDirectory.appending(path: takeName)
        try? fm.removeItem(at: retainedTakeURL)
        try fm.copyItem(at: takeURL, to: retainedTakeURL)
        let source = ReplacementSource(
            id: take.id, kind: .take, fileName: takeName, frameCount: region.frameCount
        )
        let recipe = base.replacing(region: region, with: source)
        guard recipe.isDurationPreserving else { throw AudioReplacementError.invalidRecipe }
        try write(recipe, to: nextDirectory)
        return PreparedReplacementEdit(
            directoryURL: nextDirectory, recipe: recipe, takeSource: source
        )
    }

    static func write(_ recipe: ReplacementRecipe, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            encoder.encode(recipe),
            to: directory.appending(path: AudioReplacementArtifacts.recipeFileName)
        )
    }

    static func ensureDiskSpace(at entryURL: URL, estimatedBytes: Int64) throws {
        let values = try entryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= estimatedBytes else {
            throw AudioReplacementError.diskSpace(required: estimatedBytes, available: available)
        }
    }
}

enum AudioReplacementRenderer {
    struct Output: Sendable {
        var url: URL
        var duration: Double
    }

    static func render(
        recipe: ReplacementRecipe,
        sourcesDirectory: URL,
        outputURL: URL
    ) async throws -> Output {
        guard let plan = ReplacementRenderPlan.make(recipe: recipe) else {
            throw AudioReplacementError.invalidRecipe
        }
        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioReplacementError.exporterUnavailable }

        var cursor = CMTime.zero
        for segment in plan {
            let url = sourcesDirectory.appending(path: segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AudioReplacementError.missingSource(segment.fileName)
            }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioReplacementError.missingAudioTrack(segment.fileName)
            }
            let start = CMTime(value: segment.sourceStartFrame, timescale: CMTimeScale(recipe.sampleRate))
            let duration = CMTime(value: segment.frameCount, timescale: CMTimeScale(recipe.sampleRate))
            try outputTrack.insertTimeRange(
                CMTimeRange(start: start, duration: duration), of: track, at: cursor
            )
            cursor = cursor + duration
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else { throw AudioReplacementError.exporterUnavailable }
        // A one-millisecond dip on either side suppresses discontinuity clicks
        // without overlapping sources, changing timing, or becoming an
        // audible crossfade.
        if recipe.slices.count > 1 {
            let parameters = AVMutableAudioMixInputParameters(track: outputTrack)
            let rampFrames = max(1, Int64((recipe.sampleRate * 0.001).rounded()))
            let scale = CMTimeScale(recipe.sampleRate)
            for slice in recipe.slices.dropFirst() {
                let boundary = CMTime(value: slice.timelineStartFrame, timescale: scale)
                let ramp = CMTime(value: rampFrames, timescale: scale)
                parameters.setVolumeRamp(
                    fromStartVolume: 1, toEndVolume: 0,
                    timeRange: CMTimeRange(start: boundary - ramp, duration: ramp)
                )
                parameters.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: 1,
                    timeRange: CMTimeRange(start: boundary, duration: ramp)
                )
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            exporter.audioMix = mix
        }
        try await exporter.export(to: outputURL, as: .m4a)
        let actual = try await AudioImportFormat.probeDuration(of: outputURL)
        let durationPlan = ReplacementRenderDurationPlan(
            expectedFrames: recipe.totalFrames, sampleRate: recipe.sampleRate
        )
        guard durationPlan.accepts(actualDuration: actual) else {
            throw AudioReplacementError.durationMismatch(
                expected: durationPlan.expectedDuration, actual: actual
            )
        }
        return Output(url: outputURL, duration: actual)
    }
}

enum AudioReplacementPreviewRenderer {
    static func render(
        canonicalURL: URL,
        takeURL: URL,
        region: ReplacementRegion
    ) async throws -> URL {
        let source = AVURLAsset(url: canonicalURL)
        let take = AVURLAsset(url: takeURL)
        guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first else {
            throw AudioReplacementError.missingAudioTrack(canonicalURL.lastPathComponent)
        }
        guard let takeTrack = try await take.loadTracks(withMediaType: .audio).first else {
            throw AudioReplacementError.missingAudioTrack(takeURL.lastPathComponent)
        }
        let sourceDuration = try await source.load(.duration)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioReplacementError.exporterUnavailable }
        let scale = CMTimeScale(region.sampleRate)
        let start = CMTime(value: region.startFrame, timescale: scale)
        let replacementDuration = CMTime(value: region.frameCount, timescale: scale)
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: start), of: sourceTrack, at: .zero
        )
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: replacementDuration), of: takeTrack, at: start
        )
        let suffixStart = start + replacementDuration
        if sourceDuration > suffixStart {
            try track.insertTimeRange(
                CMTimeRange(start: suffixStart, duration: sourceDuration - suffixStart),
                of: sourceTrack,
                at: suffixStart
            )
        }
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "transcride-replacement-preview-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "preview.m4a")
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else { throw AudioReplacementError.exporterUnavailable }
        try await exporter.export(to: output, as: .m4a)
        return output
    }
}

/// Installs a rendered replacement and its matching recipe as one recoverable
/// version. The visible canonical file is never mutated in place.
struct AudioReplacementApplier: Sendable {
    let vaultRoot: URL

    struct Outcome: Sendable {
        var trashedName: String
        var audioFileName: String
        var duration: Double
    }

    func apply(
        renderedFileAt renderedURL: URL,
        nextHistoryDirectory: URL,
        expectedSourceFileName: String,
        duration: Double,
        toEntryAt relPath: RelativePath,
        date: Date = Date()
    ) throws -> Outcome {
        let fm = FileManager.default
        let entryURL = vaultRoot.appendingRelativePath(relPath)
        let names = ((try? fm.contentsOfDirectory(atPath: entryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard VaultScanner.audioFile(in: names) == expectedSourceFileName else {
            throw AudioReplacementError.sourceChanged
        }
        let trash = TrashStore(vaultRoot: vaultRoot)
        let trashedName = try trash.trashPreReplacementAudio(
            atEntryPath: relPath, deletedAt: date
        )
        let destinationName = (expectedSourceFileName as NSString).deletingPathExtension + ".m4a"
        do {
            try fm.moveItem(at: renderedURL, to: entryURL.appending(path: destinationName))
            let historyDestination = entryURL.appending(
                path: AudioReplacementArtifacts.directoryName, directoryHint: .isDirectory
            )
            try? fm.removeItem(at: historyDestination)
            try fm.moveItem(at: nextHistoryDirectory, to: historyDestination)
        } catch {
            if let item = try? trash.items().first(where: { $0.trashedName == trashedName }) {
                _ = try? trash.restore(item)
            }
            throw error
        }
        try? EntryMetadata.setDuration(duration, inEntry: entryURL)
        try? TranscriptAlignmentState.markStale(inEntry: entryURL)
        return Outcome(
            trashedName: trashedName, audioFileName: destinationName, duration: duration
        )
    }
}
