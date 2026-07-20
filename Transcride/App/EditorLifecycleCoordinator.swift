import Foundation

enum EditorTransitionReason: Equatable, Sendable {
    case entryChange(RelativePath?)
    case layerChange
    case vaultChange
    case workbenchTeardown
    case applicationTermination
    case externalReload
}

struct EditorDocumentIdentity: Equatable, Sendable {
    var vaultID: String
    var documentID: String
    var path: RelativePath
    var generation: UInt64

    func remapped(to path: RelativePath) -> Self {
        var copy = self
        copy.path = path
        copy.generation &+= 1
        return copy
    }
}

struct EditorRegistrationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

@MainActor
protocol EditorTransitionParticipant: AnyObject {
    var editorDocumentIdentity: EditorDocumentIdentity { get }
    func prepareForEditorTransition(_ reason: EditorTransitionReason) async -> Bool
    func rebindEditorDocument(to identity: EditorDocumentIdentity)
}

/// Retains the currently mounted editor's asynchronous snapshot boundary.
/// Selection and lifecycle callers ask this coordinator before changing the
/// native context, which keeps the WKWebView alive until its latest snapshot
/// has been acknowledged and durably handled by the workbench.
@MainActor
final class EditorLifecycleCoordinator {
    private weak var participant: (any EditorTransitionParticipant)?
    /// A failed workbench teardown is exceptional: SwiftUI may release its
    /// state owner after `onDisappear`, but the acknowledged dirty buffer must
    /// remain reachable until a later save/recovery/export succeeds.
    private var failedTeardownParticipants: [ObjectIdentifier: any EditorTransitionParticipant] = [:]
    private var registrationToken: EditorRegistrationToken?
    private var registrationGeneration: UInt64 = 0
    private var latestIntent: UInt64 = 0
    private var transitionTail: Task<Void, Never>?

    var hasActiveParticipant: Bool { participant != nil || !failedTeardownParticipants.isEmpty }
    var hasRetainedFailedTeardown: Bool { !failedTeardownParticipants.isEmpty }
    var activeEntryPath: RelativePath? {
        participant?.editorDocumentIdentity.path
            ?? failedTeardownParticipants.values.first?.editorDocumentIdentity.path
    }
    var activeDocumentIdentity: EditorDocumentIdentity? { participant?.editorDocumentIdentity }

    @discardableResult
    func register(_ participant: any EditorTransitionParticipant) -> EditorRegistrationToken {
        registrationGeneration &+= 1
        latestIntent &+= 1
        let token = EditorRegistrationToken(rawValue: UUID())
        self.participant = participant
        registrationToken = token
        return token
    }

    func unregister(_ participant: any EditorTransitionParticipant) {
        failedTeardownParticipants.removeValue(forKey: ObjectIdentifier(participant))
        guard self.participant === participant else { return }
        registrationGeneration &+= 1
        latestIntent &+= 1
        self.participant = nil
        registrationToken = nil
    }

    func prepare(for reason: EditorTransitionReason) async -> Bool {
        await enqueuePreparation(reason: reason, requiredParticipant: nil)
    }

    /// Performs a teardown barrier only for the participant that is actually
    /// disappearing. If a replacement editor has registered in the meantime,
    /// the stale teardown is already satisfied and must not prepare that new
    /// participant.
    func prepare(
        for reason: EditorTransitionReason,
        participant requiredParticipant: any EditorTransitionParticipant
    ) async -> Bool {
        await enqueuePreparation(reason: reason, requiredParticipant: requiredParticipant)
    }

    /// Atomically rebinds the mounted participant after a true same-document
    /// rename or move. The logical and vault identities must remain unchanged;
    /// only the path and participant generation advance.
    @discardableResult
    func remapActiveDocument(
        expectedOldPath: RelativePath,
        to newPath: RelativePath
    ) -> Bool {
        guard let participant,
              participant.editorDocumentIdentity.path == expectedOldPath else { return false }
        registrationGeneration &+= 1
        latestIntent &+= 1
        participant.rebindEditorDocument(
            to: participant.editorDocumentIdentity.remapped(to: newPath)
        )
        return true
    }

    private func enqueuePreparation(
        reason: EditorTransitionReason,
        requiredParticipant: (any EditorTransitionParticipant)?
    ) async -> Bool {
        latestIntent &+= 1
        let intent = latestIntent
        let predecessor = transitionTail
        let capturedParticipant = participant
        let capturedToken = registrationToken
        let capturedRegistrationGeneration = registrationGeneration
        let capturedIdentity = capturedParticipant?.editorDocumentIdentity

        let operation = Task { @MainActor [weak self] () -> Bool in
            await predecessor?.value
            guard let self else { return false }

            if let requiredParticipant {
                // Scoped teardown belongs to A even when B has already
                // registered. Never prepare B, but never declare A durable
                // without asking A either. Retain a failed A strongly so its
                // acknowledged dirty buffer survives release of the view.
                let prepared = await requiredParticipant.prepareForEditorTransition(reason)
                let key = ObjectIdentifier(requiredParticipant)
                if prepared {
                    self.failedTeardownParticipants.removeValue(forKey: key)
                } else if case .workbenchTeardown = reason {
                    self.failedTeardownParticipants[key] = requiredParticipant
                }
                return prepared
            }
            guard intent == self.latestIntent else { return false }
            guard let capturedParticipant else {
                return self.participant == nil && intent == self.latestIntent
            }
            guard self.participant === capturedParticipant,
                  self.registrationToken == capturedToken,
                  self.registrationGeneration == capturedRegistrationGeneration,
                  capturedParticipant.editorDocumentIdentity == capturedIdentity else {
                return false
            }
            if case .entryChange(let destination) = reason,
               destination == capturedIdentity?.path {
                return true
            }

            let prepared = await capturedParticipant.prepareForEditorTransition(reason)
            guard prepared else {
                if case .workbenchTeardown = reason,
                   self.participant === capturedParticipant {
                    self.failedTeardownParticipants[ObjectIdentifier(capturedParticipant)] = capturedParticipant
                }
                return false
            }
            guard
                  intent == self.latestIntent,
                  self.participant === capturedParticipant,
                  self.registrationToken == capturedToken,
                  self.registrationGeneration == capturedRegistrationGeneration,
                  capturedParticipant.editorDocumentIdentity == capturedIdentity else {
                return false
            }
            return true
        }
        transitionTail = Task { _ = await operation.value }
        return await operation.value
    }
}
