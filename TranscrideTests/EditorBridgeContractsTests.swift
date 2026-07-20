import Foundation
import Testing

@Suite("Editor bridge contracts")
struct EditorBridgeContractsTests {
    @Test func methodRawValuesAreStableAndComplete() {
        #expect(EditorBridgeMethod.allCases.map(\.rawValue) == [
            "configure", "replaceDocument", "applyExternalChanges", "requestSnapshot",
            "captureViewState", "restoreViewState", "setStableDecorations",
            "setPlaybackDecoration", "setFrozen", "executeCommand",
            "ready", "patches", "snapshot", "viewState", "focusOwnership", "linkAction",
            "clickAction", "preferenceAction", "performance", "action",
        ])
        #expect(EditorNativeMethod.allCases.map(\.rawValue) == Array(
            EditorBridgeMethod.allCases.prefix(10).map(\.rawValue)
        ))
        #expect(EditorWebMethod.allCases.map(\.rawValue) == Array(
            EditorBridgeMethod.allCases.suffix(10).map(\.rawValue)
        ))
    }

    @Test func liveV1PayloadsRoundTripWithExactWireKeys() throws {
        let ready = EditorReadyPayload(
            protocolVersion: 1,
            loadToken: "load",
            utf16Coordinates: true,
            modes: [.original, .editedView, .editedEditing],
            capabilities: ["patches", "snapshots"]
        )
        let data = try JSONEncoder().encode(ready)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "protocolVersion", "loadToken", "utf16Coordinates", "modes", "capabilities",
        ]))
        #expect(try JSONDecoder().decode(EditorReadyPayload.self, from: data) == ready)

        let document = EditorReplaceDocumentPayload(
            text: "A\r\n😀",
            mode: .editedEditing,
            selection: [.init(anchor: 3, head: 5)],
            mainSelectionIndex: 0,
            scrollTop: 42,
            resetHistory: false
        )
        #expect(try JSONDecoder().decode(
            EditorReplaceDocumentPayload.self,
            from: JSONEncoder().encode(document)
        ) == document)

        let playback = EditorNativeDecorationPayload(
            from: 1,
            to: 3,
            kind: "playback",
            data: .init(follow: true, tooltip: nil)
        )
        let playbackData = try JSONEncoder().encode(playback)
        let playbackObject = try #require(
            JSONSerialization.jsonObject(with: playbackData) as? [String: Any]
        )
        let decorationData = try #require(playbackObject["data"] as? [String: Any])
        #expect(decorationData["follow"] as? Bool == true)
        #expect(decorationData["tooltip"] == nil)
        #expect(try JSONDecoder().decode(
            EditorNativeDecorationPayload.self,
            from: playbackData
        ) == playback)
    }

    @Test func envelopeRoundTripsWithVersionOne() throws {
        let envelope = EditorBridgeEnvelope(
            sessionID: "session-a",
            requestID: "request-a",
            sequence: 1,
            method: .patches,
            payload: EditorUTF16PatchBatch(
                baseLength: 4,
                patches: [.init(from: 1, to: 2, insert: "x")]
            )
        )
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            EditorBridgeEnvelope<EditorUTF16PatchBatch>.self,
            from: encoded
        )
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.sessionID == "session-a")
        #expect(decoded.requestID == "request-a")
        #expect(decoded.sequence == 1)
        #expect(decoded.method == .patches)
        #expect(decoded.payload == envelope.payload)
    }

    @Test func productionDirectionalPayloadAndReplyContractsMatchEveryV1Method() throws {
        let viewState: [String: Any] = [
            "selection": [["anchor": 0, "head": 0]],
            "mainSelectionIndex": 0,
            "scrollTop": 0.0,
        ]
        let nativePayloads: [(EditorNativeMethod, [String: Any], Any)] = [
            (.configure, [
                "preferences": [
                    "fontSize": 16, "width": "wide", "editedAlignment": "center",
                    "focusMode": false,
                ],
                "appearance": [
                    "colorScheme": "dark", "increasedContrast": false,
                    "reduceMotion": false,
                ],
            ], ["mode": "original"]),
            (.replaceDocument, [
                "text": "A\r\n😀", "mode": "editedEditing", "resetHistory": false,
                "selection": [["anchor": 0, "head": 1]],
            ], ["length": 5]),
            (.applyExternalChanges, [
                "mode": "editedEditing",
                "changes": [["from": 0, "to": 1, "insert": "B"]],
            ], ["text": "B", "length": 1]),
            (.requestSnapshot, ["reason": "transition"], [
                "text": "A", "mode": "editedEditing", "viewState": viewState,
                "reason": "transition",
            ]),
            (.captureViewState, [:], viewState),
            (.restoreViewState, viewState, viewState),
            (.setStableDecorations, ["decorations": []], ["count": 0]),
            (.setPlaybackDecoration, ["decoration": NSNull()], ["active": false]),
            (.setFrozen, ["frozen": true, "reason": "conflict"], ["frozen": true]),
            (.executeCommand, ["command": "bold"], true),
        ]
        for (method, payload, reply) in nativePayloads {
            try EditorBridgePayloadContract.validateNativePayload(
                method: method,
                payload: payload
            )
            try EditorBridgePayloadContract.validateNativeReply(
                method: method,
                reply: reply
            )
        }

        let webPayloads: [(EditorWebMethod, [String: Any])] = [
            (.ready, [
                "protocolVersion": 1, "loadToken": "load", "utf16Coordinates": true,
                "modes": ["original", "editedView", "editedEditing"],
                "capabilities": ["patches"],
            ]),
            (.patches, [
                "baseLength": 1, "intent": "text",
                "changes": [["from": 0, "to": 1, "insert": "B"]],
            ]),
            (.snapshot, [
                "text": "A", "mode": "editedEditing", "viewState": viewState,
                "reason": "save",
            ]),
            (.viewState, viewState),
            (.focusOwnership, [
                "owner": "editor", "acceptsTextInput": true,
                "historyOwnership": false, "composing": false,
                "mode": "editedEditing",
            ]),
            (.linkAction, [
                "kind": "wikilink", "target": "Note", "alias": NSNull(),
                "from": 0, "to": 8,
            ]),
            (.clickAction, ["kind": "enterEditing", "position": 0]),
            (.preferenceAction, ["kind": "fontSize", "value": 17]),
            (.performance, [
                "kind": "input", "sampleCount": 200, "p95Milliseconds": 5.0,
                "maximumMilliseconds": 10.0, "documentLength": 10_000,
                "targetMet": true,
            ]),
            (.action, ["kind": "transportFailure", "message": "reply lost"]),
        ]
        for (method, payload) in webPayloads {
            try EditorBridgePayloadContract.validateWebPayload(
                method: method,
                payload: payload
            )
        }

        #expect(throws: EditorBridgePayloadContractError.invalidPayload(method: "patches")) {
            try EditorBridgePayloadContract.validateWebPayload(
                method: .patches,
                payload: ["baseLength": 1, "intent": "text", "patches": []]
            )
        }
        #expect(throws: EditorBridgePayloadContractError.invalidReply(method: "executeCommand")) {
            try EditorBridgePayloadContract.validateNativeReply(
                method: .executeCommand,
                reply: ["accepted": true]
            )
        }
    }

    @Test func validatorRejectsVersionSessionSequenceAndUnknownMethod() throws {
        var validator = EditorBridgeSequenceValidator(activeSessionID: "active")

        #expect(throws: EditorBridgeValidationError.unsupportedProtocolVersion(2)) {
            try validator.validate(
                protocolVersion: 2,
                sessionID: "active",
                sequence: 1,
                methodRawValue: "ready"
            )
        }
        #expect(throws: EditorBridgeValidationError.staleSession(
            expected: "active",
            received: "stale"
        )) {
            try validator.validate(
                protocolVersion: 1,
                sessionID: "stale",
                sequence: 1,
                methodRawValue: "ready"
            )
        }
        #expect(throws: EditorBridgeValidationError.unknownMethod("mystery")) {
            try validator.validate(
                protocolVersion: 1,
                sessionID: "active",
                sequence: 1,
                methodRawValue: "mystery"
            )
        }

        #expect(try validator.validate(
            protocolVersion: 1,
            sessionID: "active",
            sequence: 1,
            methodRawValue: "ready"
        ) == .ready)
        #expect(throws: EditorBridgeValidationError.invalidSequence(expected: 2, received: 1)) {
            try validator.validate(
                protocolVersion: 1,
                sessionID: "active",
                sequence: 1,
                methodRawValue: "ready"
            )
        }
        #expect(throws: EditorBridgeValidationError.invalidSequence(expected: 2, received: 3)) {
            try validator.validate(
                protocolVersion: 1,
                sessionID: "active",
                sequence: 3,
                methodRawValue: "ready"
            )
        }
        #expect(try validator.validate(
            protocolVersion: 1,
            sessionID: "active",
            sequence: 2,
            methodRawValue: "snapshot"
        ) == .snapshot)
    }

    @Test func resetRejectsOldSessionAndRestartsSequence() throws {
        var validator = EditorBridgeSequenceValidator(activeSessionID: "old")
        _ = try validator.validate(
            protocolVersion: 1,
            sessionID: "old",
            sequence: 1,
            methodRawValue: "ready"
        )
        validator.reset(sessionID: "new")
        #expect(throws: EditorBridgeValidationError.staleSession(expected: "new", received: "old")) {
            try validator.validate(
                protocolVersion: 1,
                sessionID: "old",
                sequence: 2,
                methodRawValue: "snapshot"
            )
        }
        #expect(try validator.validate(
            protocolVersion: 1,
            sessionID: "new",
            sequence: 1,
            methodRawValue: "ready"
        ) == .ready)
    }

    @Test func appliesSortedMultiRangeUTF16PatchesIncludingEmoji() throws {
        let body = "A😀BC café"
        let batch = EditorUTF16PatchBatch(
            baseLength: body.utf16.count,
            patches: [
                .init(from: 1, to: 3, insert: "🦊"),
                .init(from: 4, to: 5, insert: "!"),
                .init(from: 10, to: 10, insert: "?"),
            ]
        )
        #expect(try batch.applying(to: body) == "A🦊B! café?")
    }

    @Test func rejectsEveryUnsafePatchShapeForSnapshotResync() {
        let body = "A😀B"
        let failures: [EditorUTF16PatchBatch] = [
            .init(baseLength: 99, patches: []),
            .init(baseLength: 4, patches: [.init(from: -1, to: 0, insert: "")]),
            .init(baseLength: 4, patches: [.init(from: 3, to: 2, insert: "")]),
            .init(baseLength: 4, patches: [
                .init(from: 2, to: 3, insert: ""),
                .init(from: 1, to: 1, insert: "x"),
            ]),
            .init(baseLength: 4, patches: [.init(from: 2, to: 2, insert: "x")]),
        ]

        for batch in failures {
            do {
                _ = try batch.applying(to: body)
                Issue.record("Expected patch rejection")
            } catch let error as EditorPatchError {
                #expect(error.requiresSnapshotResynchronization)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func exactRevisionUsesUnnormalizedUTF8Bytes() {
        #expect(EditorBodyRevision(body: "abc").rawValue ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(EditorBodyRevision(body: "a\nb") != EditorBodyRevision(body: "a\r\nb"))
        #expect(EditorBodyRevision(body: "é") != EditorBodyRevision(body: "e\u{301}"))
    }

    @Test func inputOwnershipDistinguishesReadOnlyFromTextInput() {
        #expect(!EditorInputOwnership.none.ownsTextInput)
        #expect(!EditorInputOwnership.readOnly.ownsTextInput)
        #expect(EditorInputOwnership.editable.ownsTextInput)
        #expect(EditorInputOwnership.composition.ownsTextInput)
        #expect(EditorInputOwnership.search.ownsTextInput)
        #expect(EditorInputOwnership.replace.ownsTextInput)
    }
}
