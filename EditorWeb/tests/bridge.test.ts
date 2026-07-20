import {describe, expect, it, vi} from "vitest"
import {TypedBridge} from "../src/bridge"
import type {
  NativeEnvelope,
  NativeMethod,
  NativePayloadMap,
  NativeReplyMap
} from "../src/protocol"

function incoming(sessionID: string, sequence: number, method = "captureViewState") {
  return {protocolVersion: 1, sessionID, requestID: `native-${sequence}`, sequence, method, payload: {}}
}

describe("typed bridge", () => {
  const viewState = {selection: [{anchor: 0, head: 0}], mainSelectionIndex: 0, scrollTop: 0}
  const patch = {baseLength: 0, intent: "text" as const, changes: []}

  it("serializes outgoing requests through editorBridge", async () => {
    const postMessage = vi.fn(async (_message: unknown) => ({ok: true}))
    window.webkit = {messageHandlers: {editorBridge: {postMessage}}}
    const bridge = new TypedBridge("session")
    await Promise.all([
      bridge.send("ready", {
        protocolVersion: 1, loadToken: "load", utf16Coordinates: true,
        modes: ["original", "editedView", "editedEditing"], capabilities: ["patches"]
      }),
      bridge.send("viewState", viewState)
    ])
    expect(postMessage.mock.calls.map(call => (call[0] as {sequence: number}).sequence)).toEqual([0, 1])
    expect((postMessage.mock.calls[0]![0] as {sessionID: string}).sessionID).toBe("session")
  })

  it("rejects stale sessions, unknown methods, duplicates, and skipped sequences", async () => {
    const bridge = new TypedBridge("active")
    bridge.setNativeHandler(<M extends NativeMethod>(
      _message: NativeEnvelope<M>
    ): NativeReplyMap[M] => viewState as NativeReplyMap[M])
    expect((await bridge.receive(incoming("stale", 0))).ok).toBe(false)
    expect((await bridge.receive(incoming("active", 1))).error).toContain("out-of-order")
    expect((await bridge.receive(incoming("active", 0, "notACommand"))).error).toContain("Unknown")
    expect((await bridge.receive(incoming("active", 0))).ok).toBe(true)
    expect((await bridge.receive(incoming("active", 0))).error).toContain("out-of-order")
  })

  it("does not consume a native sequence when handling rejects", async () => {
    const bridge = new TypedBridge("active")
    let shouldReject = true
    bridge.setNativeHandler(<M extends NativeMethod>(
      _message: NativeEnvelope<M>
    ): NativeReplyMap[M] => {
      if (shouldReject) throw new Error("invalid payload")
      return viewState as NativeReplyMap[M]
    })
    expect((await bridge.receive(incoming("active", 0))).error).toContain("invalid payload")
    shouldReject = false
    expect((await bridge.receive(incoming("active", 0))).ok).toBe(true)
    expect((await bridge.receive(incoming("active", 1))).ok).toBe(true)
  })

  it("keeps every native method correlated to its production payload and reply", async () => {
    const payloads = {
      configure: {
        mode: "editedEditing",
        preferences: {fontSize: 16, width: "wide", editedAlignment: "center", focusMode: false},
        appearance: {colorScheme: "dark", increasedContrast: false, reduceMotion: false}
      },
      replaceDocument: {text: "A", mode: "editedEditing", resetHistory: true},
      applyExternalChanges: {mode: "editedEditing", changes: []},
      requestSnapshot: {reason: "test"},
      captureViewState: {},
      restoreViewState: viewState,
      setStableDecorations: {decorations: []},
      setPlaybackDecoration: {decoration: null},
      setFrozen: {frozen: false, reason: "test"},
      executeCommand: {command: "bold"}
    } satisfies NativePayloadMap
    const replies = {
      configure: {mode: "editedEditing"},
      replaceDocument: {length: 1},
      applyExternalChanges: {text: "A", length: 1},
      requestSnapshot: {text: "A", mode: "editedEditing", viewState, reason: "test"},
      captureViewState: viewState,
      restoreViewState: viewState,
      setStableDecorations: {count: 0},
      setPlaybackDecoration: {active: false},
      setFrozen: {frozen: false},
      executeCommand: true
    } satisfies NativeReplyMap
    const bridge = new TypedBridge("typed-session")
    bridge.setNativeHandler(<M extends NativeMethod>(
      message: NativeEnvelope<M>
    ): NativeReplyMap[M] => replies[message.method] as NativeReplyMap[M])

    let sequence = 0
    for (const method of Object.keys(payloads) as NativeMethod[]) {
      const result = await bridge.receive({
        protocolVersion: 1,
        sessionID: "typed-session",
        requestID: `typed-${sequence}`,
        sequence: sequence++,
        method,
        payload: payloads[method]
      })
      expect(result).toEqual({ok: true, result: replies[method]})
    }
  })

  it("makes a before-host web-to-native failure terminal without reserving later sequences", async () => {
    const failure = vi.fn()
    window.addEventListener("transcride-editor-transport-failure", failure, {once: true})
    const postMessage = vi.fn(async (_message: unknown) => { throw new Error("transport failed") })
    window.webkit = {messageHandlers: {editorBridge: {postMessage}}}
    const bridge = new TypedBridge("session")
    expect((await bridge.send("viewState", viewState)).error).toContain("transport failed")
    expect((await bridge.send("patches", patch)).error).toContain("transport failed")
    expect(postMessage).toHaveBeenCalledTimes(2)
    expect((postMessage.mock.calls[0]![0] as {sequence: number}).sequence).toBe(0)
    expect(postMessage.mock.calls[1]![0]).toMatchObject({
      sequence: 0,
      method: "action",
      payload: {kind: "transportFailure", message: "transport failed"}
    })
    expect(failure).toHaveBeenCalledOnce()
  })

  it("emits the same sequence-bypassing terminal signal after native accepted but the reply was lost", async () => {
    let calls = 0
    const postMessage = vi.fn(async (_message: unknown) => {
      calls++
      if (calls === 1) throw new Error("reply lost after acceptance")
      return {ok: true, result: {accepted: true}}
    })
    window.webkit = {messageHandlers: {editorBridge: {postMessage}}}
    const bridge = new TypedBridge("accepted-session")
    expect((await bridge.send("patches", patch)).ok)
      .toBe(false)
    expect(postMessage).toHaveBeenCalledTimes(2)
    expect(postMessage.mock.calls.map(call => (call[0] as {sequence: number}).sequence))
      .toEqual([0, 0])
    expect(postMessage.mock.calls[1]![0]).toMatchObject({
      method: "action",
      payload: {kind: "transportFailure", message: "reply lost after acceptance"}
    })
    expect((await bridge.send("viewState", viewState)).error).toContain("reply lost")
    expect(postMessage).toHaveBeenCalledTimes(2)
  })
})
