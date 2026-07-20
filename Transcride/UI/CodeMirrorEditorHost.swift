import AppKit
import SwiftUI
import WebKit

@MainActor
final class CodeMirrorEditorController: NSObject, ObservableObject {
    struct Snapshot: Equatable {
        var text: String
        var mode: EditorMode
        var selection: [EditorSelectionState]
        var mainSelectionIndex: Int
        var scrollTop: Double
    }

    struct PerformanceReport: Equatable, Sendable {
        var kind: String
        var sampleCount: Int
        var p95Milliseconds: Double
        var maximumMilliseconds: Double
        var documentLength: Int
        var targetMet: Bool
    }

    struct AppearanceState: Equatable, Sendable {
        var colorScheme: String
        var increasedContrast: Bool
        var reduceMotion: Bool

        static let light = AppearanceState(
            colorScheme: "light",
            increasedContrast: false,
            reduceMotion: false
        )
    }

    let webView: WKWebView
    private let messageProxy: EditorBridgeReplyProxy
    private(set) var acknowledgedBody = ""
    private(set) var mode: EditorMode = .original
    private var sessionID: String?
    private var expectedWebSequence = 0
    private var nativeSequence = 0
    private var sessionGeneration = 0
    private var seenWebRequestIDs = Set<String>()
    private var pendingLoadToken: String?
    private var activeLoadToken: String?
    private var initialNavigationURL: URL?
    private var initialNavigationConsumed = false
    private var authorizedRecoveryReload = false
    private var recoveryInProgress = false
    private var loaded = false
    private(set) var isReady = false
    private var pendingDocument: (
        body: String,
        mode: EditorMode,
        resetHistory: Bool,
        selection: [EditorSelectionState]?,
        scrollTop: Double?
    )?
    private var latestSnapshot: Snapshot?
    private var outboundSendInProgress = false
    private var outboundWaiters: [CheckedContinuation<Void, Never>] = []
    private var preferences = EditorPreferences()
    private var appearance = AppearanceState.light
    private var frozen = false
    private var frozenReason: String?
    private var pendingPatchSnapshotResync = false
    private var pendingEditedTaskSnapshotResync = false
#if DEBUG
    private var failNextPatchMessageForTesting = false
    private var shouldFailNextAcceptedPatchReplyForTesting = false
    private var failNextNativeMethodForTesting: String?
    private(set) var stableDecorationSendCountForTesting = 0
    private(set) var playbackDecorationSendCountForTesting = 0
    private(set) var deniedDownloadCountForTesting = 0
#endif

    var onReady: ((Bool) -> Void)?
    var onBodyChange: ((String) -> Void)?
    var onFocusOwnership: ((Bool) -> Void)?
    var onOriginalPosition: ((Int) -> Void)?
    var onEnterEditing: ((Int) -> Void)?
    var onLink: (([String: Any]) -> Void)?
    var onWebProcessRecovery: (() async -> Void)?
    var onUserScroll: (() -> Void)?
    var onFontSizePreference: ((Int) -> Void)?
    var onPerformanceReport: ((PerformanceReport) -> Void)?
    private(set) var performanceReports: [PerformanceReport] = []
    private(set) var lastPlaybackDecoration: Range<Int>?
    private(set) var lastSearchDecorations: [Range<Int>] = []
    private(set) var lastFollowRequested = false
    private var knowledgeDecorations: [[String: Any]] = []
    private var stableDecorationRevision = 0
    private var playbackDecorationRevision = 0
    private var sentStableDecorationRevision = -1
    private var sentPlaybackDecorationRevision = -1
    private var decorationFlushTask: Task<Void, Never>?
    private(set) var editorDocumentIdentity = EditorDocumentIdentity(
        vaultID: "",
        documentID: "",
        path: "",
        generation: 0
    )
    var editorEntryPath: RelativePath { editorDocumentIdentity.path }
    var prepareTransition: ((EditorTransitionReason) async -> Bool)?

    override init() {
        let configuration = WKWebViewConfiguration()
        let proxy = EditorBridgeReplyProxy()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.addScriptMessageHandler(
            proxy,
            contentWorld: .page,
            name: "editorBridge"
        )
        messageProxy = proxy
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
#if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
#endif
    }

    func loadIfNeeded(forceReload: Bool = false) {
        guard !loaded, !recoveryInProgress else { return }
        loaded = true
        isReady = false
        guard let indexURL = Self.editorIndexURL else {
            assertionFailure("EditorWeb/dist/index.html is missing from the application bundle")
            return
        }
        let token = UUID().uuidString
        var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
        components?.fragment = "load=\(token)"
        guard let loadURL = components?.url else {
            assertionFailure("Could not construct the editor load URL")
            return
        }
        pendingLoadToken = token
        activeLoadToken = nil
        initialNavigationURL = loadURL
        initialNavigationConsumed = false
        authorizedRecoveryReload = false
        if forceReload, Self.isTrustedEditorURL(webView.url) {
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "window.history.replaceState(null, '', '#load=' + token); return true",
                        arguments: ["token": token],
                        in: nil,
                        contentWorld: .page
                    )
                    authorizedRecoveryReload = true
                    webView.reloadFromOrigin()
                } catch {
                    webView.loadFileURL(
                        loadURL,
                        allowingReadAccessTo: indexURL.deletingLastPathComponent()
                    )
                }
            }
        } else {
            webView.loadFileURL(loadURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    func replaceDocument(
        _ body: String,
        mode: EditorMode,
        resetHistory: Bool,
        selection: [EditorSelectionState]? = nil,
        scrollTop: Double? = nil
    ) {
        pendingDocument = (body, mode, resetHistory, selection, scrollTop)
        guard sessionID != nil else { loadIfNeeded(); return }
        Task { try? await flushPendingDocumentAndConfiguration() }
    }

    @discardableResult
    func replaceDocumentAndWait(
        _ body: String,
        mode: EditorMode,
        resetHistory: Bool,
        selection: [EditorSelectionState]? = nil,
        scrollTop: Double? = nil
    ) async -> Bool {
        pendingDocument = (body, mode, resetHistory, selection, scrollTop)
        guard sessionID != nil, isReady else { loadIfNeeded(); return false }
        do {
            try await flushPendingDocumentAndConfiguration()
            return pendingDocument == nil
                && acknowledgedBody == body && self.mode == mode
        } catch {
            return false
        }
    }

    @discardableResult
    func applyExternalChangesAndWait(
        _ patches: [EditorUTF16Patch],
        resultingBody: String,
        mode: EditorMode
    ) async -> Bool {
        guard sessionID != nil, isReady, self.mode == mode,
              (try? EditorUTF16PatchBatch(
                baseLength: acknowledgedBody.utf16.count,
                patches: patches
              ).applying(to: acknowledgedBody)) == resultingBody else { return false }
        do {
            try await flushPendingDocumentAndConfiguration()
            let result = try await send(
                method: .applyExternalChanges,
                payload: [
                    "mode": mode.rawValue,
                    "changes": patches.map {
                        ["from": $0.from, "to": $0.to, "insert": $0.insert]
                    },
                ]
            )
            guard let reply = result as? [String: Any],
                  reply["text"] as? String == resultingBody else { return false }
            acknowledgedBody = resultingBody
            self.mode = mode
            return true
        } catch {
            return false
        }
    }

    func configure(mode: EditorMode? = nil, preferences: EditorPreferences) {
        self.preferences = preferences
        guard sessionID != nil else { return }
        Task {
            do {
                try await flushPendingDocumentAndConfiguration()
                try await sendConfiguration(modeOverride: mode)
                if let mode { self.mode = mode }
            } catch {
                // send() owns terminal recovery for ambiguous delivery.
            }
        }
    }

    func updateAppearance(
        colorScheme: String,
        increasedContrast: Bool,
        reduceMotion: Bool
    ) {
        guard colorScheme == "light" || colorScheme == "dark" else { return }
        let next = AppearanceState(
            colorScheme: colorScheme,
            increasedContrast: increasedContrast,
            reduceMotion: reduceMotion
        )
        guard next != appearance else { return }
        appearance = next
        guard sessionID != nil else { return }
        Task { try? await sendConfiguration() }
    }

    func execute(_ command: String) {
        guard sessionID != nil else { return }
        Task {
            try? await flushPendingDocumentAndConfiguration()
            _ = try? await send(method: .executeCommand, payload: ["command": command])
        }
    }

    func executeAndWait(_ command: String) async -> Bool {
        guard sessionID != nil else { return false }
        do {
            try await flushPendingDocumentAndConfiguration()
            return (try await send(method: .executeCommand, payload: ["command": command]) as? Bool) ?? false
        } catch {
            return false
        }
    }

    func setDecorations(
        playback: Range<Int>?,
        search: [Range<Int>] = [],
        followPlayback: Bool = false
    ) {
        if lastSearchDecorations != search {
            lastSearchDecorations = search
            stableDecorationRevision &+= 1
        }
        if lastPlaybackDecoration != playback || lastFollowRequested != followPlayback {
            lastPlaybackDecoration = playback
            lastFollowRequested = followPlayback
            playbackDecorationRevision &+= 1
        }
        scheduleDecorationFlush()
    }

    func setLinkDecorations(
        unresolved: [Range<Int>],
        ambiguous: [(range: Range<Int>, tooltip: String)]
    ) {
        knowledgeDecorations = unresolved.map {
            ["from": $0.lowerBound, "to": $0.upperBound, "kind": "unresolvedLink"]
        } + ambiguous.map {
            [
                "from": $0.range.lowerBound,
                "to": $0.range.upperBound,
                "kind": "ambiguousLink",
                "data": ["tooltip": $0.tooltip],
            ]
        }
        stableDecorationRevision &+= 1
        scheduleDecorationFlush()
    }

    private func scheduleDecorationFlush() {
        guard sessionID != nil, decorationFlushTask == nil else { return }
        decorationFlushTask = Task { @MainActor [weak self] in
            // One task owns this channel. Playback ticks only replace the
            // latest desired state while a send is in flight; they never form
            // an unbounded queue behind WebKit.
            try? await Task.sleep(for: .milliseconds(8))
            await self?.flushDecorationChannels()
            guard let self else { return }
            self.decorationFlushTask = nil
            if self.sentStableDecorationRevision != self.stableDecorationRevision
                || self.sentPlaybackDecorationRevision != self.playbackDecorationRevision {
                self.scheduleDecorationFlush()
            }
        }
    }

    private func flushDecorationChannels() async {
        guard sessionID != nil else { return }
        do {
            try await flushPendingDocumentAndConfiguration()
            while sessionID != nil {
                let stableRevision = stableDecorationRevision
                let playbackRevision = playbackDecorationRevision
                if sentStableDecorationRevision != stableRevision {
                    try await sendStableDecorations()
                    sentStableDecorationRevision = stableRevision
                }
                if sentPlaybackDecorationRevision != playbackRevision {
                    try await sendPlaybackDecoration()
                    sentPlaybackDecorationRevision = playbackRevision
                }
                if stableRevision == stableDecorationRevision,
                   playbackRevision == playbackDecorationRevision { return }
            }
        } catch {
            // send() initiates native-owned recovery. Both revision counters
            // remain dirty and are replayed after the next ready handshake.
        }
    }

    private func sendStableDecorations() async throws {
        let validRange: (Range<Int>) -> Bool = { range in
            range.lowerBound <= range.upperBound
                && Self.isValidUTF16Boundary(range.lowerBound, in: self.acknowledgedBody)
                && Self.isValidUTF16Boundary(range.upperBound, in: self.acknowledgedBody)
        }
        var decorations: [[String: Any]] = lastSearchDecorations
            .filter(validRange)
            .map { ["from": $0.lowerBound, "to": $0.upperBound, "kind": "search"] }
        decorations.append(contentsOf: knowledgeDecorations.filter { decoration in
            guard let from = decoration["from"] as? Int,
                  let to = decoration["to"] as? Int else { return false }
            return validRange(from..<to)
        })
        _ = try await send(
            method: .setStableDecorations,
            payload: ["decorations": decorations]
        )
#if DEBUG
        stableDecorationSendCountForTesting &+= 1
#endif
    }

    private func sendPlaybackDecoration() async throws {
        var payload: [String: Any] = ["decoration": NSNull()]
        if let playback = lastPlaybackDecoration,
           playback.lowerBound <= playback.upperBound,
           Self.isValidUTF16Boundary(playback.lowerBound, in: acknowledgedBody),
           Self.isValidUTF16Boundary(playback.upperBound, in: acknowledgedBody) {
            payload["decoration"] = [
                "from": playback.lowerBound,
                "to": playback.upperBound,
                "kind": "playback",
                "data": ["follow": lastFollowRequested],
            ]
        }
        _ = try await send(method: .setPlaybackDecoration, payload: payload)
#if DEBUG
        playbackDecorationSendCountForTesting &+= 1
#endif
    }

    func setFrozen(_ frozen: Bool, reason: String? = nil) {
        self.frozen = frozen
        frozenReason = reason
        guard sessionID != nil else { return }
        Task {
            try? await flushPendingDocumentAndConfiguration()
            try? await sendFrozenState()
        }
    }

    @discardableResult
    func setFrozenAndWait(_ frozen: Bool, reason: String? = nil) async -> Bool {
        let previousFrozen = self.frozen
        let previousReason = frozenReason
        self.frozen = frozen
        frozenReason = reason
        guard sessionID != nil, isReady else {
            if !frozen {
                return await establishFrozenStateAfterRecovery(false, reason: reason)
            }
            self.frozen = previousFrozen
            frozenReason = previousReason
            return false
        }
        do {
            try await flushPendingDocumentAndConfiguration()
            try await sendFrozenState()
            return true
        } catch {
            // A requested unfreeze is authoritative across an ambiguous
            // delivery. Recovery must configure the replacement page as
            // unfrozen and this call does not succeed until that handshake is
            // acknowledged. A failed freeze still rolls back to the prior
            // usable state.
            if !frozen {
                return await establishFrozenStateAfterRecovery(false, reason: reason)
            }
            self.frozen = previousFrozen
            frozenReason = previousReason
            return false
        }
    }

    private func establishFrozenStateAfterRecovery(
        _ targetFrozen: Bool,
        reason: String?
    ) async -> Bool {
        self.frozen = targetFrozen
        frozenReason = reason
        if sessionID == nil, !loaded, !recoveryInProgress { loadIfNeeded() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            self.frozen = targetFrozen
            frozenReason = reason
            if sessionID != nil, isReady {
                do {
                    try await flushPendingDocumentAndConfiguration()
                    try await sendFrozenState()
                    return self.frozen == targetFrozen
                } catch {
                    // send() starts a fresh native-issued recovery when the
                    // delivery outcome is ambiguous. Retain the requested
                    // state while that replacement session becomes ready.
                    self.frozen = targetFrozen
                    frozenReason = reason
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func sendFrozenState() async throws {
        var payload: [String: Any] = ["frozen": frozen]
        if let frozenReason { payload["reason"] = frozenReason }
        _ = try await send(method: .setFrozen, payload: payload)
    }

    func snapshot(reason: String) async -> Snapshot? {
        guard sessionID != nil, isReady else { return nil }
        do {
            try await flushPendingDocumentAndConfiguration()
            let result = try await send(method: .requestSnapshot, payload: ["reason": reason])
            let snapshot = parseSnapshot(result)
            if let snapshot { latestSnapshot = snapshot }
            return snapshot
        } catch {
            return nil
        }
    }

    private func flushPendingDocumentAndConfiguration() async throws {
        while pendingDocument != nil {
            try await sendOnePendingDocument()
        }
    }

    private func sendOnePendingDocument() async throws {
        guard let pendingDocument else { return }
        self.pendingDocument = nil
        var payload: [String: Any] = [
            "text": pendingDocument.body,
            "mode": pendingDocument.mode.rawValue,
            "resetHistory": pendingDocument.resetHistory,
        ]
        if let selection = pendingDocument.selection {
            payload["selection"] = selection.map { ["anchor": $0.anchor, "head": $0.head] }
        }
        if let scrollTop = pendingDocument.scrollTop { payload["scrollTop"] = scrollTop }
        do {
            // Apply appearance/preferences before exposing document content so
            // a dark window never flashes the default light theme. The mode is
            // changed by replaceDocument itself: configuring the destination
            // mode first would erase the web editor's old-layer identity and
            // overwrite its separately retained Original/Edited history.
            try await sendConfiguration(includeMode: false)
            _ = try await send(method: .replaceDocument, payload: payload)
            acknowledgedBody = pendingDocument.body
            mode = pendingDocument.mode
            latestSnapshot = Snapshot(
                text: pendingDocument.body,
                mode: pendingDocument.mode,
                selection: Self.clampedSelection(
                    pendingDocument.selection ?? [EditorSelectionState(anchor: 0, head: 0)],
                    in: pendingDocument.body
                ),
                mainSelectionIndex: 0,
                scrollTop: max(0, pendingDocument.scrollTop ?? 0)
            )
        } catch {
            if self.pendingDocument == nil { self.pendingDocument = pendingDocument }
            throw error
        }
    }

    private func sendConfiguration(
        includeMode: Bool = true,
        modeOverride: EditorMode? = nil
    ) async throws {
        var payload: [String: Any] = [
            "preferences": [
                "fontSize": preferences.fontSize,
                "width": preferences.width.rawValue,
                "editedAlignment": preferences.editedAlignment.rawValue,
                "focusMode": preferences.focusMode,
            ],
            "appearance": [
                "colorScheme": appearance.colorScheme,
                "increasedContrast": appearance.increasedContrast,
                "reduceMotion": appearance.reduceMotion,
            ],
        ]
        if includeMode { payload["mode"] = (modeOverride ?? mode).rawValue }
        _ = try await send(method: .configure, payload: payload)
    }

    private func send(method: EditorNativeMethod, payload: [String: Any]) async throws -> Any? {
        let generation = sessionGeneration
        await acquireOutboundSendSlot()
        defer { releaseOutboundSendSlot() }
        guard generation == sessionGeneration else { throw EditorHostError.staleSessionGeneration }
        do {
#if DEBUG
            if failNextNativeMethodForTesting == method.rawValue {
                failNextNativeMethodForTesting = nil
                throw EditorHostError.bridge("Injected native \(method.rawValue) delivery failure")
            }
#endif
            return try await performSend(
                method: method,
                payload: payload,
                generation: generation
            )
        } catch {
            if generation == sessionGeneration {
                await recoverFromAmbiguousOutboundFailure()
            }
            throw error
        }
    }

    private func acquireOutboundSendSlot() async {
        if !outboundSendInProgress {
            outboundSendInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            outboundWaiters.append(continuation)
        }
    }

    private func releaseOutboundSendSlot() {
        if outboundWaiters.isEmpty {
            outboundSendInProgress = false
        } else {
            outboundWaiters.removeFirst().resume()
        }
    }

    private func resetOutboundSession() {
        sessionGeneration &+= 1
        nativeSequence = 0
        sentStableDecorationRevision = -1
        sentPlaybackDecorationRevision = -1
    }

    private func performSend(
        method: EditorNativeMethod,
        payload: [String: Any],
        generation: Int
    ) async throws -> Any? {
        try EditorBridgePayloadContract.validateNativePayload(
            method: method,
            payload: payload
        )
        guard let sessionID else { throw EditorHostError.notReady }
        guard generation == sessionGeneration else { throw EditorHostError.staleSessionGeneration }
        let sequence = nativeSequence
        let message: [String: Any] = [
            "protocolVersion": 1,
            "sessionID": sessionID,
            "requestID": UUID().uuidString,
            "sequence": sequence,
            "method": method.rawValue,
            "payload": payload,
        ]
        let raw = try await webView.callAsyncJavaScript(
            "return await window.transcrideEditor.handleNativeMessage(message)",
            arguments: ["message": message],
            in: nil,
            contentWorld: .page
        )
        guard generation == sessionGeneration else { throw EditorHostError.staleSessionGeneration }
        guard let reply = raw as? [String: Any],
              Set(reply.keys) == Set(["ok", "result"]),
              reply["ok"] as? Bool == true else {
            let message = (raw as? [String: Any])?["error"] as? String ?? "Editor rejected native message"
            throw EditorHostError.bridge(message)
        }
        try EditorBridgePayloadContract.validateNativeReply(
            method: method,
            reply: reply["result"]
        )
        nativeSequence = sequence + 1
        return reply["result"]
    }

    private func recoverFromAmbiguousOutboundFailure(
        postRecoveryFrozenState: (frozen: Bool, reason: String?)? = nil
    ) async {
        guard !recoveryInProgress else { return }
        recoveryInProgress = true
        let snapshot = latestSnapshot
        sessionID = nil
        activeLoadToken = nil
        pendingLoadToken = nil
        isReady = false
        expectedWebSequence = 0
        seenWebRequestIDs.removeAll()
        resetOutboundSession()
        let recoveryState = clampedRecoveryViewState()
        pendingDocument = (
            acknowledgedBody,
            mode,
            true,
            recoveryState?.selection ?? snapshot?.selection,
            recoveryState?.scrollTop ?? snapshot?.scrollTop
        )
        onReady?(false)
        loaded = false
        webView.stopLoading()
        await onWebProcessRecovery?()
        if let postRecoveryFrozenState {
            frozen = postRecoveryFrozenState.frozen
            frozenReason = postRecoveryFrozenState.reason
        }
        recoveryInProgress = false
        loadIfNeeded(forceReload: true)
    }

    func receive(_ body: Any) throws -> Any? {
        guard let envelope = body as? [String: Any],
              Set(envelope.keys) == Set(["protocolVersion", "sessionID", "requestID", "sequence", "method", "payload"]),
              envelope["protocolVersion"] as? Int == 1,
              let incomingSession = envelope["sessionID"] as? String,
              !incomingSession.isEmpty,
              let requestID = envelope["requestID"] as? String,
              !requestID.isEmpty,
              let sequence = envelope["sequence"] as? Int,
              let methodRawValue = envelope["method"] as? String,
              let method = EditorWebMethod(rawValue: methodRawValue),
              let payload = envelope["payload"] as? [String: Any]
        else { throw EditorHostError.bridge("Malformed editor envelope") }
        try EditorBridgePayloadContract.validateWebPayload(
            method: method,
            payload: payload
        )

#if DEBUG
        if method == .patches, failNextPatchMessageForTesting {
            failNextPatchMessageForTesting = false
            throw EditorHostError.bridge("Injected editor transport failure")
        }
#endif

        // A failed/reply-lost transport cannot participate in the ordinary
        // sequence any longer: the sender and receiver may disagree whether
        // N was consumed. Accept this one terminal signal from either the
        // active accepted session, bypass sequencing, freeze, and issue a
        // native-owned fresh session. A stale page cannot cancel a newer
        // pending load that has not completed its ready handshake.
        if method == .action,
           Set(payload.keys) == Set(["kind", "message"]),
           payload["kind"] as? String == "transportFailure",
           let message = payload["message"] as? String, !message.isEmpty {
            guard let sessionID, incomingSession == sessionID else {
                throw EditorHostError.bridge("Stale transport-failure session")
            }
            let postRecoveryFrozenState = (frozen: frozen, reason: frozenReason)
            frozen = true
            frozenReason = "Editor transport recovery"
            isReady = false
            onReady?(false)
            Task { @MainActor in
                await recoverFromAmbiguousOutboundFailure(
                    postRecoveryFrozenState: postRecoveryFrozenState
                )
            }
            return ["accepted": true, "terminalSession": true]
        }

        if method == .ready {
            guard sequence == 0 else { throw EditorHostError.bridge("Invalid ready sequence") }
            guard sessionID == nil,
                  let expectedLoadToken = pendingLoadToken,
                  Set(payload.keys) == Set(["protocolVersion", "utf16Coordinates", "modes", "capabilities", "loadToken"]),
                  payload["loadToken"] as? String == expectedLoadToken,
                  payload["protocolVersion"] as? Int == 1,
                  payload["utf16Coordinates"] as? Bool == true,
                  let modes = payload["modes"] as? [String],
                  Set(modes) == Set(["original", "editedView", "editedEditing"]),
                  let capabilities = payload["capabilities"] as? [String],
                  Set(["patches", "snapshots", "viewState", "search", "replace", "tasks", "formatting"])
                    .isSubset(of: Set(capabilities)) else {
                throw EditorHostError.bridge("Editor readiness capabilities are incompatible")
            }
            resetOutboundSession()
            sessionID = incomingSession
            activeLoadToken = expectedLoadToken
            pendingLoadToken = nil
            expectedWebSequence = 1
            seenWebRequestIDs = [requestID]
            isReady = true
            onReady?(true)
            Task {
                // Configuration comes first even when no document is queued;
                // the first visible frame therefore uses the window palette.
                try? await sendConfiguration()
                try? await flushPendingDocumentAndConfiguration()
                try? await sendFrozenState()
                scheduleDecorationFlush()
            }
            return ["accepted": true]
        }
        guard incomingSession == sessionID, sequence == expectedWebSequence else {
            throw EditorHostError.bridge("Stale or out-of-order editor message")
        }
        guard seenWebRequestIDs.insert(requestID).inserted else {
            throw EditorHostError.bridge("Duplicate editor request ID")
        }

        var response: [String: Any] = ["accepted": true]
        switch method {
        case .patches:
            guard Set(payload.keys) == Set(["baseLength", "intent", "changes"]),
                  let baseLength = payload["baseLength"] as? Int,
                  let intent = payload["intent"] as? String,
                  ["text", "task", "history"].contains(intent),
                  let rawChanges = payload["changes"] as? [[String: Any]] else {
                throw EditorHostError.bridge("Malformed patch payload")
            }
            let patches = try rawChanges.map { raw -> EditorUTF16Patch in
                guard Set(raw.keys) == Set(["from", "to", "insert"]),
                      let from = raw["from"] as? Int, let to = raw["to"] as? Int,
                      let insert = raw["insert"] as? String else {
                    throw EditorHostError.bridge("Malformed patch")
                }
                return EditorUTF16Patch(from: from, to: to, insert: insert)
            }
            guard !frozen, mode != .original else {
                throw EditorHostError.bridge("The current editor mode is immutable")
            }
            if mode == .editedView {
                guard ["task", "history"].contains(intent),
                      Self.isValidEditedViewTaskPatch(patches, in: acknowledgedBody) else {
                    throw EditorHostError.bridge("Edited view accepts only task history changes")
                }
            }
            do {
                let previousBody = acknowledgedBody
                acknowledgedBody = try EditorUTF16PatchBatch(baseLength: baseLength, patches: patches)
                    .applying(to: acknowledgedBody)
                if let latestSnapshot, latestSnapshot.mode == mode {
                    self.latestSnapshot = Snapshot(
                        text: acknowledgedBody,
                        mode: mode,
                        selection: Self.mapSelection(
                            latestSnapshot.selection,
                            through: patches,
                            from: previousBody,
                            to: acknowledgedBody
                        ),
                        mainSelectionIndex: min(
                            latestSnapshot.mainSelectionIndex,
                            max(0, latestSnapshot.selection.count - 1)
                        ),
                        scrollTop: max(0, latestSnapshot.scrollTop)
                    )
                }
                pendingEditedTaskSnapshotResync = false
                pendingPatchSnapshotResync = false
                onBodyChange?(acknowledgedBody)
            } catch is EditorPatchError {
                pendingPatchSnapshotResync = true
                pendingEditedTaskSnapshotResync = mode == .editedView
                    && ["task", "history"].contains(intent)
                response = ["accepted": false, "requiresSnapshot": true]
                // Consume this delivered sequence, return the typed rejection,
                // and independently request the full exact document. The web
                // side also reacts to `requiresSnapshot`; this native request
                // makes accepted-transport/reply-interpretation loss
                // idempotent instead of leaving the mirror stale forever.
                Task { @MainActor [weak self] in
                    _ = await self?.snapshot(reason: "native-patch-mismatch")
                }
            }
        case .snapshot:
            if let snapshot = parseSnapshot(payload) {
                guard snapshot.mode == mode else {
                    throw EditorHostError.bridge("Snapshot mode does not match the active editor mode")
                }
                if frozen || mode == .original || mode == .editedView {
                    let exactMirror = snapshot.text == acknowledgedBody
                    let validTaskResync = !frozen
                        && mode == .editedView
                        && pendingEditedTaskSnapshotResync
                        && Self.isValidEditedViewTaskSnapshot(snapshot.text, from: acknowledgedBody)
                    guard exactMirror || validTaskResync else {
                        throw EditorHostError.bridge("Immutable editor snapshot drifted from native state")
                    }
                }
                acknowledgedBody = snapshot.text
                mode = snapshot.mode
                latestSnapshot = snapshot
                pendingPatchSnapshotResync = false
                pendingEditedTaskSnapshotResync = false
                onBodyChange?(snapshot.text)
            } else { throw EditorHostError.bridge("Malformed snapshot payload") }
        case .focusOwnership:
            guard Set(payload.keys) == Set(["owner", "acceptsTextInput", "historyOwnership", "composing", "mode"]),
                  let owner = payload["owner"] as? String,
                  ["application", "editor", "search"].contains(owner),
                  let acceptsText = payload["acceptsTextInput"] as? Bool,
                  let historyOwnership = payload["historyOwnership"] as? Bool,
                  payload["composing"] is Bool,
                  let modeRaw = payload["mode"] as? String,
                  EditorMode(rawValue: modeRaw) != nil else {
                throw EditorHostError.bridge("Malformed focus ownership payload")
            }
            let owns = acceptsText || historyOwnership
            onFocusOwnership?(owns)
        case .clickAction:
            guard Set(payload.keys) == Set(["kind", "position"]),
                  let kind = payload["kind"] as? String,
                  ["originalPosition", "enterEditing"].contains(kind),
                  let position = payload["position"] as? Int,
                  Self.isValidUTF16Boundary(position, in: acknowledgedBody) else {
                throw EditorHostError.bridge("Malformed click payload")
            }
            if kind == "originalPosition" { onOriginalPosition?(position) }
            if kind == "enterEditing" { onEnterEditing?(position) }
        case .linkAction:
            guard let kind = payload["kind"] as? String,
                  ["wikilink", "markdownLink"].contains(kind),
                  Self.hasExactLinkPayloadShape(payload, kind: kind),
                  let from = payload["from"] as? Int, let to = payload["to"] as? Int,
                  from <= to,
                  Self.isValidUTF16Boundary(from, in: acknowledgedBody),
                  Self.isValidUTF16Boundary(to, in: acknowledgedBody),
                  Self.linkPayloadMatchesBody(payload, kind: kind, body: acknowledgedBody) else {
                throw EditorHostError.bridge("Malformed link payload")
            }
            onLink?(payload)
        case .preferenceAction:
            guard Set(payload.keys) == Set(["kind", "value"]),
                  payload["kind"] as? String == "fontSize", let size = payload["value"] as? Int,
                  (EditorPreferences.minimumFontSize...EditorPreferences.maximumFontSize).contains(size) else {
                throw EditorHostError.bridge("Malformed preference payload")
            }
            preferences.fontSize = size
            onFontSizePreference?(size)
        case .viewState:
            // A patch rejection deliberately leaves the native mirror behind
            // until the immediately following full snapshot. Selection may
            // already describe the newer web text, so consume but ignore this
            // transient report rather than turning a recoverable mismatch
            // into a terminal transport failure/reload of stale text.
            if pendingPatchSnapshotResync { break }
            guard let snapshot = parseViewState(payload) else {
                throw EditorHostError.bridge("Malformed view state")
            }
            latestSnapshot = snapshot
        case .performance:
            guard Set(payload.keys) == Set([
                "kind", "sampleCount", "p95Milliseconds", "maximumMilliseconds",
                "documentLength", "targetMet",
            ]),
                  let kind = payload["kind"] as? String,
                  ["input", "playback", "bridge"].contains(kind),
                  let sampleCount = payload["sampleCount"] as? Int, sampleCount > 0,
                  let p95 = Self.finiteDouble(payload["p95Milliseconds"]), p95 >= 0,
                  let maximum = Self.finiteDouble(payload["maximumMilliseconds"]), maximum >= p95,
                  let documentLength = payload["documentLength"] as? Int, documentLength >= 0,
                  let targetMet = payload["targetMet"] as? Bool else {
                throw EditorHostError.bridge("Malformed performance payload")
            }
            let report = PerformanceReport(
                kind: kind,
                sampleCount: sampleCount,
                p95Milliseconds: p95,
                maximumMilliseconds: maximum,
                documentLength: documentLength,
                targetMet: targetMet
            )
            performanceReports.append(report)
            onPerformanceReport?(report)
        case .action:
            if Set(payload.keys) == Set(["kind"]),
               payload["kind"] as? String == "userScroll" {
                onUserScroll?()
            } else {
                throw EditorHostError.bridge("Malformed editor action")
            }
        case .ready:
            throw EditorHostError.bridge("Duplicate editor readiness")
        }
        expectedWebSequence += 1
        return response
    }

    private func parseSnapshot(_ raw: Any?) -> Snapshot? {
        guard let payload = raw as? [String: Any],
              Set(payload.keys) == Set(["text", "mode", "viewState", "reason"]),
              let text = payload["text"] as? String,
              let modeRaw = payload["mode"] as? String,
              let mode = EditorMode(rawValue: modeRaw),
              let viewState = payload["viewState"] as? [String: Any],
              payload["reason"] is String
        else { return nil }
        return Self.parseViewState(viewState, text: text, mode: mode)
    }

    private func parseViewState(_ payload: [String: Any]) -> Snapshot? {
        Self.parseViewState(payload, text: acknowledgedBody, mode: mode)
    }

    private static func parseViewState(
        _ payload: [String: Any],
        text: String,
        mode: EditorMode
    ) -> Snapshot? {
        guard Set(payload.keys) == Set(["selection", "mainSelectionIndex", "scrollTop"]),
              let selectionPayload = payload["selection"] as? [[String: Any]],
              !selectionPayload.isEmpty,
              let main = payload["mainSelectionIndex"] as? Int,
              let scrollTop = finiteDouble(payload["scrollTop"]) else { return nil }
        let selection = selectionPayload.compactMap { item -> EditorSelectionState? in
            guard Set(item.keys) == Set(["anchor", "head"]),
                  let anchor = item["anchor"] as? Int, let head = item["head"] as? Int,
                  isValidUTF16Boundary(anchor, in: text),
                  isValidUTF16Boundary(head, in: text) else { return nil }
            return EditorSelectionState(anchor: anchor, head: head)
        }
        guard selection.count == selectionPayload.count,
              selection.indices.contains(main), scrollTop.isFinite, scrollTop >= 0 else { return nil }
        return Snapshot(
            text: text,
            mode: mode,
            selection: selection,
            mainSelectionIndex: main,
            scrollTop: scrollTop
        )
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? Int { number = Double(value) }
        else { number = nil }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func isValidUTF16Boundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: text) != nil
    }

    private func clampedRecoveryViewState() -> Snapshot? {
        guard let latestSnapshot, latestSnapshot.mode == mode else { return nil }
        let selection = Self.clampedSelection(latestSnapshot.selection, in: acknowledgedBody)
        return Snapshot(
            text: acknowledgedBody,
            mode: mode,
            selection: selection,
            mainSelectionIndex: min(
                latestSnapshot.mainSelectionIndex,
                max(0, selection.count - 1)
            ),
            scrollTop: latestSnapshot.scrollTop.isFinite
                ? max(0, latestSnapshot.scrollTop) : 0
        )
    }

    private static func clampedSelection(
        _ selection: [EditorSelectionState],
        in text: String
    ) -> [EditorSelectionState] {
        let source = selection.isEmpty
            ? [EditorSelectionState(anchor: 0, head: 0)] : selection
        return source.map {
            EditorSelectionState(
                anchor: clampedUTF16Boundary($0.anchor, in: text),
                head: clampedUTF16Boundary($0.head, in: text)
            )
        }
    }

    private static func clampedUTF16Boundary(_ offset: Int, in text: String) -> Int {
        var candidate = min(max(0, offset), text.utf16.count)
        while candidate > 0, !isValidUTF16Boundary(candidate, in: text) {
            candidate -= 1
        }
        return candidate
    }

    private static func mapSelection(
        _ selection: [EditorSelectionState],
        through patches: [EditorUTF16Patch],
        from oldText: String,
        to newText: String
    ) -> [EditorSelectionState] {
        func map(_ position: Int) -> Int {
            var delta = 0
            for patch in patches.sorted(by: { $0.from < $1.from }) {
                if position < patch.from { break }
                if position <= patch.to {
                    return clampedUTF16Boundary(
                        patch.from + delta + patch.insert.utf16.count,
                        in: newText
                    )
                }
                delta += patch.insert.utf16.count - (patch.to - patch.from)
            }
            return clampedUTF16Boundary(position + delta, in: newText)
        }
        _ = oldText
        return selection.map {
            EditorSelectionState(anchor: map($0.anchor), head: map($0.head))
        }
    }

    private static func isValidEditedViewTaskPatch(
        _ patches: [EditorUTF16Patch],
        in text: String
    ) -> Bool {
        guard patches.count == 1, let patch = patches.first,
              patch.to == patch.from + 1,
              patch.insert == " " || patch.insert == "x" || patch.insert == "X",
              patch.from > 0,
              patch.to < text.utf16.count,
              isValidUTF16Boundary(patch.from - 1, in: text),
              isValidUTF16Boundary(patch.to + 1, in: text) else { return false }
        let source = text as NSString
        let marker = source.substring(
            with: NSRange(location: patch.from - 1, length: 3)
        )
        return marker == "[ ]" || marker == "[x]" || marker == "[X]"
    }

    private static func isValidEditedViewTaskSnapshot(
        _ candidate: String,
        from baseline: String
    ) -> Bool {
        guard candidate.utf16.count == baseline.utf16.count else { return false }
        let old = baseline as NSString
        let new = candidate as NSString
        var changedOffset: Int?
        for offset in 0..<old.length where old.character(at: offset) != new.character(at: offset) {
            guard changedOffset == nil else { return false }
            changedOffset = offset
        }
        guard let changedOffset else { return false }
        let replacement = new.substring(with: NSRange(location: changedOffset, length: 1))
        return isValidEditedViewTaskPatch(
            [EditorUTF16Patch(from: changedOffset, to: changedOffset + 1, insert: replacement)],
            in: baseline
        )
    }

    private static func hasExactLinkPayloadShape(
        _ payload: [String: Any],
        kind: String
    ) -> Bool {
        switch kind {
        case "wikilink":
            guard Set(payload.keys) == Set(["kind", "target", "alias", "from", "to"]),
                  payload["target"] is String else { return false }
            return payload["alias"] is String || payload["alias"] is NSNull
        case "markdownLink":
            return Set(payload.keys) == Set(["kind", "label", "destination", "from", "to"])
                && payload["label"] is String
                && payload["destination"] is String
        default:
            return false
        }
    }

    private static func linkPayloadMatchesBody(
        _ payload: [String: Any],
        kind: String,
        body: String
    ) -> Bool {
        guard let from = payload["from"] as? Int,
              let to = payload["to"] as? Int,
              from >= 0, to >= from, to <= body.utf16.count else { return false }
        switch kind {
        case "wikilink":
            guard let target = payload["target"] as? String else { return false }
            let alias = payload["alias"] is NSNull ? nil : payload["alias"] as? String
            return EditorWikiLinkParser.links(in: body).contains {
                $0.range == EditorUTF16Range(from: from, to: to)
                    && $0.target == target && $0.alias == alias
            }
        case "markdownLink":
            guard let label = payload["label"] as? String,
                  let destination = payload["destination"] as? String else { return false }
            guard from == 0 || (body as NSString).substring(
                with: NSRange(location: from - 1, length: 1)
            ) != "!" else { return false }
            let source = body as NSString
            let slice = source.substring(with: NSRange(location: from, length: to - from))
            guard let expression = try? NSRegularExpression(
                pattern: #"^\[([^\]\r\n]*)\]\(([^)\r\n]*)\)$"#
            ), let match = expression.firstMatch(
                in: slice,
                range: NSRange(location: 0, length: (slice as NSString).length)
            ), match.range == NSRange(location: 0, length: (slice as NSString).length) else {
                return false
            }
            return (slice as NSString).substring(with: match.range(at: 1)) == label
                && (slice as NSString).substring(with: match.range(at: 2)) == destination
        default:
            return false
        }
    }

    fileprivate static var editorIndexURL: URL? {
        Bundle(for: CodeMirrorEditorController.self)
            .url(forResource: "index", withExtension: "html", subdirectory: "EditorWeb")
            ?? Bundle(for: CodeMirrorEditorController.self)
                .url(forResource: "index", withExtension: "html", subdirectory: "dist")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "EditorWeb")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist")
    }

    fileprivate static func isTrustedEditorURL(_ url: URL?) -> Bool {
        guard let candidate = normalizedEditorURL(url),
              let index = normalizedEditorURL(editorIndexURL) else { return false }
        return candidate == index
    }

    fileprivate static func isSameEditorDocument(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs = normalizedEditorURL(lhs),
              let rhs = normalizedEditorURL(rhs) else { return false }
        return lhs == rhs
    }

    private static func normalizedEditorURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        var components = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.standardizedFileURL
    }

    func evaluateJavaScriptForTesting(_ source: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            "return await (async () => { \(source) })()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

#if DEBUG
    /// Forces only the native mirror out of sync so the real-WK integration
    /// suite can exercise the production patch-rejection snapshot handshake.
    func forceAcknowledgedBodyForTesting(_ body: String) {
        acknowledgedBody = body
    }

    func failNextPatchTransportForTesting() {
        failNextPatchMessageForTesting = true
    }

    func failNextAcceptedPatchReplyForTesting() {
        shouldFailNextAcceptedPatchReplyForTesting = true
    }

    fileprivate func consumeAcceptedPatchReplyFailureForTesting(_ body: Any) -> Bool {
        guard shouldFailNextAcceptedPatchReplyForTesting,
              let envelope = body as? [String: Any],
              envelope["method"] as? String == EditorWebMethod.patches.rawValue else {
            return false
        }
        shouldFailNextAcceptedPatchReplyForTesting = false
        return true
    }

    func failNextNativeSendForTesting(method: String) {
        failNextNativeMethodForTesting = method
    }

    func forcePendingLoadWithoutAcceptedSessionForTesting() {
        sessionID = nil
        isReady = false
        pendingLoadToken = "pending-test-\(UUID().uuidString)"
    }

    var isFrozenForTesting: Bool { frozen }
    var latestSnapshotForTesting: Snapshot? { latestSnapshot }
#endif
}

extension CodeMirrorEditorController: EditorTransitionParticipant {
    func rebindEditorDocument(to identity: EditorDocumentIdentity) {
        editorDocumentIdentity = identity
    }

    func prepareForEditorTransition(_ reason: EditorTransitionReason) async -> Bool {
        if let prepareTransition { return await prepareTransition(reason) }
        return await snapshot(reason: String(describing: reason)) != nil
    }
}

private final class EditorBridgeReplyProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: CodeMirrorEditorController?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            guard message.frameInfo.isMainFrame else {
                replyHandler(nil, "Editor messages must come from the main frame")
                return
            }
            guard CodeMirrorEditorController.isTrustedEditorURL(message.frameInfo.request.url) else {
                replyHandler(nil, "Editor messages must come from the bundled editor origin")
                return
            }
            guard let owner else {
                replyHandler(nil, "Editor host has been released")
                return
            }
            // The WebKit transport always returns the same typed reply shape.
            // In particular, an accepted transport carrying
            // `{accepted:false, requiresSnapshot:true}` must not be confused
            // with a transport failure or silently double-wrapped by JS.
            do {
                let result = try owner.receive(message.body)
#if DEBUG
                if owner.consumeAcceptedPatchReplyFailureForTesting(message.body) {
                    replyHandler(nil, "Injected reply loss after native acceptance")
                    return
                }
#endif
                replyHandler([
                    "ok": true,
                    "result": result as Any,
                ], nil)
            }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }
}

extension CodeMirrorEditorController: WKNavigationDelegate, WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            if initialNavigationConsumed,
               let url = navigationAction.request.url,
               Self.isTrustedEditorURL(url),
               Self.isSameEditorDocument(url, initialNavigationURL) {
                decisionHandler(.cancel)
                Task { @MainActor in await recoverFromAmbiguousOutboundFailure() }
                return
            }
            let isAuthorizedRecoveryReload = authorizedRecoveryReload
                && navigationAction.navigationType == .reload
            guard !initialNavigationConsumed,
                  navigationAction.targetFrame?.isMainFrame == true,
                  navigationAction.navigationType == .other || isAuthorizedRecoveryReload,
                  !navigationAction.shouldPerformDownload,
                  let url = navigationAction.request.url,
                  url == initialNavigationURL,
                  Self.isTrustedEditorURL(url)
            else {
#if DEBUG
                if navigationAction.shouldPerformDownload {
                    deniedDownloadCountForTesting &+= 1
                }
#endif
                decisionHandler(.cancel)
                return
            }
            initialNavigationConsumed = true
            authorizedRecoveryReload = false
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        Task { @MainActor in
            guard navigationResponse.isForMainFrame,
                  navigationResponse.canShowMIMEType,
                  Self.isSameEditorDocument(
                    navigationResponse.response.url,
                    initialNavigationURL
                  ),
                  Self.isTrustedEditorURL(navigationResponse.response.url)
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard !recoveryInProgress else { return }
            recoveryInProgress = true
            loaded = false
            sessionID = nil
            activeLoadToken = nil
            pendingLoadToken = nil
            isReady = false
            expectedWebSequence = 0
            seenWebRequestIDs.removeAll()
            resetOutboundSession()
            let recoveryState = clampedRecoveryViewState()
            pendingDocument = (
                acknowledgedBody,
                mode,
                true,
                recoveryState?.selection,
                recoveryState?.scrollTop
            )
            onReady?(false)
            await onWebProcessRecovery?()
            recoveryInProgress = false
            loadIfNeeded(forceReload: true)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        Task { @MainActor in decisionHandler(.deny) }
    }
}

private enum EditorHostError: LocalizedError {
    case notReady
    case staleSessionGeneration
    case bridge(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "The editor is not ready."
        case .staleSessionGeneration: "The editor session changed before the message could be delivered."
        case .bridge(let message): message
        }
    }
}

struct CodeMirrorEditorHost: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let controller: CodeMirrorEditorController

    func makeNSView(context: Context) -> WKWebView {
        synchronizeAppearance(for: controller.webView)
        controller.loadIfNeeded()
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        synchronizeAppearance(for: nsView)
    }

    private func synchronizeAppearance(for _: WKWebView) {
        controller.updateAppearance(
            // The mounted SwiftUI environment is authoritative. WKWebView's
            // effectiveAppearance can still be the previous/default window
            // appearance during attachment and live per-window transitions.
            colorScheme: colorScheme == .dark ? "dark" : "light",
            increasedContrast: colorSchemeContrast == .increased
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: accessibilityReduceMotion
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}
