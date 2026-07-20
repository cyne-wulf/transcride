export const protocolVersion = 1 as const

export type EditorMode = "original" | "editedView" | "editedEditing"
export type WidthPreset = "narrow" | "wide" | "full"
export type EditedAlignment = "center" | "left"

export interface Envelope<M extends string = string, P = unknown> {
  protocolVersion: typeof protocolVersion
  sessionID: string
  requestID: string
  sequence: number
  method: M
  payload: P
}

export interface UTF16Patch {
  from: number
  to: number
  insert: string
}

export interface PatchPayload {
  baseLength: number
  intent: "text" | "task" | "history"
  changes: UTF16Patch[]
}

export interface SelectionRange {
  anchor: number
  head: number
}

export interface ViewStatePayload {
  selection: SelectionRange[]
  mainSelectionIndex: number
  scrollTop: number
}

export interface EditorPreferences {
  fontSize: number
  width: WidthPreset
  editedAlignment: EditedAlignment
  focusMode: boolean
}

export interface EditorAppearance {
  colorScheme: "light" | "dark"
  increasedContrast: boolean
  reduceMotion: boolean
}

export interface NativeDecoration {
  from: number
  to: number
  kind: "playback" | "search" | "spokenWord" | "speaker" | "unresolvedLink" | "ambiguousLink"
  data?: Record<string, unknown>
}

export interface DocumentPayload {
  text: string
  mode: EditorMode
  selection?: SelectionRange[]
  mainSelectionIndex?: number
  scrollTop?: number
  resetHistory?: boolean
}

export type NativeMethod =
  | "configure"
  | "replaceDocument"
  | "applyExternalChanges"
  | "requestSnapshot"
  | "captureViewState"
  | "restoreViewState"
  | "setStableDecorations"
  | "setPlaybackDecoration"
  | "setFrozen"
  | "executeCommand"

export type WebMethod =
  | "ready"
  | "patches"
  | "snapshot"
  | "viewState"
  | "focusOwnership"
  | "linkAction"
  | "clickAction"
  | "preferenceAction"
  | "performance"
  | "action"

export type EditorCommand = "openFind" | "closeFind" | "findNext" | "findPrevious" |
  "replaceNext" | "replaceAll" | "undo" | "redo" | "bold" | "italic" | "link"

export interface NativePayloadMap {
  configure: {mode?: EditorMode, preferences: EditorPreferences, appearance: EditorAppearance}
  replaceDocument: DocumentPayload
  applyExternalChanges: {mode: EditorMode, changes: UTF16Patch[]}
  requestSnapshot: {reason: string}
  captureViewState: Record<string, never>
  restoreViewState: ViewStatePayload
  setStableDecorations: {decorations: NativeDecoration[]}
  setPlaybackDecoration: {decoration: NativeDecoration | null}
  setFrozen: {frozen: boolean, reason?: string}
  executeCommand: {command: EditorCommand}
}

export interface NativeReplyMap {
  configure: {mode: EditorMode}
  replaceDocument: {length: number}
  applyExternalChanges: {text: string, length: number}
  requestSnapshot: SnapshotPayload
  captureViewState: ViewStatePayload
  restoreViewState: ViewStatePayload
  setStableDecorations: {count: number}
  setPlaybackDecoration: {active: boolean}
  setFrozen: {frozen: boolean}
  executeCommand: boolean
}

export type NativeHandlerMap = {
  [K in NativeMethod]: (
    payload: NativePayloadMap[K]
  ) => NativeReplyMap[K] | Promise<NativeReplyMap[K]>
}

export interface SnapshotPayload {
  text: string
  mode: EditorMode
  viewState: ViewStatePayload
  reason: string
}

export type LinkActionPayload =
  | {kind: "wikilink", target: string, alias: string | null, from: number, to: number}
  | {kind: "markdownLink", label: string, destination: string, from: number, to: number}

export interface WebPayloadMap {
  ready: {protocolVersion: 1, loadToken: string, utf16Coordinates: true,
    modes: EditorMode[], capabilities: string[]}
  patches: PatchPayload
  snapshot: SnapshotPayload
  viewState: ViewStatePayload
  focusOwnership: {owner: "application" | "editor" | "search", acceptsTextInput: boolean,
    historyOwnership: boolean, composing: boolean, mode: EditorMode}
  linkAction: LinkActionPayload
  clickAction: {kind: "originalPosition" | "enterEditing", position: number}
  preferenceAction: {kind: "fontSize", value: number}
  performance: {kind: "input" | "playback" | "bridge", sampleCount: number,
    p95Milliseconds: number, maximumMilliseconds: number, documentLength: number,
    targetMet: boolean}
  action: {kind: "userScroll"} | {kind: "transportFailure", message: string}
}

export interface WebReplyMap {
  ready: {accepted: true}
  patches: PatchAcknowledgement
  snapshot: {accepted: true}
  viewState: {accepted: true}
  focusOwnership: {accepted: true}
  linkAction: {accepted: true}
  clickAction: {accepted: true}
  preferenceAction: {accepted: true}
  performance: {accepted: true}
  action: {accepted: true, terminalSession?: boolean}
}

export type NativeEnvelope<M extends NativeMethod = NativeMethod> = {
  [K in M]: Envelope<K, NativePayloadMap[K]>
}[M]

export type WebEnvelope<M extends WebMethod = WebMethod> = {
  [K in M]: Envelope<K, WebPayloadMap[K]>
}[M]

export interface BridgeReply<Result = unknown> {
  ok: boolean
  error?: string
  result?: Result
}

export type PatchAcknowledgement =
  | {accepted: true}
  | {accepted: false, requiresSnapshot: true}

export function validatePatchAcknowledgement(value: unknown): value is PatchAcknowledgement {
  if (!value || typeof value !== "object") return false
  const acknowledgement = value as Record<string, unknown>
  const keys = Object.keys(acknowledgement).sort().join(",")
  return (keys === "accepted" && acknowledgement.accepted === true) ||
    (keys === "accepted,requiresSnapshot" && acknowledgement.accepted === false &&
      acknowledgement.requiresSnapshot === true)
}

export function validateEnvelope(value: unknown): value is Envelope {
  if (!value || typeof value !== "object") return false
  const envelope = value as Record<string, unknown>
  return envelope.protocolVersion === protocolVersion &&
    typeof envelope.sessionID === "string" && envelope.sessionID.length > 0 &&
    typeof envelope.requestID === "string" && envelope.requestID.length > 0 &&
    Number.isSafeInteger(envelope.sequence) && (envelope.sequence as number) >= 0 &&
    typeof envelope.method === "string" &&
    "payload" in envelope
}

export function validatePatches(baseLength: number, changes: readonly UTF16Patch[]): boolean {
  if (!Number.isSafeInteger(baseLength) || baseLength < 0) return false
  let previousEnd = 0
  for (const change of changes) {
    if (!Number.isSafeInteger(change.from) || !Number.isSafeInteger(change.to) ||
        change.from < previousEnd || change.from < 0 || change.to < change.from ||
        change.to > baseLength || typeof change.insert !== "string") return false
    previousEnd = change.to
  }
  return true
}

export function applyPatches(text: string, changes: readonly UTF16Patch[]): string {
  if (!validatePatches(text.length, changes)) throw new RangeError("Invalid UTF-16 patch batch")
  let result = text
  for (let index = changes.length - 1; index >= 0; index--) {
    const change = changes[index]!
    result = result.slice(0, change.from) + change.insert + result.slice(change.to)
  }
  return result
}
