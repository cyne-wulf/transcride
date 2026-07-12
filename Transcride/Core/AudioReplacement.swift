import Foundation

enum AudioReplacementArtifacts {
    static let directoryName = ".transcride-replacements"
    static let nextDirectoryName = ".transcride-replacements-next"
    static let sessionDirectoryName = ".transcride-replacement-session"
    static let recipeFileName = "recipe-v1.json"
    static let sessionFileName = "session-v1.json"
    static let partialFileName = ".replacement-recording.caf"
    /// Durable intent written before discarded take artifacts are removed.
    /// If cleanup is interrupted, relaunch finishes the discard instead of
    /// offering a session the user already cancelled as recoverable work.
    static let cancellationMarkerFileName = ".replacement-session-cancelled"
    static let previewFileName = ".replacement-preview.m4a"
    static let candidateFileName = ".replacement-candidate.m4a"

    static func takeFileName(id: UUID, fileExtension: String = "m4a") -> String {
        "take-\(id.uuidString.lowercased()).\(fileExtension)"
    }
}

/// A replacement range is locked before capture begins. Frame coordinates are
/// authoritative; seconds exist only for display and player seeking.
struct ReplacementRegion: Codable, Equatable, Sendable {
    var startFrame: Int64
    var frameCount: Int64
    var sampleRate: Double

    init(selection: AudioRangeSelection, timelineDuration: Double, sampleRate: Double) {
        let clamped = selection.clamped(toDuration: timelineDuration)
        let totalFrames = Int64((timelineDuration * sampleRate).rounded())
        let start = min(totalFrames, max(0, Int64((clamped.start * sampleRate).rounded())))
        let end = min(totalFrames, max(start, Int64((clamped.end * sampleRate).rounded())))
        startFrame = start
        frameCount = end - start
        self.sampleRate = sampleRate
    }

    var endFrame: Int64 { startFrame + frameCount }
    var start: Double { Double(startFrame) / sampleRate }
    var duration: Double { Double(frameCount) / sampleRate }
    var end: Double { Double(endFrame) / sampleRate }
}

/// The replacement timeline is derived from the playable asset, not the
/// two-decimal duration stored in Markdown frontmatter. Keeping an integer
/// frame count here prevents range locking and later render validation from
/// disagreeing about the same file by a few milliseconds.
struct ReplacementTimeline: Equatable, Sendable {
    /// Frontmatter writes two fractional digits, so a legacy replacement
    /// session may differ from its asset by at most half of one centisecond.
    static func roundedMetadataToleranceFrames(sampleRate: Double) -> Int64 {
        Int64((sampleRate * 0.005).rounded(.up)) + 1
    }

    var sampleRate: Double
    var totalFrames: Int64

    init(duration: Double, sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        totalFrames = max(0, Int64((duration * sampleRate).rounded()))
    }

    var duration: Double { Double(totalFrames) / sampleRate }

    func matches(duration candidate: Double, toleranceFrames: Int64 = 1) -> Bool {
        guard candidate.isFinite, candidate > 0 else { return false }
        let candidateFrames = Int64((candidate * sampleRate).rounded())
        return abs(candidateFrames - totalFrames) <= toleranceFrames
    }
}

/// Export validation is also frame based. Comparing raw floating-point seconds
/// can reject the exact same duration after a CMTime/Double round trip.
struct ReplacementRenderDurationPlan: Equatable, Sendable {
    var expectedFrames: Int64
    var sampleRate: Double

    var expectedDuration: Double { Double(expectedFrames) / sampleRate }

    func accepts(actualDuration: Double, toleranceFrames: Int64 = 1) -> Bool {
        guard actualDuration.isFinite, actualDuration > 0 else { return false }
        let actualFrames = Int64((actualDuration * sampleRate).rounded())
        return abs(actualFrames - expectedFrames) <= toleranceFrames
    }
}

enum ReplacementTakeStatus: String, Codable, Sendable {
    case complete
    case incomplete
}

struct ReplacementTake: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var number: Int
    var fileName: String
    var capturedFrames: Int64
    var sampleRate: Double
    var createdAt: Date
    var status: ReplacementTakeStatus

    var duration: Double { Double(capturedFrames) / sampleRate }
}

enum ReplacementTakeEligibility: Equatable, Sendable {
    case eligible
    case incomplete(missingFrames: Int64)
    case tooLong(extraFrames: Int64)
    case wrongSampleRate

    static func classify(
        capturedFrames: Int64,
        capturedSampleRate: Double,
        for region: ReplacementRegion
    ) -> Self {
        guard abs(capturedSampleRate - region.sampleRate) < 0.001 else {
            return .wrongSampleRate
        }
        let delta = capturedFrames - region.frameCount
        if abs(delta) <= 1 { return .eligible }
        return delta < 0 ? .incomplete(missingFrames: -delta) : .tooLong(extraFrames: delta)
    }
}

enum ReplacementSessionPhase: String, Codable, Sendable {
    case selecting
    case ready
    case capturing
    case finalizingTake
    case auditioning
    case rendering
    case swapping
    case retranscribing
    case completed
    case failed
}

struct ReplacementTakeSession: Codable, Equatable, Sendable {
    var id: UUID
    var entryRelativePath: RelativePath
    var sourceAudioFileName: String
    var timelineDuration: Double
    var region: ReplacementRegion
    var phase: ReplacementSessionPhase
    var takes: [ReplacementTake]
    var selectedTakeID: UUID?
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        entryRelativePath: RelativePath,
        sourceAudioFileName: String,
        timelineDuration: Double,
        region: ReplacementRegion
    ) {
        self.id = id
        self.entryRelativePath = entryRelativePath
        self.sourceAudioFileName = sourceAudioFileName
        self.timelineDuration = timelineDuration
        self.region = region
        phase = .ready
        takes = []
    }

    var selectedTake: ReplacementTake? {
        takes.first { $0.id == selectedTakeID }
    }

    var selectedTakeCanBake: Bool {
        guard let take = selectedTake, take.status == .complete else { return false }
        return ReplacementTakeEligibility.classify(
            capturedFrames: take.capturedFrames,
            capturedSampleRate: take.sampleRate,
            for: region
        ) == .eligible
    }

    mutating func appendTake(_ take: ReplacementTake) {
        takes.append(take)
        if take.status == .complete { selectedTakeID = take.id }
        phase = .ready
    }
}

struct ReplacementRecordingTarget: Codable, Equatable, Sendable {
    var entryRelativePath: RelativePath
    var sessionID: UUID
    var region: ReplacementRegion
    var takeNumber: Int
}

enum ReplacementSourceKind: String, Codable, Sendable {
    case master
    case take
}

struct ReplacementSource: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: ReplacementSourceKind
    var fileName: String
    var frameCount: Int64
}

/// A slice uses stable source-frame coordinates and fixed timeline length.
/// Replacements split existing slices but never shift a later slice.
struct ReplacementTimelineSlice: Codable, Equatable, Sendable {
    var sourceID: UUID
    var sourceStartFrame: Int64
    var timelineStartFrame: Int64
    var frameCount: Int64

    var timelineEndFrame: Int64 { timelineStartFrame + frameCount }
}

struct ReplacementRecipe: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var sampleRate: Double
    var totalFrames: Int64
    var sources: [ReplacementSource]
    var slices: [ReplacementTimelineSlice]

    static func master(fileName: String, duration: Double, sampleRate: Double = 44_100) -> Self {
        let frames = Int64((duration * sampleRate).rounded())
        let source = ReplacementSource(
            id: UUID(), kind: .master, fileName: fileName, frameCount: frames
        )
        return Self(
            version: currentVersion,
            sampleRate: sampleRate,
            totalFrames: frames,
            sources: [source],
            slices: [ReplacementTimelineSlice(
                sourceID: source.id,
                sourceStartFrame: 0,
                timelineStartFrame: 0,
                frameCount: frames
            )]
        )
    }

    func replacing(region: ReplacementRegion, with source: ReplacementSource) -> Self {
        precondition(abs(region.sampleRate - sampleRate) < 0.001)
        let start = min(totalFrames, max(0, region.startFrame))
        let end = min(totalFrames, max(start, region.endFrame))
        var result: [ReplacementTimelineSlice] = []

        for slice in slices.sorted(by: { $0.timelineStartFrame < $1.timelineStartFrame }) {
            if slice.timelineEndFrame <= start || slice.timelineStartFrame >= end {
                result.append(slice)
                continue
            }
            if slice.timelineStartFrame < start {
                result.append(ReplacementTimelineSlice(
                    sourceID: slice.sourceID,
                    sourceStartFrame: slice.sourceStartFrame,
                    timelineStartFrame: slice.timelineStartFrame,
                    frameCount: start - slice.timelineStartFrame
                ))
            }
            if slice.timelineEndFrame > end {
                let removedFromSlice = end - slice.timelineStartFrame
                result.append(ReplacementTimelineSlice(
                    sourceID: slice.sourceID,
                    sourceStartFrame: slice.sourceStartFrame + removedFromSlice,
                    timelineStartFrame: end,
                    frameCount: slice.timelineEndFrame - end
                ))
            }
        }

        if end > start {
            result.append(ReplacementTimelineSlice(
                sourceID: source.id,
                sourceStartFrame: 0,
                timelineStartFrame: start,
                frameCount: end - start
            ))
        }
        result.sort { $0.timelineStartFrame < $1.timelineStartFrame }

        var updatedSources = sources.filter { existing in
            result.contains { $0.sourceID == existing.id }
        }
        updatedSources.append(source)
        return Self(
            version: version,
            sampleRate: sampleRate,
            totalFrames: totalFrames,
            sources: updatedSources,
            slices: result
        )
    }

    var isDurationPreserving: Bool {
        guard slices.first?.timelineStartFrame == 0,
              slices.last?.timelineEndFrame == totalFrames else { return false }
        return zip(slices, slices.dropFirst()).allSatisfy {
            $0.timelineEndFrame == $1.timelineStartFrame
        }
    }
}

struct ReplacementRenderSegment: Equatable, Sendable {
    var fileName: String
    var sourceStartFrame: Int64
    var frameCount: Int64
}

enum ReplacementRenderPlan {
    static func make(recipe: ReplacementRecipe) -> [ReplacementRenderSegment]? {
        guard recipe.version == ReplacementRecipe.currentVersion,
              recipe.isDurationPreserving else { return nil }
        let sourceNames = Dictionary(uniqueKeysWithValues: recipe.sources.map { ($0.id, $0.fileName) })
        return recipe.slices.compactMap { slice in
            guard let fileName = sourceNames[slice.sourceID] else { return nil }
            return ReplacementRenderSegment(
                fileName: fileName,
                sourceStartFrame: slice.sourceStartFrame,
                frameCount: slice.frameCount
            )
        }
    }
}

enum ReplacementRecoveryClassification: Equatable, Sendable {
    case none
    case partialTake
    case takesReady
    case candidateAwaitingSwap
    case swapNeedsCleanup
    case abandonedMetadata

    static func classify(
        hasSession: Bool,
        hasPartial: Bool,
        completeTakeCount: Int,
        hasCandidate: Bool,
        canonicalMatchesCandidate: Bool
    ) -> Self {
        if canonicalMatchesCandidate { return .swapNeedsCleanup }
        if hasCandidate { return .candidateAwaitingSwap }
        if hasPartial { return .partialTake }
        if completeTakeCount > 0 { return .takesReady }
        if hasSession { return .abandonedMetadata }
        return .none
    }
}

struct ReplacementSessionDiscovery: Sendable {
    var recoverable: [ReplacementTakeSession]
    var committedEntryPaths: [RelativePath]
}

enum ReplacementSessionDisposition: Equatable, Sendable {
    case recover
    case discard

    static func classify(hasCancellationMarker: Bool) -> Self {
        hasCancellationMarker ? .discard : .recover
    }
}
