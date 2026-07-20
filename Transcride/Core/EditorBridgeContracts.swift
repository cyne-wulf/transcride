import CryptoKit
import Foundation

/// The native/editor wire protocol is intentionally small and versioned. Raw
/// values are part of the JavaScript/Swift contract and must not be renamed.
enum EditorNativeMethod: String, CaseIterable, Codable, Sendable {
    case configure
    case replaceDocument
    case applyExternalChanges
    case requestSnapshot
    case captureViewState
    case restoreViewState
    case setStableDecorations
    case setPlaybackDecoration
    case setFrozen
    case executeCommand
}

enum EditorWebMethod: String, CaseIterable, Codable, Sendable {
    case ready
    case patches
    case snapshot
    case viewState
    case focusOwnership
    case linkAction
    case clickAction
    case preferenceAction
    case performance
    case action
}

enum EditorBridgeMethod: String, CaseIterable, Codable, Sendable {
    case configure, replaceDocument, applyExternalChanges, requestSnapshot
    case captureViewState, restoreViewState, setStableDecorations
    case setPlaybackDecoration, setFrozen, executeCommand
    case ready, patches, snapshot, viewState, focusOwnership, linkAction
    case clickAction, preferenceAction, performance, action
}

struct EditorBridgeEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    static var currentProtocolVersion: Int { 1 }

    var protocolVersion: Int
    var sessionID: String
    var requestID: String
    var sequence: Int
    var method: EditorBridgeMethod
    var payload: Payload

    init(
        protocolVersion: Int = Self.currentProtocolVersion,
        sessionID: String,
        requestID: String,
        sequence: Int,
        method: EditorBridgeMethod,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.requestID = requestID
        self.sequence = sequence
        self.method = method
        self.payload = payload
    }
}

enum EditorBridgeValidationError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case staleSession(expected: String, received: String)
    case invalidSequence(expected: Int, received: Int)
    case unknownMethod(String)
}

/// Stateful receive-side validation. Keep one instance per mounted web view and
/// reset it whenever a new editor session is created.
struct EditorBridgeSequenceValidator: Sendable {
    private(set) var activeSessionID: String
    private(set) var nextExpectedSequence: Int

    init(activeSessionID: String, firstExpectedSequence: Int = 1) {
        self.activeSessionID = activeSessionID
        nextExpectedSequence = firstExpectedSequence
    }

    mutating func reset(sessionID: String, firstExpectedSequence: Int = 1) {
        activeSessionID = sessionID
        nextExpectedSequence = firstExpectedSequence
    }

    @discardableResult
    mutating func validate(
        protocolVersion: Int,
        sessionID: String,
        sequence: Int,
        methodRawValue: String
    ) throws -> EditorBridgeMethod {
        guard protocolVersion == EditorBridgeEnvelope<EditorEmptyPayload>.currentProtocolVersion else {
            throw EditorBridgeValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard sessionID == activeSessionID else {
            throw EditorBridgeValidationError.staleSession(
                expected: activeSessionID,
                received: sessionID
            )
        }
        guard sequence == nextExpectedSequence else {
            throw EditorBridgeValidationError.invalidSequence(
                expected: nextExpectedSequence,
                received: sequence
            )
        }
        guard let method = EditorBridgeMethod(rawValue: methodRawValue) else {
            throw EditorBridgeValidationError.unknownMethod(methodRawValue)
        }
        nextExpectedSequence += 1
        return method
    }

    mutating func validate<Payload>(_ envelope: EditorBridgeEnvelope<Payload>) throws {
        _ = try validate(
            protocolVersion: envelope.protocolVersion,
            sessionID: envelope.sessionID,
            sequence: envelope.sequence,
            methodRawValue: envelope.method.rawValue
        )
    }
}

struct EditorEmptyPayload: Codable, Equatable, Sendable {
    init() {}
}

enum EditorMode: String, Codable, Sendable {
    case original
    case editedView
    case editedEditing
}

struct EditorSelectionState: Codable, Equatable, Sendable {
    var anchor: Int
    var head: Int
}

struct EditorViewState: Codable, Equatable, Sendable {
    var selection: [EditorSelectionState]
    var mainSelectionIndex: Int
    var scrollTop: Double
}

enum EditorInputOwnership: String, Codable, Sendable {
    case none
    case readOnly
    case editable
    case composition
    case search
    case replace

    var ownsTextInput: Bool {
        switch self {
        case .editable, .composition, .search, .replace: true
        case .none, .readOnly: false
        }
    }
}

struct EditorReadyPayload: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var loadToken: String
    var utf16Coordinates: Bool
    var modes: [EditorMode]
    var capabilities: [String]
}

struct EditorSnapshotPayload: Codable, Equatable, Sendable {
    var text: String
    var mode: EditorMode
    var viewState: EditorViewState
    var reason: String
}

enum EditorFocusOwner: String, Codable, Sendable {
    case application, editor, search
}

struct EditorFocusOwnershipPayload: Codable, Equatable, Sendable {
    var owner: EditorFocusOwner
    var acceptsTextInput: Bool
    var historyOwnership: Bool
    var composing: Bool
    var mode: EditorMode
}

struct EditorActionPayload: Codable, Equatable, Sendable {
    var kind: String
    var message: String?
}

enum EditorLinkKind: String, Codable, Sendable {
    case wikilink
    case markdownLink
}

struct EditorLinkPayload: Codable, Equatable, Sendable {
    var kind: EditorLinkKind
    var target: String?
    var alias: String?
    var label: String?
    var destination: String?
    var from: Int
    var to: Int
}

struct EditorClickPayload: Codable, Equatable, Sendable {
    var kind: String
    var position: Int
}

enum EditorWidthPreset: String, Codable, Sendable {
    case narrow
    case wide
    case full
}

enum EditorAlignment: String, Codable, Sendable {
    case center
    case left
}

struct EditorConfigurationPayload: Codable, Equatable, Sendable {
    var mode: EditorMode?
    var preferences: EditorWirePreferencesPayload
    var appearance: EditorAppearancePayload?
}

/// The bridge deliberately excludes the persistence-only preferences schema
/// version. These are the four fields JavaScript accepts on every configure.
struct EditorWirePreferencesPayload: Codable, Equatable, Sendable {
    var fontSize: Int
    var width: EditorWidthPreset
    var editedAlignment: EditorAlignment
    var focusMode: Bool
}

struct EditorAppearancePayload: Codable, Equatable, Sendable {
    var colorScheme: String
    var increasedContrast: Bool
    var reduceMotion: Bool
}

struct EditorReplaceDocumentPayload: Codable, Equatable, Sendable {
    var text: String
    var mode: EditorMode
    var selection: [EditorSelectionState]?
    var mainSelectionIndex: Int?
    var scrollTop: Double?
    var resetHistory: Bool
}

struct EditorExternalChangesPayload: Codable, Equatable, Sendable {
    var mode: EditorMode
    var changes: [EditorUTF16Patch]
}

struct EditorSnapshotRequestPayload: Codable, Equatable, Sendable {
    var reason: String
}

struct EditorUTF16Range: Codable, Equatable, Hashable, Sendable {
    var from: Int
    var to: Int
}

struct EditorNativeDecorationPayload: Codable, Equatable, Sendable {
    var from: Int
    var to: Int
    var kind: String
    var data: EditorNativeDecorationData?
}

struct EditorNativeDecorationData: Codable, Equatable, Sendable {
    var follow: Bool?
    var tooltip: String?
}

struct EditorStableDecorationsPayload: Codable, Equatable, Sendable {
    var decorations: [EditorNativeDecorationPayload]
}

struct EditorPlaybackDecorationPayload: Codable, Equatable, Sendable {
    var decoration: EditorNativeDecorationPayload?
}

struct EditorFreezePayload: Codable, Equatable, Sendable {
    var frozen: Bool
    var reason: String?
}

enum EditorCommand: String, Codable, Sendable {
    case openFind
    case closeFind
    case findNext
    case findPrevious
    case replaceNext
    case replaceAll
    case undo
    case redo
    case bold
    case italic
    case link
}

struct EditorCommandPayload: Codable, Equatable, Sendable {
    var command: EditorCommand
}

enum EditorPatchIntent: String, Codable, Sendable {
    case text, task, history
}

struct EditorPatchPayload: Codable, Equatable, Sendable {
    var baseLength: Int
    var intent: EditorPatchIntent
    var changes: [EditorUTF16Patch]
}

struct EditorPreferenceActionPayload: Codable, Equatable, Sendable {
    var kind: String
    var value: Int
}

struct EditorPerformancePayload: Codable, Equatable, Sendable {
    var kind: String
    var sampleCount: Int
    var p95Milliseconds: Double
    var maximumMilliseconds: Double
    var documentLength: Int
    var targetMet: Bool
}

struct EditorModeReply: Codable, Equatable, Sendable { var mode: EditorMode }
struct EditorLengthReply: Codable, Equatable, Sendable { var length: Int }
struct EditorExternalChangesReply: Codable, Equatable, Sendable {
    var text: String
    var length: Int
}
struct EditorCountReply: Codable, Equatable, Sendable { var count: Int }
struct EditorActiveReply: Codable, Equatable, Sendable { var active: Bool }
struct EditorFrozenReply: Codable, Equatable, Sendable { var frozen: Bool }

enum EditorBridgePayloadContractError: LocalizedError, Equatable, Sendable {
    case invalidPayload(method: String)
    case invalidReply(method: String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let method): "Invalid payload for editor method \(method)."
        case .invalidReply(let method): "Invalid reply for editor method \(method)."
        }
    }
}

/// Directional v1 method→payload/reply contract used by the live host. The
/// host retains its stricter semantic/range checks after this structural
/// decode, while this layer prevents the Core schema from drifting away from
/// the dictionaries delivered to and from JavaScript.
enum EditorBridgePayloadContract {
    static func validateNativePayload(
        method: EditorNativeMethod,
        payload: [String: Any]
    ) throws {
        do {
            switch method {
            case .configure: _ = try decode(EditorConfigurationPayload.self, from: payload)
            case .replaceDocument: _ = try decode(EditorReplaceDocumentPayload.self, from: payload)
            case .applyExternalChanges: _ = try decode(EditorExternalChangesPayload.self, from: payload)
            case .requestSnapshot: _ = try decode(EditorSnapshotRequestPayload.self, from: payload)
            case .captureViewState: _ = try decode(EditorEmptyPayload.self, from: payload)
            case .restoreViewState: _ = try decode(EditorViewState.self, from: payload)
            case .setStableDecorations: _ = try decode(EditorStableDecorationsPayload.self, from: payload)
            case .setPlaybackDecoration: _ = try decode(EditorPlaybackDecorationPayload.self, from: payload)
            case .setFrozen: _ = try decode(EditorFreezePayload.self, from: payload)
            case .executeCommand: _ = try decode(EditorCommandPayload.self, from: payload)
            }
        } catch {
            throw EditorBridgePayloadContractError.invalidPayload(method: method.rawValue)
        }
    }

    static func validateNativeReply(
        method: EditorNativeMethod,
        reply: Any?
    ) throws {
        do {
            switch method {
            case .configure: _ = try decode(EditorModeReply.self, from: reply)
            case .replaceDocument: _ = try decode(EditorLengthReply.self, from: reply)
            case .applyExternalChanges: _ = try decode(EditorExternalChangesReply.self, from: reply)
            case .requestSnapshot: _ = try decode(EditorSnapshotPayload.self, from: reply)
            case .captureViewState, .restoreViewState:
                _ = try decode(EditorViewState.self, from: reply)
            case .setStableDecorations: _ = try decode(EditorCountReply.self, from: reply)
            case .setPlaybackDecoration: _ = try decode(EditorActiveReply.self, from: reply)
            case .setFrozen: _ = try decode(EditorFrozenReply.self, from: reply)
            case .executeCommand:
                guard reply is Bool else {
                    throw EditorBridgePayloadContractError.invalidReply(method: method.rawValue)
                }
            }
        } catch let error as EditorBridgePayloadContractError {
            throw error
        } catch {
            throw EditorBridgePayloadContractError.invalidReply(method: method.rawValue)
        }
    }

    static func validateWebPayload(
        method: EditorWebMethod,
        payload: [String: Any]
    ) throws {
        do {
            switch method {
            case .ready: _ = try decode(EditorReadyPayload.self, from: payload)
            case .patches: _ = try decode(EditorPatchPayload.self, from: payload)
            case .snapshot: _ = try decode(EditorSnapshotPayload.self, from: payload)
            case .viewState: _ = try decode(EditorViewState.self, from: payload)
            case .focusOwnership: _ = try decode(EditorFocusOwnershipPayload.self, from: payload)
            case .linkAction: _ = try decode(EditorLinkPayload.self, from: payload)
            case .clickAction: _ = try decode(EditorClickPayload.self, from: payload)
            case .preferenceAction: _ = try decode(EditorPreferenceActionPayload.self, from: payload)
            case .performance: _ = try decode(EditorPerformancePayload.self, from: payload)
            case .action: _ = try decode(EditorActionPayload.self, from: payload)
            }
        } catch {
            throw EditorBridgePayloadContractError.invalidPayload(method: method.rawValue)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from object: Any?
    ) throws -> Value {
        guard let object,
              JSONSerialization.isValidJSONObject(object) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Bridge value is not JSON"
            ))
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}

struct EditorUTF16Patch: Codable, Equatable, Sendable {
    var from: Int
    var to: Int
    var insert: String
}

struct EditorUTF16PatchBatch: Codable, Equatable, Sendable {
    var baseLength: Int
    var patches: [EditorUTF16Patch]

    func applying(to body: String) throws -> String {
        let actualLength = body.utf16.count
        guard baseLength == actualLength else {
            throw EditorPatchError.baseLengthMismatch(expected: baseLength, actual: actualLength)
        }

        var previousUpperBound = 0
        var ranges: [Range<String.Index>] = []
        ranges.reserveCapacity(patches.count)
        for (index, patch) in patches.enumerated() {
            guard patch.from >= 0, patch.to >= patch.from, patch.to <= baseLength else {
                throw EditorPatchError.invalidRange(index: index, from: patch.from, to: patch.to)
            }
            guard index == 0 || patch.from >= previousUpperBound else {
                throw EditorPatchError.unsortedOrOverlapping(index: index)
            }
            previousUpperBound = patch.to

            guard
                let lower = body.stringIndex(atUTF16Offset: patch.from),
                let upper = body.stringIndex(atUTF16Offset: patch.to)
            else {
                throw EditorPatchError.splitsSurrogatePair(index: index)
            }
            ranges.append(lower..<upper)
        }

        var result = body
        for index in patches.indices.reversed() {
            result.replaceSubrange(ranges[index], with: patches[index].insert)
        }
        return result
    }
}

enum EditorPatchError: Error, Equatable, Sendable {
    case baseLengthMismatch(expected: Int, actual: Int)
    case invalidRange(index: Int, from: Int, to: Int)
    case unsortedOrOverlapping(index: Int)
    case splitsSurrogatePair(index: Int)

    /// Patch failures are never repaired heuristically; the host requests an
    /// acknowledged full snapshot and replaces its mirror from that snapshot.
    var requiresSnapshotResynchronization: Bool { true }
}

private extension String {
    func stringIndex(atUTF16Offset offset: Int) -> String.Index? {
        guard offset >= 0, offset <= utf16.count else { return nil }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: self)
    }
}

/// SHA-256 over the exact UTF-8 bytes of the body. No line-ending, Unicode, or
/// whitespace normalization is performed.
struct EditorBodyRevision: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(body: String) {
        let digest = SHA256.hash(data: Data(body.utf8))
        rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }
}
