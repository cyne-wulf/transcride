import {
  type BridgeReply,
  type NativeEnvelope,
  type NativeMethod,
  type NativeReplyMap,
  protocolVersion,
  validateEnvelope,
  type WebEnvelope,
  type WebMethod,
  type WebPayloadMap,
  type WebReplyMap
} from "./protocol"

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        editorBridge?: {postMessage(message: unknown): Promise<unknown>}
      }
    }
  }
}

function identifier(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

export interface NativeHandler {
  <M extends NativeMethod>(
    message: NativeEnvelope<M>
  ): NativeReplyMap[M] | Promise<NativeReplyMap[M]>
}

export class TypedBridge {
  readonly sessionID: string
  private outgoingSequence = 0
  private incomingSequence = -1
  private handler: NativeHandler | undefined
  private transportFailureHandler: ((message: string) => void) | undefined
  private outgoingQueue = Promise.resolve()
  private terminalTransportError: string | undefined

  constructor(sessionID = identifier()) {
    this.sessionID = sessionID
  }

  setNativeHandler(handler: NativeHandler): void {
    this.handler = handler
  }

  setTransportFailureHandler(handler: (message: string) => void): void {
    this.transportFailureHandler = handler
  }

  send<M extends WebMethod>(method: M, payload: WebPayloadMap[M]): Promise<BridgeReply<WebReplyMap[M]>> {
    let resolveReply!: (reply: BridgeReply<WebReplyMap[M]>) => void
    const result = new Promise<BridgeReply<WebReplyMap[M]>>(resolve => { resolveReply = resolve })
    this.outgoingQueue = this.outgoingQueue.then(async () => {
      if (this.terminalTransportError) {
        resolveReply({ok: false, error: this.terminalTransportError})
        return
      }
      const endpoint = window.webkit?.messageHandlers?.editorBridge
      if (!endpoint) {
        const message = "Native editorBridge is unavailable"
        this.failTransport(message)
        resolveReply({ok: false, error: message})
        return
      }
      const message = {
        protocolVersion,
        sessionID: this.sessionID,
        requestID: identifier(),
        sequence: this.outgoingSequence,
        method,
        payload
      } as WebEnvelope<M>
      try {
        const reply = await endpoint.postMessage(message) as BridgeReply<WebReplyMap[M]> |
          WebReplyMap[M] | undefined
        this.outgoingSequence++
        resolveReply(reply && typeof reply === "object" && "ok" in reply && typeof reply.ok === "boolean"
          ? reply as BridgeReply<WebReplyMap[M]>
          : {ok: true, result: reply as WebReplyMap[M]})
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.failTransport(message)
        resolveReply({ok: false, error: message})
      }
    })
    return result
  }

  private failTransport(message: string): void {
    this.terminalTransportError = message
    this.transportFailureHandler?.(message)
    window.dispatchEvent(new CustomEvent("transcride-editor-transport-failure", {detail: message}))
    const endpoint = window.webkit?.messageHandlers?.editorBridge
    if (endpoint) {
      const recoverySignal: WebEnvelope<"action"> = {
        protocolVersion,
        sessionID: this.sessionID,
        requestID: identifier(),
        sequence: this.outgoingSequence,
        method: "action",
        payload: {kind: "transportFailure", message}
      }
      void endpoint.postMessage(recoverySignal).catch(() => {
        // The editor is already frozen. WebKit process termination remains
        // the final recovery signal when the message channel is fully gone.
      })
    }
  }

  async receive<M extends NativeMethod>(
    value: NativeEnvelope<M>
  ): Promise<BridgeReply<NativeReplyMap[M]>>
  async receive(value: unknown): Promise<BridgeReply<NativeReplyMap[NativeMethod]>>
  async receive(value: unknown): Promise<BridgeReply<NativeReplyMap[NativeMethod]>> {
    if (!validateEnvelope(value)) return {ok: false, error: "Invalid bridge envelope"}
    if (value.sessionID !== this.sessionID) return {ok: false, error: "Stale editor session"}
    if (value.sequence !== this.incomingSequence + 1) return {ok: false, error: "Duplicate or out-of-order sequence"}
    const known: readonly NativeMethod[] = [
      "configure", "replaceDocument", "applyExternalChanges", "requestSnapshot", "captureViewState",
      "restoreViewState", "setStableDecorations", "setPlaybackDecoration", "setFrozen", "executeCommand"
    ]
    if (!known.includes(value.method as NativeMethod)) return {ok: false, error: "Unknown native method"}
    if (!this.handler) return {ok: false, error: "Editor is not initialized"}
    try {
      const result = await this.dispatchToNativeHandler(value as NativeEnvelope)
      this.incomingSequence = value.sequence
      return {ok: true, result}
    } catch (error) {
      return {ok: false, error: error instanceof Error ? error.message : String(error)}
    }
  }

  private async dispatchToNativeHandler<M extends NativeMethod>(
    message: NativeEnvelope<M>
  ): Promise<NativeReplyMap[M]> {
    if (!this.handler) throw new Error("Editor is not initialized")
    return await this.handler(message)
  }
}
