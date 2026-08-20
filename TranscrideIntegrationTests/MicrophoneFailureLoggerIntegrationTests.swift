import AVFoundation
import Foundation
import Testing
@testable import Transcride

@Suite("Durable microphone failure logging", .serialized)
struct MicrophoneFailureLoggerIntegrationTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_786_579_200.125)
    private let fixedVersion = MicrophoneFailureLogVersion(
        appVersion: "9.8.7-test",
        appBuild: "654"
    )

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "transcride-mic-failure-log-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(
        sessionID: UUID = UUID(),
        kind: MicrophoneFailureEvent.Kind = .noAudioAfterStart,
        reason: MicrophoneFailureEvent.Reason = .noBuffers
    ) -> MicrophoneFailureEvent {
        MicrophoneFailureEvent(
            sessionID: sessionID,
            kind: kind,
            target: .newEntry,
            stage: .firstBuffer,
            reason: reason,
            preferredRoute: .selectedDevice(uid: "test-device-uid"),
            resolvedDeviceFormat: .init(
                deviceID: 42,
                sampleRate: 48_000,
                channelCount: 2,
                sampleFormat: .float32,
                isInterleaved: false
            ),
            engineState: .init(phase: .running, isRunning: true, tapInstalled: true),
            frames: 0,
            elapsedSeconds: 2.5,
            error: .init(domain: "test.audio", code: -50),
            attemptNumber: 2,
            requestedDeviceID: 41,
            baselineDeviceFormat: .init(
                deviceID: 41,
                sampleRate: 48_000,
                channelCount: 1
            ),
            currentDeviceFormat: .init(
                deviceID: 42,
                sampleRate: 16_000,
                channelCount: 1
            ),
            firstBufferFormat: .init(
                deviceID: 41,
                sampleRate: 48_000,
                channelCount: 1,
                sampleFormat: .float32,
                isInterleaved: false
            ),
            firstBufferLatencySeconds: 0.125
        )
    }

    private func records(at url: URL) throws -> [MicrophoneFailureLogRecord] {
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        return try lines.map { try JSONDecoder().decode(MicrophoneFailureLogRecord.self, from: $0) }
    }

    private func writeSilentJournal(frames: AVAudioFrameCount, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: CrashTolerantAudioJournal.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        defer { file.close() }
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames
        ))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(frames))
        }
        try file.write(from: buffer)
    }

    @Test func newLoggerInstancesAppendWithoutTruncatingPriorFailures() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "microphone-failures.jsonl")
        let firstSession = UUID()
        let secondSession = UUID()

        let first = MicrophoneFailureLogger(
            url: url,
            clock: { fixedDate },
            version: fixedVersion
        )
        #expect(first.log(event(sessionID: firstSession)))

        // A new instance models an app relaunch/update. It must append to the
        // same durable history rather than treating a successful start as a
        // reason to clear it.
        let relaunched = MicrophoneFailureLogger(
            url: url,
            clock: { fixedDate.addingTimeInterval(10) },
            version: .init(appVersion: "9.8.8-test", appBuild: "655")
        )
        #expect(relaunched.log(event(
            sessionID: secondSession,
            kind: .perfectlySilentClip,
            reason: .perfectlySilent
        )))

        let written = try records(at: url)
        #expect(written.count == 2)
        #expect(written.map(\.sessionID) == [firstSession, secondSession])
        #expect(written[0].appVersion == "9.8.7-test")
        #expect(written[1].appVersion == "9.8.8-test")
        #expect(written[0].timestamp != written[1].timestamp)
        #expect(written[0].event == .noAudioAfterStart)
        #expect(written[1].event == .perfectlySilentClip)
        #expect(written[1].reason == .perfectlySilent)
        #expect(written[0].preferredRoute.mode == .selectedDevice)
        #expect(written[0].preferredRoute.uidFingerprint?.count == 24)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .contains("test-device-uid"))
    }

    @Test func concurrentCallsProduceUniqueParseableCompleteLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "microphone-failures.jsonl")
        let logger = MicrophoneFailureLogger(
            url: url,
            clock: { fixedDate },
            version: fixedVersion
        )
        let sessions = (0..<128).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
            _ = logger.log(event(sessionID: sessions[index]))
        }

        let written = try records(at: url)
        #expect(written.count == sessions.count)
        #expect(Set(written.map(\.eventID)).count == sessions.count)
        #expect(Set(written.map(\.sessionID)) == Set(sessions))
        #expect(written.allSatisfy { $0.schemaVersion == 2 })
        #expect(written.allSatisfy { $0.appBuild == "654" })
        #expect(written.allSatisfy { $0.attemptNumber == 2 })
        #expect(written.allSatisfy { $0.requestedDeviceID == 41 })
        #expect(written.allSatisfy { $0.baselineDeviceFormat?.deviceID == 41 })
        #expect(written.allSatisfy { $0.currentDeviceFormat?.deviceID == 42 })
        #expect(written.allSatisfy { $0.firstBufferLatencySeconds == 0.125 })
    }

    @Test func schemaVersionOneRecordDecodesWithoutVersionTwoDiagnostics() throws {
        let json = """
        {
          "schemaVersion": 1,
          "timestamp": "2026-08-13T12:00:00.000Z",
          "appVersion": "1.0",
          "appBuild": "1",
          "eventID": "00000000-0000-0000-0000-000000000001",
          "sessionID": "00000000-0000-0000-0000-000000000002",
          "event": "no_audio_after_start",
          "target": "new_entry",
          "stage": "first_buffer",
          "reason": "no_buffers",
          "preferredRoute": { "mode": "system_default" },
          "resolvedDeviceFormat": null,
          "engineState": {
            "phase": "running",
            "isRunning": true,
            "tapInstalled": true
          },
          "frames": 0,
          "elapsedSeconds": 2.0,
          "error": null
        }
        """

        let record = try JSONDecoder().decode(
            MicrophoneFailureLogRecord.self,
            from: Data(json.utf8)
        )
        #expect(record.schemaVersion == 1)
        #expect(record.attemptNumber == nil)
        #expect(record.requestedDeviceID == nil)
        #expect(record.baselineDeviceFormat == nil)
        #expect(record.currentDeviceFormat == nil)
        #expect(record.firstBufferFormat == nil)
        #expect(record.firstBufferLatencySeconds == nil)
        #expect(record.engineState.firstBufferConfirmed == nil)
    }

    @Test func logFileIsOwnerReadWriteOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "microphone-failures.jsonl")
        let logger = MicrophoneFailureLogger(
            url: url,
            clock: { fixedDate },
            version: fixedVersion
        )

        #expect(logger.log(event()))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test func writeFailureIsNonthrowingAndDoesNotAffectCaller() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let regularFile = directory.appending(path: "not-a-directory")
        try Data("occupied".utf8).write(to: regularFile)
        let impossibleURL = regularFile.appending(path: "microphone-failures.jsonl")
        let logger = MicrophoneFailureLogger(
            url: impossibleURL,
            clock: { fixedDate },
            version: fixedVersion
        )

        var callerContinued = false
        #expect(!logger.log(event()))
        callerContinued = true
        #expect(callerContinued)
        #expect(try Data(contentsOf: regularFile) == Data("occupied".utf8))
    }

    @Test func replacementHardCrashReturnsSilentMicObservationBeforePromotion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entryPath = "transcride-2026-08-13T18-45-00"
        let entryURL = root.appending(path: entryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try EntryCreator.writeRecordingStub(
            entryURL: entryURL,
            created: Date(timeIntervalSince1970: 1_786_579_500),
            duration: 1
        )

        let region = ReplacementRegion(
            selection: .init(start: 0, end: 1),
            timelineDuration: 1,
            sampleRate: 44_100
        )
        let session = ReplacementTakeSession(
            entryRelativePath: entryPath,
            sourceAudioFileName: "audio.m4a",
            timelineDuration: 1,
            region: region
        )
        let service = VaultService(rootURL: root)
        try await service.saveReplacementSession(session)
        try writeSilentJournal(
            frames: 4_410,
            to: entryURL.appending(path: AudioReplacementArtifacts.partialFileName)
        )

        let discovery = await service.replacementTakeSessions()
        let observation = try #require(discovery.microphoneObservations.first)
        #expect(observation.sessionID == session.id)
        #expect(observation.inspection.frames == 4_410)
        #expect(observation.inspection.terminalState == .perfectlySilent)
        #expect(discovery.recoverable.first?.takes.count == 1)
    }
}

@Suite("Replacement take orphan recovery", .serialized)
struct ReplacementTakeOrphanRecoveryIntegrationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "transcride-replacement-orphan-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(
        in root: URL
    ) async throws -> (service: VaultService, entryURL: URL, session: ReplacementTakeSession) {
        let entryPath = "transcride-2026-08-13T19-00-00"
        let entryURL = root.appending(path: entryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        try EntryCreator.writeRecordingStub(
            entryURL: entryURL,
            created: Date(timeIntervalSince1970: 1_786_580_000),
            duration: 0.1
        )
        let region = ReplacementRegion(
            selection: .init(start: 0, end: 0.1),
            timelineDuration: 0.1,
            sampleRate: 44_100
        )
        let session = ReplacementTakeSession(
            entryRelativePath: entryPath,
            sourceAudioFileName: "audio.m4a",
            timelineDuration: 0.1,
            region: region
        )
        let service = VaultService(rootURL: root)
        try await service.saveReplacementSession(session)
        return (service, entryURL, session)
    }

    private func sessionDirectory(in entryURL: URL) -> URL {
        entryURL.appending(
            path: AudioReplacementArtifacts.sessionDirectoryName,
            directoryHint: .isDirectory
        )
    }

    private func writePCM(
        frames: AVAudioFrameCount,
        sampleRate: Double = 44_100,
        to url: URL
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frames
        ))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                channel[index] = Float((index % 31) - 15) / 100
            }
        }
        try file.write(from: buffer)
    }

    private func writeM4A(
        frames: AVAudioFrameCount,
        encoding: RecordingOutputEncoding = .aac,
        to url: URL
    ) throws {
        let journal = url.deletingLastPathComponent().appending(
            path: ".fixture-\(UUID().uuidString).caf"
        )
        defer { try? FileManager.default.removeItem(at: journal) }
        try writePCM(frames: frames, to: journal)
        try CrashTolerantAudioJournal.encodeM4A(
            from: journal,
            to: url,
            encoding: encoding
        )
    }

    private func persistedSession(in entryURL: URL) throws -> ReplacementTakeSession {
        let url = sessionDirectory(in: entryURL).appending(
            path: AudioReplacementArtifacts.sessionFileName
        )
        return try JSONDecoder().decode(
            ReplacementTakeSession.self,
            from: Data(contentsOf: url)
        )
    }

    @Test func validEncodedOrphanIsPersistedExactlyOnceAcrossDiscoveries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeSession(in: root)
        let takeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let fileName = AudioReplacementArtifacts.takeFileName(id: takeID)
        try writeM4A(
            frames: AVAudioFrameCount(fixture.session.region.frameCount),
            to: sessionDirectory(in: fixture.entryURL).appending(path: fileName)
        )

        let firstDiscovery = await fixture.service.replacementTakeSessions()
        let firstSession = try #require(firstDiscovery.recoverable.first)
        let recovered = try #require(firstSession.takes.first)
        #expect(firstSession.takes.count == 1)
        #expect(recovered.id == takeID)
        #expect(recovered.fileName == fileName)
        #expect(recovered.number == 1)
        #expect(recovered.capturedFrames == fixture.session.region.frameCount)
        #expect(recovered.sampleRate == fixture.session.region.sampleRate)
        #expect(recovered.status == .complete)
        #expect(firstSession.selectedTakeID == takeID)
        #expect(firstSession.phase == .ready)

        let durable = try persistedSession(in: fixture.entryURL)
        #expect(durable.takes == firstSession.takes)
        #expect(durable.selectedTakeID == takeID)

        let secondDiscovery = await fixture.service.replacementTakeSessions()
        let secondSession = try #require(secondDiscovery.recoverable.first)
        #expect(secondSession.takes.count == 1)
        #expect(secondSession.takes.first?.id == takeID)
        #expect(try persistedSession(in: fixture.entryURL).takes.count == 1)
    }

    @Test func corruptMismatchedAndForeignFilesAreIgnoredAndRetained() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeSession(in: root)
        let directory = sessionDirectory(in: fixture.entryURL)

        let corruptID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let corruptURL = directory.appending(
            path: AudioReplacementArtifacts.takeFileName(id: corruptID)
        )
        try Data("not an audio file".utf8).write(to: corruptURL)

        let wrongRateID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let wrongRateURL = directory.appending(
            path: AudioReplacementArtifacts.takeFileName(
                id: wrongRateID, fileExtension: "caf"
            )
        )
        try writePCM(frames: 4_410, sampleRate: 48_000, to: wrongRateURL)

        let overlongID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let overlongURL = directory.appending(
            path: AudioReplacementArtifacts.takeFileName(
                id: overlongID, fileExtension: "caf"
            )
        )
        try writePCM(frames: 4_500, to: overlongURL)

        let foreignURL = directory.appending(path: AudioReplacementArtifacts.previewFileName)
        try writeM4A(frames: 4_410, to: foreignURL)
        let uppercaseURL = directory.appending(
            path: "take-20000000-0000-0000-0000-000000000004.m4a".uppercased()
        )
        try writeM4A(frames: 4_410, to: uppercaseURL)
        let temporaryURL = directory.appending(
            path: "take-20000000-0000-0000-0000-000000000005.m4a.tmp"
        )
        try Data("temporary".utf8).write(to: temporaryURL)

        let discovery = await fixture.service.replacementTakeSessions()
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.takes.isEmpty)
        #expect(try persistedSession(in: fixture.entryURL).takes.isEmpty)
        for url in [corruptURL, wrongRateURL, overlongURL, foreignURL, uppercaseURL, temporaryURL] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func alreadyReferencedTakeIsNotDuplicated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try await makeSession(in: root)
        let takeID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let fileName = AudioReplacementArtifacts.takeFileName(id: takeID)
        let take = ReplacementTake(
            id: takeID,
            number: 7,
            fileName: fileName,
            capturedFrames: fixture.session.region.frameCount,
            sampleRate: fixture.session.region.sampleRate,
            createdAt: Date(timeIntervalSince1970: 1_786_580_010),
            status: .complete
        )
        fixture.session.appendTake(take)
        try await fixture.service.saveReplacementSession(fixture.session)
        try writeM4A(
            frames: AVAudioFrameCount(fixture.session.region.frameCount),
            to: sessionDirectory(in: fixture.entryURL).appending(path: fileName)
        )

        let discovery = await fixture.service.replacementTakeSessions()
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.takes == [take])
        #expect(recovered.selectedTakeID == takeID)
        #expect(try persistedSession(in: fixture.entryURL).takes == [take])
    }

    @Test func multipleOrphansReceiveDeterministicNumbersAndStatuses() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try await makeSession(in: root)
        let priorID = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
        fixture.session.appendTake(ReplacementTake(
            id: priorID,
            number: 4,
            fileName: AudioReplacementArtifacts.takeFileName(id: priorID),
            capturedFrames: fixture.session.region.frameCount,
            sampleRate: fixture.session.region.sampleRate,
            createdAt: Date(timeIntervalSince1970: 1_786_580_020),
            status: .complete
        ))
        try await fixture.service.saveReplacementSession(fixture.session)

        let incompleteID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let completeID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        try writePCM(
            frames: 2_205,
            to: sessionDirectory(in: fixture.entryURL).appending(
                path: AudioReplacementArtifacts.takeFileName(
                    id: incompleteID, fileExtension: "caf"
                )
            )
        )
        try writeM4A(
            frames: AVAudioFrameCount(fixture.session.region.frameCount),
            to: sessionDirectory(in: fixture.entryURL).appending(
                path: AudioReplacementArtifacts.takeFileName(id: completeID)
            )
        )

        let discovery = await fixture.service.replacementTakeSessions()
        let recovered = try #require(discovery.recoverable.first)
        #expect(recovered.takes.map(\.id) == [priorID, incompleteID, completeID])
        #expect(recovered.takes.map(\.number) == [4, 5, 6])
        #expect(recovered.takes.map(\.status) == [.complete, .incomplete, .complete])
        #expect(recovered.selectedTakeID == completeID)
        #expect(try persistedSession(in: fixture.entryURL).takes == recovered.takes)
    }

    @Test func cancellationMarkerRemainsAuthoritativeOverAValidOrphan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeSession(in: root)
        let takeID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let orphanURL = sessionDirectory(in: fixture.entryURL).appending(
            path: AudioReplacementArtifacts.takeFileName(id: takeID)
        )
        try writeM4A(
            frames: AVAudioFrameCount(fixture.session.region.frameCount),
            to: orphanURL
        )
        let markerURL = fixture.entryURL.appending(
            path: AudioReplacementArtifacts.cancellationMarkerFileName
        )
        try AtomicFile.write(Data("cancelled".utf8), to: markerURL)

        let discovery = await fixture.service.replacementTakeSessions()
        #expect(discovery.recoverable.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }
}
