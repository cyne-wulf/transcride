import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Transcride

@Suite("Offline CodeMirror WKWebView integration", .serialized)
@MainActor
struct EditorWebKitIntegrationTests {
    @Test func layerControlRemainsDiscoverableAcrossUntouchedForkedEditingAndNarrowStates() {
        let untouchedOriginal = TranscriptLayerControlState(
            hasEditableNote: true,
            originalAvailable: true,
            isForked: false,
            layer: .original,
            isEditing: false,
            isSaving: false
        )
        #expect(!untouchedOriginal.isVisible)
        #expect(untouchedOriginal.originalSelected)
        #expect(untouchedOriginal.editedTitle == "Edited")
        #expect(untouchedOriginal.originalAccessibilityLabel == "Show Original Transcript")
        #expect(untouchedOriginal.editedAccessibilityLabel == "Show Edited Note")

        var untouchedEdited = untouchedOriginal
        untouchedEdited.layer = .edited
        #expect(untouchedEdited.editedSelected)
        #expect(!untouchedEdited.isForked)
        #expect(!untouchedEdited.isVisible)

        var forked = untouchedEdited
        forked.isForked = true
        #expect(forked.isVisible)
        #expect(forked.editedSelected)

        var editing = forked
        editing.isEditing = true
        #expect(editing.editedTitle == "Edited")
        #expect(editing.editedAccessibilityLabel == "Show Edited Note")
        #expect(!editing.editedEnabled)
        #expect(!editing.originalEnabled)

        var saving = editing
        saving.isSaving = true
        #expect(!saving.editedEnabled)
        #expect(saving.isPersistentCompactTrailingAction)

        var unavailable = untouchedOriginal
        unavailable.hasEditableNote = false
        #expect(!unavailable.isVisible)
        #expect(!unavailable.isPersistentCompactTrailingAction)

        let idleAction = TranscriptEditSaveActionState(
            hasEditableNote: true,
            isForked: false,
            viewedLayer: .original,
            isEditing: false,
            isSaving: false,
            isTransitioning: false,
            isRecoveryBlocked: false
        )
        #expect(idleAction.isVisible)
        #expect(idleAction.title == "Edit")
        #expect(idleAction.accessibilityLabel == "Edit Note")
        #expect(idleAction.isEnabled)

        var forkedOriginalAction = idleAction
        forkedOriginalAction.isForked = true
        #expect(!forkedOriginalAction.isVisible)

        var forkedEditedAction = forkedOriginalAction
        forkedEditedAction.viewedLayer = .edited
        #expect(forkedEditedAction.isVisible)
        #expect(forkedEditedAction.title == "Edit")

        var saveAction = forkedOriginalAction
        saveAction.isEditing = true
        #expect(saveAction.title == "Save")
        #expect(saveAction.accessibilityLabel == "Save Edited Note")
        #expect(saveAction.isEnabled)

        saveAction.isSaving = true
        #expect(saveAction.title == "Saving…")
        #expect(saveAction.accessibilityLabel == "Saving Edited Note")
        #expect(saveAction.accessibilityValue == "Busy")
        #expect(!saveAction.isEnabled)

        var narrowAction = idleAction
        narrowAction.isTransitioning = true
        #expect(narrowAction.isVisible)
        #expect(!narrowAction.isEnabled)

        var recoveringLayer = forked
        recoveringLayer.isRecoveryBlocked = true
        #expect(!recoveringLayer.originalEnabled)
        #expect(!recoveringLayer.editedEnabled)

        var loadingAction = idleAction
        loadingAction.isEditorReady = false
        #expect(loadingAction.isVisible)
        #expect(!loadingAction.isEnabled)
    }

    @Test func compactToolbarGeometryStaysInBoundsAcrossNarrowRuntimeStates() async throws {
        let baseLayer = TranscriptLayerControlState(
            hasEditableNote: true,
            originalAvailable: true,
            isForked: true,
            layer: .original,
            isEditing: false,
            isSaving: false
        )
        let baseAction = TranscriptEditSaveActionState(
            hasEditableNote: true,
            isForked: true,
            viewedLayer: .original,
            isEditing: false,
            isSaving: false,
            isTransitioning: false,
            isRecoveryBlocked: false
        )
        var editedAction = baseAction
        editedAction.viewedLayer = .edited
        var editedLayer = baseLayer
        editedLayer.layer = .edited
        var editingLayer = editedLayer
        editingLayer.isEditing = true
        var editingAction = editedAction
        editingAction.isEditing = true
        var savingLayer = editingLayer
        savingLayer.isSaving = true
        var savingAction = editingAction
        savingAction.isSaving = true
        var recoveryLayer = editedLayer
        recoveryLayer.isRecoveryBlocked = true
        var recoveryAction = editedAction
        recoveryAction.isRecoveryBlocked = true

        let states = [
            (baseLayer, baseAction),
            (editedLayer, editedAction),
            (editingLayer, editingAction),
            (savingLayer, savingAction),
            (recoveryLayer, recoveryAction),
        ]
        for width in [CGFloat(320), 280] {
            for (layerState, actionState) in states {
                let recorder = ToolbarFrameRecorder()
                let host = NSHostingView(rootView: TranscriptToolbarGeometryFixture(
                    width: width,
                    layerState: layerState,
                    actionState: actionState,
                    onFramesChange: { recorder.frames = $0 }
                ))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 44)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let frames = recorder.frames

                #expect((frames["transcript-more-actions"]?.width ?? 0) > 0)
                #expect((frames["transcript-layer-control"]?.width ?? 0) > 0)
                #expect(((frames["transcript-edit-save-action"]?.width ?? 0) > 0)
                    == actionState.isVisible)

                let orderedFrames = frames.values.filter { $0.width > 0 && $0.height > 0 }
                    .sorted { $0.minX < $1.minX }
                for frame in orderedFrames {
                    #expect(CGRect(x: 0, y: 0, width: width, height: 44)
                        .insetBy(dx: -1, dy: -1).contains(frame))
                    #expect(frame.width >= 20)
                    #expect(frame.height >= 20)
                }
                for pair in zip(orderedFrames, orderedFrames.dropFirst()) {
                    #expect(pair.0.maxX <= pair.1.minX + 0.5)
                }
                withExtendedLifetime(recorder) {}
            }
        }

        var hiddenLayer = baseLayer
        hiddenLayer.isForked = false
        let hiddenRecorder = ToolbarFrameRecorder()
        let hiddenHost = NSHostingView(rootView: TranscriptToolbarGeometryFixture(
            width: 280,
            layerState: hiddenLayer,
            actionState: TranscriptEditSaveActionState(
                hasEditableNote: true,
                viewedLayer: .original,
                isEditing: false,
                isSaving: false,
                isTransitioning: false,
                isRecoveryBlocked: false
            ),
            onFramesChange: { hiddenRecorder.frames = $0 }
        ))
        hiddenHost.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
        hiddenHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect((hiddenRecorder.frames["transcript-layer-control"]?.width ?? 0) == 0)
    }

    @Test func readinessUTF16PatchSnapshotAndProcessRecoveryRoundTrip() async throws {
        let controller = CodeMirrorEditorController()
        var readyCount = 0
        controller.onReady = { if $0 { readyCount += 1 } }
        controller.loadIfNeeded()
        #expect(await eventually { readyCount == 1 })

        #expect(await controller.replaceDocumentAndWait(
            "😀 word",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 3, head: 7)]
        ))
        #expect(await eventually {
            await controller.snapshot(reason: "initial")?.text == "😀 word"
        })

        controller.execute("bold")
        #expect(await eventually { controller.acknowledgedBody == "😀 **word**" })
        let snapshot = await controller.snapshot(reason: "round-trip")
        #expect(snapshot?.text == "😀 **word**")
        #expect(snapshot?.mode == .editedEditing)

        controller.webViewWebContentProcessDidTerminate(controller.webView)
        #expect(await eventually { readyCount == 2 })
        #expect(await eventually {
            await controller.snapshot(reason: "process-recovery")?.text == "😀 **word**"
        })
    }

    @Test func processRecoveryRetainsUnsnappedSelectionAndScrollAtEmojiBoundaries() async throws {
        let controller = CodeMirrorEditorController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.webView
        window.orderFront(nil)
        defer { window.close() }
        var readyCount = 0
        controller.onReady = { if $0 { readyCount += 1 } }
        controller.loadIfNeeded()
        #expect(await eventually { readyCount == 1 })
        let text = "😀 word\r\n" + (0..<800).map { "line \($0)" }.joined(separator: "\n")
        #expect(await controller.replaceDocumentAndWait(
            text,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 3, head: 7)]
        ))

        _ = try await controller.evaluateJavaScriptForTesting("""
            const scroller = document.querySelector('.cm-scroller');
            if (!scroller) throw new Error('Missing editor scroller');
            scroller.scrollTop = Math.floor(scroller.scrollHeight / 2);
            scroller.dispatchEvent(new Event('scroll'));
            return scroller.scrollTop;
        """)
        // No native snapshot is requested here: the debounced view-state
        // acknowledgement must be sufficient for an abrupt process loss.
        #expect(await eventually {
            controller.latestSnapshotForTesting?.selection
                == [EditorSelectionState(anchor: 3, head: 7)]
                && (controller.latestSnapshotForTesting?.scrollTop ?? 0) > 0
        })
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        #expect(await eventually { readyCount == 2 })
        #expect(await eventually {
            guard let recovered = await controller.snapshot(reason: "unsnapped-view-recovery") else {
                return false
            }
            return recovered.text == text
                && recovered.selection == [EditorSelectionState(anchor: 3, head: 7)]
                && recovered.scrollTop > 0
        })
    }

    @Test func patchLengthMismatchResynchronizesSnapshotAndAcceptsTheNextEdit() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        #expect(await controller.replaceDocumentAndWait(
            "word",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        #expect(await eventually { await controller.snapshot(reason: "baseline")?.text == "word" })

        controller.forceAcknowledgedBodyForTesting("x")
        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { controller.acknowledgedBody == "**word**" })

        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { controller.acknowledgedBody == "word" })
        #expect(await controller.snapshot(reason: "after-resync")?.text == "word")
    }

    @Test func exactCRLFAndMixedSeparatorsSurviveNoOpSnapshotsAndEdits() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        let mixed = "one\r\ntwo\rthree\nfour"
        #expect(await controller.replaceDocumentAndWait(
            mixed,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 5, head: 8)]
        ))
        #expect(await controller.snapshot(reason: "mixed-no-op")?.text == mixed)

        #expect(await controller.executeAndWait("bold"))
        let expected = "one\r\n**two**\rthree\nfour"
        #expect(await eventually { controller.acknowledgedBody == expected })
        #expect(await controller.snapshot(reason: "mixed-edit")?.text == expected)

        #expect(await controller.replaceDocumentAndWait(mixed, mode: .original, resetHistory: true))
        #expect(await controller.snapshot(reason: "mixed-original-no-op")?.text == mixed)
    }

    @Test func liveAppearancePreservesExactMixedTextSelectionAndHistoryInEveryEditorState() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        let mixed = "one\r\ntwo\rthree\nfour"
        var dark = false
        for mode in [EditorMode.original, .editedView, .editedEditing] {
            #expect(await controller.replaceDocumentAndWait(
                mixed,
                mode: mode,
                resetHistory: true,
                selection: [EditorSelectionState(anchor: 5, head: 8)]
            ))
            let before = try #require(await controller.snapshot(reason: "appearance-\(mode)-before"))
            dark.toggle()
            let expectedScheme = dark ? "dark" : "light"
            controller.updateAppearance(
                colorScheme: expectedScheme,
                increasedContrast: mode == .editedView,
                reduceMotion: mode == .editedEditing
            )
            #expect(await eventually {
                await appearanceFacts(controller)["scheme"] as? String == expectedScheme
            })
            let after = try #require(await controller.snapshot(reason: "appearance-\(mode)-after"))
            #expect(after.text == mixed)
            #expect(after.text == before.text)
            #expect(after.selection == before.selection)
            #expect(after.mode == mode)
        }

        #expect(await controller.replaceDocumentAndWait(
            mixed,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 5, head: 8)]
        ))
        #expect(await controller.executeAndWait("bold"))
        let edited = "one\r\n**two**\rthree\nfour"
        #expect(await eventually { controller.acknowledgedBody == edited })
        let historyBefore = try #require(await controller.snapshot(reason: "appearance-history-before"))
        controller.updateAppearance(
            colorScheme: "dark",
            increasedContrast: true,
            reduceMotion: true
        )
        #expect(await eventually { await appearanceFacts(controller)["scheme"] as? String == "dark" })
        let historyAfter = try #require(await controller.snapshot(reason: "appearance-history-after"))
        #expect(historyAfter.text == historyBefore.text)
        #expect(historyAfter.selection == historyBefore.selection)
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { controller.acknowledgedBody == mixed })
        #expect(await controller.executeAndWait("redo"))
        #expect(await eventually { controller.acknowledgedBody == edited })

        #expect(await controller.replaceDocumentAndWait(
            mixed,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 5, head: 8)]
        ))
        #expect(await controller.setFrozenAndWait(true, reason: "Appearance preservation"))
        let frozenBefore = try #require(await controller.snapshot(reason: "appearance-frozen-before"))
        controller.updateAppearance(
            colorScheme: "light",
            increasedContrast: false,
            reduceMotion: false
        )
        #expect(await eventually { await appearanceFacts(controller)["scheme"] as? String == "light" })
        let frozenAfter = try #require(await controller.snapshot(reason: "appearance-frozen-after"))
        #expect(frozenAfter.text == mixed)
        #expect(frozenAfter.text == frozenBefore.text)
        #expect(frozenAfter.selection == frozenBefore.selection)
        #expect(await appearanceFacts(controller)["frozen"] as? Bool == true)
        #expect(await controller.setFrozenAndWait(false))
    }

    @Test func mountedWorkbenchEditSessionForksOnlyForRealWebPatchesAndClearsAfterUndo() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        var untouched = FrontmatterDocument(fields: [], body: "word")
        var untouchedSession = TranscriptEditSessionCoordinator(
            initialBody: untouched.body,
            startedForked: false
        )
        let noChangeSave = untouchedSession.completion(for: untouched)
        #expect(!noChangeSave.hasActualChange)
        #expect(noChangeSave.restoresUnforkedState)
        #expect(!noChangeSave.isForkedAfterSave)
        #expect(!untouched.handEdited)

        controller.onBodyChange = { body in
            _ = untouchedSession.apply(body, to: &untouched)
        }
        #expect(await controller.replaceDocumentAndWait(
            untouched.body,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { untouched.body == "**word**" && untouched.handEdited })
        let firstPatchSave = untouchedSession.completion(for: untouched)
        #expect(firstPatchSave.hasActualChange)
        #expect(firstPatchSave.isForkedAfterSave)

        var reverted = FrontmatterDocument(fields: [], body: "word")
        var revertedSession = TranscriptEditSessionCoordinator(
            initialBody: reverted.body,
            startedForked: false
        )
        controller.onBodyChange = { body in
            _ = revertedSession.apply(body, to: &reverted)
        }
        #expect(await controller.replaceDocumentAndWait(
            reverted.body,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { reverted.body == "**word**" && reverted.handEdited })
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { reverted.body == "word" && !reverted.handEdited })
        let revertedSave = revertedSession.completion(for: reverted)
        #expect(!revertedSave.hasActualChange)
        #expect(revertedSave.restoresUnforkedState)
        #expect(!revertedSave.isForkedAfterSave)
    }

    @Test func disjointExternalCRLFHunkRebasesLocalUndoAndNativeMirror() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        let original = "local\r\nexternal\r\n"
        #expect(await controller.replaceDocumentAndWait(
            original,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 5)]
        ))
        #expect(await controller.executeAndWait("bold"))
        let local = "**local**\r\nexternal\r\n"
        #expect(await eventually { controller.acknowledgedBody == local })

        let merged = "**local**\r\noutside\r\n"
        let patches = EditorBodyMerger.utf16Patches(from: local, to: merged)
        #expect(await controller.applyExternalChangesAndWait(
            patches,
            resultingBody: merged,
            mode: .editedEditing
        ))
        #expect(controller.acknowledgedBody == merged)
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { controller.acknowledgedBody == "local\r\noutside\r\n" })
        #expect(await controller.snapshot(reason: "external-crlf-undo")?.text == "local\r\noutside\r\n")
        #expect(await controller.executeAndWait("redo"))
        #expect(await eventually { controller.acknowledgedBody == merged })
    }

    @Test func webTransportFailureFreezesThenUsesANativeIssuedRecoveryGeneration() async throws {
        let controller = CodeMirrorEditorController()
        var readyCount = 0
        var recoveryCount = 0
        controller.onReady = { if $0 { readyCount += 1 } }
        controller.onWebProcessRecovery = { recoveryCount += 1 }
        controller.loadIfNeeded()
        #expect(await eventually { readyCount == 1 })

        #expect(await controller.replaceDocumentAndWait(
            "word",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        #expect(await eventually { await controller.snapshot(reason: "transport-baseline")?.text == "word" })

        controller.failNextPatchTransportForTesting()
        controller.execute("bold")
        #expect(await eventually { recoveryCount == 1 && readyCount == 2 })
        #expect(await controller.snapshot(reason: "transport-recovered")?.text == "word")

        controller.failNextAcceptedPatchReplyForTesting()
        controller.execute("bold")
        #expect(await eventually {
            recoveryCount == 2 && readyCount == 3
                && controller.acknowledgedBody == "**word**"
        })
        #expect(await controller.snapshot(reason: "accepted-reply-lost-recovered")?.text
            == "**word**")
        #expect(await controller.replaceDocumentAndWait(
            "next",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        controller.execute("italic")
        #expect(await eventually { controller.acknowledgedBody == "*next*" })
    }

    @Test func staleTransportFailureCannotCancelAFreshPendingLoad() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        var recoveryCount = 0
        controller.onReady = { ready = $0 }
        controller.onWebProcessRecovery = { recoveryCount += 1 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })
        controller.forcePendingLoadWithoutAcceptedSessionForTesting()

        #expect(throws: (any Error).self) {
            try controller.receive([
                "protocolVersion": 1,
                "sessionID": "obsolete-session",
                "requestID": UUID().uuidString,
                "sequence": 99,
                "method": "action",
                "payload": [
                    "kind": "transportFailure",
                    "message": "delayed obsolete page",
                ],
            ])
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recoveryCount == 0)
    }

    @Test func failedFreezeRollsBackAndFrozenModeRejectsCommandsAndTyping() async throws {
        let controller = CodeMirrorEditorController()
        var readyCount = 0
        controller.onReady = { if $0 { readyCount += 1 } }
        controller.loadIfNeeded()
        #expect(await eventually { readyCount == 1 })
        #expect(await controller.replaceDocumentAndWait(
            "word",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))

        controller.failNextNativeSendForTesting(method: "setFrozen")
        #expect(!(await controller.setFrozenAndWait(true, reason: "Injected failure")))
        #expect(!controller.isFrozenForTesting)
        #expect(await eventually { readyCount == 2 })
        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { controller.acknowledgedBody == "**word**" })

        #expect(await controller.setFrozenAndWait(true, reason: "Conflict"))
        #expect(controller.isFrozenForTesting)
        #expect(!(await controller.executeAndWait("italic")))
        _ = try await controller.evaluateJavaScriptForTesting("""
            const content = document.querySelector('.cm-content');
            content?.focus();
            content?.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', bubbles: true}));
            content?.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
            return true;
        """)
        #expect(await controller.snapshot(reason: "frozen-immutable")?.text == "**word**")
        controller.failNextNativeSendForTesting(method: "setFrozen")
        #expect(await controller.setFrozenAndWait(false))
        #expect(await eventually { readyCount == 3 })
        #expect(!controller.isFrozenForTesting)
        #expect(try await controller.evaluateJavaScriptForTesting("""
            const root = document.querySelector('.cm-editor');
            const content = document.querySelector('.cm-content');
            return !root?.classList.contains('tc-frozen') && content?.contentEditable === 'true';
        """) as? Bool == true)
        #expect(await controller.replaceDocumentAndWait(
            "**word**",
            mode: .editedEditing,
            resetHistory: false,
            selection: [EditorSelectionState(anchor: 2, head: 6)]
        ))
        #expect(await controller.executeAndWait("italic"))
        #expect(await eventually { controller.acknowledgedBody != "**word**" })
        #expect(await controller.snapshot(reason: "unfreeze-editable")?.text == controller.acknowledgedBody)
    }

    @Test func configurationIsEphemeralAndExternalNavigationIsDenied() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        #expect(controller.webView.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        controller.loadIfNeeded()
        #expect(await eventually { ready })
        let localURL = controller.webView.url
        controller.webView.load(URLRequest(url: try #require(URL(string: "https://example.com"))))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(controller.webView.url == localURL)

        let security = try #require(try await controller.evaluateJavaScriptForTesting("""
            window.__transcrideInlineScriptRan = false;
            const script = document.createElement('script');
            script.textContent = 'window.__transcrideInlineScriptRan = true';
            document.body.append(script);
            const popup = window.open('https://example.com', '_blank');
            const download = document.createElement('a');
            download.href = 'data:text/plain,blocked'; download.download = 'blocked.txt';
            document.body.append(download); download.click();
            let permission = 'unavailable';
            if (navigator.mediaDevices?.getUserMedia) {
              permission = await Promise.race([
                navigator.mediaDevices.getUserMedia({audio: true}).then(stream => {
                  stream.getTracks().forEach(track => track.stop()); return 'granted';
                }).catch(() => 'denied'),
                new Promise(resolve => setTimeout(() => resolve('blocked'), 250))
              ]);
            }
            await new Promise(resolve => setTimeout(resolve, 60));
            return {
              inlineBlocked: window.__transcrideInlineScriptRan !== true,
              popupBlocked: popup === null,
              permission
            };
        """) as? [String: Any])
        #expect(security["inlineBlocked"] as? Bool == true)
        #expect(security["popupBlocked"] as? Bool == true)
        #expect(["denied", "unavailable", "blocked"].contains(
            security["permission"] as? String ?? ""
        ))
        #expect(await eventually { controller.deniedDownloadCountForTesting == 1 })
        #expect(controller.webView.url == localURL)
    }

    @Test func bundledEditorFirstFrameAndLiveAppearanceRemainAccessibleWithoutGuttersOrStateLoss() async throws {
        let controller = CodeMirrorEditorController()
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let testWindow = NSWindow(
            contentRect: controller.webView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = controller.webView
        testWindow.makeKeyAndOrderFront(nil)
        defer {
            testWindow.orderOut(nil)
            testWindow.close()
        }
        controller.updateAppearance(
            colorScheme: "dark",
            increasedContrast: false,
            reduceMotion: false
        )
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        let representative = "# Heading\n\nFind **text** [[Note]] #tag\n\n> quote\n\n- [ ] task\n\n`code` ==mark== %%comment%%"
        #expect(await controller.replaceDocumentAndWait(
            representative,
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 13, head: 17)]
        ))
        #expect(await controller.executeAndWait("openFind"))
        #expect(await setSearch(controller, query: "text"))
        #expect(await eventually { await appearanceFacts(controller)["scheme"] as? String == "dark" })
        testWindow.makeFirstResponder(controller.webView)
        _ = try await controller.evaluateJavaScriptForTesting(
            "document.querySelector('.cm-content')?.focus(); "
                + "document.querySelector('.cm-editor')?.classList.add('cm-focused'); return true"
        )

        let dark = await appearanceFacts(controller)
        #expect(dark["rootTransparent"] as? Bool == true)
        #expect(dark["gutterCount"] as? Int == 0)
        #expect(dark["gutterWidth"] as? Double == 0)
        #expect(dark["contentPadding"] as? Double == 28)
        #expect((27.0...31.0).contains(dark["lineInset"] as? Double ?? -1))
        #expect(dark["textContrastPass"] as? Bool == true)
        #expect(dark["selectedSearchContrastPass"] as? Bool == true)
        #expect(dark["borderContrastPass"] as? Bool == true)
        #expect(dark["focusOutlineWidth"] as? Double == 1)
        #expect(dark["searchVisible"] as? Bool == true)
        #expect(dark["replaceVisible"] as? Bool == true)
        #expect(dark["semanticDecorationCount"] as? Int ?? 0 >= 8)

        _ = try await controller.evaluateJavaScriptForTesting(
            "document.documentElement.style.backgroundColor = '#1a1d21'; return true"
        )
        let darkStats = try snapshotStats(await snapshot(controller.webView))
        let before = try #require(await controller.snapshot(reason: "dark-before-live-change"))

        controller.updateAppearance(
            colorScheme: "light",
            increasedContrast: true,
            reduceMotion: true
        )
        #expect(await eventually { await appearanceFacts(controller)["scheme"] as? String == "light" })
        testWindow.makeFirstResponder(controller.webView)
        _ = try await controller.evaluateJavaScriptForTesting(
            "document.querySelector('.cm-content')?.focus(); "
                + "document.querySelector('.cm-editor')?.classList.add('cm-focused'); return true"
        )
        let light = await appearanceFacts(controller)
        #expect(light["textContrastPass"] as? Bool == true)
        #expect(light["selectedSearchContrastPass"] as? Bool == true)
        #expect(light["borderContrastPass"] as? Bool == true)
        #expect(light["focusOutlineWidth"] as? Double == 2)
        #expect(light["scrollBehavior"] as? String == "auto")
        let after = try #require(await controller.snapshot(reason: "light-after-live-change"))
        #expect(after.text == before.text)
        #expect(after.mode == before.mode)
        #expect(after.selection == before.selection)

        _ = try await controller.evaluateJavaScriptForTesting(
            "document.documentElement.style.backgroundColor = '#ffffff'; return true"
        )
        let lightStats = try snapshotStats(await snapshot(controller.webView))
        #expect(lightStats.averageLuminance > darkStats.averageLuminance + 0.25)
        #expect(lightStats.luminanceRange > 0.20)
        #expect(darkStats.luminanceRange > 0.20)

        for mode in [EditorMode.original, .editedView, .editedEditing] {
            #expect(await controller.replaceDocumentAndWait(representative, mode: mode, resetHistory: false))
            #expect(await eventually { await appearanceFacts(controller)["scheme"] as? String == "light" })
            if mode != .editedEditing {
                #expect(await appearanceFacts(controller)["replaceVisible"] as? Bool == false)
            }
        }
        #expect(await controller.setFrozenAndWait(true, reason: "Appearance test"))
        #expect(await appearanceFacts(controller)["frozen"] as? Bool == true)
        #expect(await appearanceFacts(controller)["gutterCount"] as? Int == 0)
        #expect(await controller.setFrozenAndWait(false))

        let longDocument = (0..<4_000).map { "Line \($0) with enough text to exercise viewport rendering." }
            .joined(separator: "\n")
        #expect(await controller.replaceDocumentAndWait(
            longDocument,
            mode: .original,
            resetHistory: true
        ))
        _ = try await controller.evaluateJavaScriptForTesting(
            "const scroller = document.querySelector('.cm-scroller'); "
                + "if (scroller) scroller.scrollTop = Math.floor(scroller.scrollHeight / 2); return true"
        )
        try? await Task.sleep(for: .milliseconds(50))
        let layout = try #require(try await controller.evaluateJavaScriptForTesting("""
            const elements = [
              document.documentElement,
              document.body,
              document.querySelector('#editor'),
              document.querySelector('.cm-editor'),
              document.querySelector('.cm-scroller')
            ];
            const rects = elements.map(element => element?.getBoundingClientRect());
            const scroller = elements[4];
            const content = document.querySelector('.cm-content');
            const firstLine = content?.querySelector('.cm-line');
            return {
              viewportHeight: window.innerHeight,
              viewportWidth: window.innerWidth,
              heights: rects.map(rect => rect?.height ?? -1),
              widths: rects.map(rect => rect?.width ?? -1),
              lefts: rects.map(rect => rect?.left ?? -1),
              tops: rects.map(rect => rect?.top ?? -1),
              outerScrollY: window.scrollY,
              pageScrollHeight: document.scrollingElement?.scrollHeight ?? -1,
              scrollerClientHeight: scroller?.clientHeight ?? -1,
              scrollerScrollHeight: scroller?.scrollHeight ?? -1,
              scrollerScrollTop: scroller?.scrollTop ?? -1,
              visibleLineCount: document.querySelectorAll('.cm-line').length,
              contentPaddingLeft: parseFloat(getComputedStyle(content).paddingLeft) || 0,
              firstLineInset: firstLine && content
                ? firstLine.getBoundingClientRect().left - content.getBoundingClientRect().left
                : -1
            };
        """) as? [String: Any])
        let viewportHeight = try #require(layout["viewportHeight"] as? Double)
        let viewportWidth = try #require(layout["viewportWidth"] as? Double)
        let heights = try #require(layout["heights"] as? [Double])
        let widths = try #require(layout["widths"] as? [Double])
        let lefts = try #require(layout["lefts"] as? [Double])
        let tops = try #require(layout["tops"] as? [Double])
        #expect(abs(viewportHeight - 520) < 1)
        #expect(heights.allSatisfy { abs($0 - viewportHeight) < 1 })
        #expect(widths.allSatisfy { abs($0 - viewportWidth) < 1 })
        #expect(lefts.allSatisfy { abs($0) < 1 })
        #expect(tops.allSatisfy { abs($0) < 1 })
        #expect(layout["outerScrollY"] as? Double == 0)
        #expect(layout["pageScrollHeight"] as? Double == viewportHeight)
        #expect((layout["scrollerScrollHeight"] as? Double ?? 0)
            > (layout["scrollerClientHeight"] as? Double ?? .infinity))
        #expect((layout["scrollerScrollTop"] as? Double ?? 0) > 0)
        #expect((1...160).contains(layout["visibleLineCount"] as? Int ?? 0))
        #expect(layout["contentPaddingLeft"] as? Double == 28)
        #expect((27.0...31.0).contains(layout["firstLineInset"] as? Double ?? -1))
    }

    @Test func findReplaceTaskHistoryFocusAndPlaybackDecorationsUseOneRealHost() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        var userScrolled = false
        var ownsInput = false
        controller.onReady = { ready = $0 }
        controller.onUserScroll = { userScrolled = true }
        controller.onFocusOwnership = { ownsInput = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        for mode in [EditorMode.original, .editedView, .editedEditing] {
            #expect(await controller.replaceDocumentAndWait("one one", mode: mode, resetHistory: true))
            #expect(await controller.executeAndWait("openFind"))
            #expect(try await controller.evaluateJavaScriptForTesting(
                "return document.querySelector('.cm-search') !== null"
            ) as? Bool == true)
        }

        #expect(await controller.replaceDocumentAndWait("one one", mode: .original, resetHistory: true))
        #expect(await controller.executeAndWait("openFind"))
        #expect(await setSearch(controller, query: "one"))
        #expect(await eventually {
            (try? await controller.evaluateJavaScriptForTesting(
                "return document.querySelector('.tc-search-count')?.textContent === '1 of 2'"
            ) as? Bool) == true
        })
        #expect(await controller.executeAndWait("findNext"))
        #expect(await controller.snapshot(reason: "find-first")?.selection.first == .init(anchor: 0, head: 3))
        #expect(await controller.executeAndWait("findNext"))
        #expect(await controller.snapshot(reason: "find-next")?.selection.first == .init(anchor: 4, head: 7))
        #expect(!(await controller.executeAndWait("replaceAll")))
        #expect(await controller.snapshot(reason: "read-only-replace")?.text == "one one")

        #expect(await controller.replaceDocumentAndWait("one one", mode: .editedEditing, resetHistory: true))
        #expect(await controller.executeAndWait("openFind"))
        #expect(await setSearch(controller, query: "one", replacement: "X"))
        #expect(await controller.executeAndWait("replaceAll"))
        #expect(await eventually { controller.acknowledgedBody == "X X" })
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { controller.acknowledgedBody == "one one" })

        #expect(await controller.replaceDocumentAndWait("- [ ] task", mode: .editedView, resetHistory: true))
        _ = try await controller.evaluateJavaScriptForTesting(
            "document.querySelector('.tc-task-control')?.click(); return true"
        )
        #expect(await eventually { controller.acknowledgedBody == "- [x] task" })
        #expect(await eventually { ownsInput })
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { controller.acknowledgedBody == "- [ ] task" })

        #expect(await controller.replaceDocumentAndWait("- [ ] immutable", mode: .original, resetHistory: true))
        _ = try await controller.evaluateJavaScriptForTesting(
            "document.querySelector('.tc-task-control')?.click(); return true"
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.acknowledgedBody == "- [ ] immutable")

        controller.setDecorations(playback: 0..<3, search: [4..<7], followPlayback: true)
        #expect(await eventually {
            (try? await controller.evaluateJavaScriptForTesting(
                "return !!document.querySelector('.tc-native-playback') && !!document.querySelector('.tc-native-search')"
            ) as? Bool) == true
        })
        _ = try await controller.evaluateJavaScriptForTesting(
            "document.querySelector('.cm-scroller')?.dispatchEvent(new WheelEvent('wheel', {deltaY: 20, bubbles: true})); return true"
        )
        #expect(await eventually { userScrolled })
    }

    @Test func rapidOriginalEditedOriginalDeliveryCannotOvertakeOrCreateEdits() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        var bodyChanges = 0
        controller.onReady = { ready = $0 }
        controller.onBodyChange = { _ in bodyChanges += 1 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        #expect(await controller.replaceDocumentAndWait(
            "word",
            mode: .editedEditing,
            resetHistory: true,
            selection: [EditorSelectionState(anchor: 0, head: 4)]
        ))
        #expect(await controller.executeAndWait("bold"))
        #expect(await eventually { controller.acknowledgedBody == "**word**" })
        let changesAfterLocalEdit = bodyChanges

        controller.replaceDocument("engine original", mode: .original, resetHistory: false)
        controller.replaceDocument("**word**", mode: .editedView, resetHistory: false)
        controller.replaceDocument("engine original", mode: .original, resetHistory: false)
        #expect(await eventually {
            await controller.snapshot(reason: "rapid-toggle")?.text == "engine original"
        })
        #expect(controller.mode == .original)
        #expect(bodyChanges <= changesAfterLocalEdit + 1)

        #expect(await controller.replaceDocumentAndWait(
            "**word**",
            mode: .editedEditing,
            resetHistory: false
        ))
        #expect(await controller.executeAndWait("undo"))
        #expect(await eventually { controller.acknowledgedBody == "word" })
    }

    @Test func longManyLinkPlaybackTicksCoalesceWithoutResendingStableKnowledge() async throws {
        let controller = CodeMirrorEditorController()
        var ready = false
        controller.onReady = { ready = $0 }
        controller.loadIfNeeded()
        #expect(await eventually { ready })

        var body = ""
        var unresolved: [Range<Int>] = []
        for index in 0..<1_000 {
            let link = "[[Missing \(index)]]"
            let start = body.utf16.count
            body += link + " "
            unresolved.append(start..<(start + link.utf16.count))
        }
        body += String(repeating: "word ", count: 10_000)
        #expect(await controller.replaceDocumentAndWait(
            body,
            mode: .original,
            resetHistory: true
        ))
        controller.setLinkDecorations(unresolved: unresolved, ambiguous: [])
        controller.setDecorations(playback: nil, search: [], followPlayback: false)
        #expect(await eventually { controller.stableDecorationSendCountForTesting > 0 })
        try? await Task.sleep(for: .milliseconds(50))
        let stableSends = controller.stableDecorationSendCountForTesting
        let playbackSends = controller.playbackDecorationSendCountForTesting

        let playbackBase = body.utf16.count - 50_000
        for tick in 0..<120 {
            let from = playbackBase + (tick % 500)
            controller.setDecorations(
                playback: from..<(from + 1),
                search: [],
                followPlayback: tick == 119 || tick.isMultiple(of: 2)
            )
        }
        #expect(await eventually {
            controller.playbackDecorationSendCountForTesting > playbackSends
        })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.stableDecorationSendCountForTesting == stableSends)
        #expect(controller.playbackDecorationSendCountForTesting - playbackSends < 12)
        #expect(await eventually {
            (try? await controller.evaluateJavaScriptForTesting(
                "return !!document.querySelector('.tc-native-playback')"
            ) as? Bool) == true
        })
    }

    @Test func playbackProjectionAdvancesOriginalMapsEditedPrefixAndSuspendsFollow() {
        let original = TranscriptOriginal(
            engine: .init(engine: "test", model: "test", options: [:], created: "", appVersion: ""),
            segments: [
                .init(start: 0, end: 2, speaker: nil, words: [
                    .init(text: "alpha", start: 0, end: 0.8),
                    .init(text: "beta", start: 1, end: 1.8),
                ])
            ]
        )
        let map = TranscriptWordMap(transcript: original)
        let edited = EditedTranscriptPlaybackMap(original: map, editedBody: map.renderedText + " changed")
        let first = CodeMirrorPlaybackProjection.make(
            layer: .original, wordMap: map, editedMap: edited,
            entryHasAudio: true, playerHasAudio: true, time: 0.2, isPlaying: true,
            knownTranscriptDuration: nil, navigationRange: 20..<22, followingPaused: false
        )
        let second = CodeMirrorPlaybackProjection.make(
            layer: .original, wordMap: map, editedMap: edited,
            entryHasAudio: true, playerHasAudio: true, time: 1.2, isPlaying: true,
            knownTranscriptDuration: nil, navigationRange: 20..<22, followingPaused: false
        )
        #expect(first.playback != nil)
        #expect(second.playback != nil)
        #expect(first.playback != second.playback)
        #expect(second.navigation == [20..<22])
        #expect(second.shouldFollow)

        let editedProjection = CodeMirrorPlaybackProjection.make(
            layer: .edited, wordMap: map, editedMap: edited,
            entryHasAudio: true, playerHasAudio: true, time: 0.2, isPlaying: true,
            knownTranscriptDuration: nil, navigationRange: nil, followingPaused: true
        )
        #expect(editedProjection.playback == edited.range(forWordAt: 0))
        #expect(!editedProjection.shouldFollow)

        let cleared = CodeMirrorPlaybackProjection.make(
            layer: .original, wordMap: map, editedMap: edited,
            entryHasAudio: true, playerHasAudio: true, time: 3, isPlaying: true,
            knownTranscriptDuration: 2, navigationRange: nil, followingPaused: false
        )
        #expect(cleared.playback == nil)
    }

    private func setSearch(
        _ controller: CodeMirrorEditorController,
        query: String,
        replacement: String? = nil
    ) async -> Bool {
        let replacementScript = replacement.map {
            "const replace = document.querySelector('.cm-search input[name=replace]');" +
            "if (!replace) return false; replace.value = '\($0)';" +
            "replace.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true, key: 'e'}));"
        } ?? ""
        return (try? await controller.evaluateJavaScriptForTesting("""
            const search = document.querySelector('.cm-search input[name=search]');
            if (!search) return false;
            search.value = '\(query)'; search.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true, key: 'e'}));
            \(replacementScript)
            return !!document.querySelector('.cm-search [name=case]') &&
              !!document.querySelector('.cm-search [name=re]') &&
              !!document.querySelector('.cm-search [name=word]');
        """) as? Bool) == true
    }

    private func appearanceFacts(_ controller: CodeMirrorEditorController) async -> [String: Any] {
        (try? await controller.evaluateJavaScriptForTesting("""
            const root = document.querySelector('.cm-editor');
            const content = document.querySelector('.cm-content');
            const panel = document.querySelector('.cm-search');
            if (!root || !content) return {};
            const style = getComputedStyle(root), contentStyle = getComputedStyle(content);
            const parse = value => {
              const text = value.trim();
              if (text.startsWith('#')) {
                const hex = text.slice(1); return [0, 2, 4].map(i => parseInt(hex.slice(i, i + 2), 16));
              }
              return (text.match(/[\\d.]+/g) || []).slice(0, 3).map(Number);
            };
            const luminance = value => {
              const rgb = parse(value).map(component => component / 255)
                .map(component => component <= .04045 ? component / 12.92 : Math.pow((component + .055) / 1.055, 2.4));
              return .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2];
            };
            const contrast = (left, right) => {
              const a = luminance(left), b = luminance(right);
              return (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
            };
            const primary = style.getPropertyValue('--tc-primary');
            const selected = style.getPropertyValue('--tc-search-selected');
            const border = style.getPropertyValue('--tc-border');
            const panelColor = style.getPropertyValue('--tc-panel');
            const page = style.colorScheme === 'dark' ? '#1a1d21' : '#ffffff';
            const contentRect = content.getBoundingClientRect();
            const firstLine = content.querySelector('.cm-line');
            const gutter = document.querySelector('.cm-gutters');
            const replace = panel?.querySelector('input[name=replace]');
            return {
              scheme: style.colorScheme,
              rootTransparent: style.backgroundColor === 'rgba(0, 0, 0, 0)',
              gutterCount: document.querySelectorAll('.cm-gutters,.cm-lineNumbers').length,
              gutterWidth: gutter ? gutter.getBoundingClientRect().width : 0,
              contentPadding: parseFloat(contentStyle.paddingLeft) || 0,
              lineInset: firstLine ? Math.round(firstLine.getBoundingClientRect().left - contentRect.left) : -1,
              textContrastPass: contrast(primary, page) >= 4.5,
              selectedSearchContrastPass: contrast(primary, selected) >= 4.5,
              borderContrastPass: contrast(border, panelColor) >= 3,
              focusOutlineWidth: parseFloat(style.outlineWidth) || 0,
              scrollBehavior: getComputedStyle(document.querySelector('.cm-scroller')).scrollBehavior,
              searchVisible: !!panel,
              replaceVisible: !!replace && getComputedStyle(replace).display !== 'none',
              semanticDecorationCount: document.querySelectorAll('[class*=tc-heading],.tc-strong,.tc-wikilink,.tc-tag,.tc-blockquote,.tc-task-control,.tc-inline-code,.tc-highlight,.tc-comment').length,
              frozen: root.classList.contains('tc-frozen')
            };
        """) as? [String: Any]) ?? [:]
    }

    private func snapshot(_ webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private func snapshotStats(_ image: NSImage) throws -> (averageLuminance: Double, luminanceRange: Double) {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var total = 0.0
        var count = 0.0
        var minimum = 1.0
        var maximum = 0.0
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 160)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                total += luminance
                count += 1
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return (total / count, maximum - minimum)
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

@MainActor
private final class ToolbarFrameRecorder {
    var frames: [String: CGRect] = [:]
}
