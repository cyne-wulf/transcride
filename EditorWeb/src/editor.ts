import {
  defaultKeymap,
  history,
  historyKeymap,
  indentLess,
  indentMore,
  invertedEffects,
  redo,
  undo
} from "@codemirror/commands"
import {bracketMatching, indentOnInput, syntaxTree} from "@codemirror/language"
import {markdown, insertNewlineContinueMarkup} from "@codemirror/lang-markdown"
import {
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  openSearchPanel,
  replaceAll,
  replaceNext,
  search,
  searchKeymap,
  searchPanelOpen
} from "@codemirror/search"
import {
  Annotation,
  Compartment,
  EditorSelection,
  EditorState,
  MapMode,
  StateEffect,
  TransactionSpec,
  Transaction,
  type Extension
} from "@codemirror/state"
import {
  drawSelection,
  EditorView,
  keymap,
  type Command,
  type ViewUpdate,
  ViewPlugin
} from "@codemirror/view"
import {Strikethrough, Table, TaskList} from "@lezer/markdown"
import {TypedBridge} from "./bridge"
import {
  focusDecorationPlugin,
  markdownPositionIsInert,
  markdownDecorationPlugin,
  obsidianCommentAt,
  obsidianComments,
  playbackNativeDecoration,
  setPlaybackDecoration,
  setStableDecorations,
  stableNativeDecorations,
  taskChange
} from "./decorations"
import {toggleDelimiter, toggleLink} from "./formatting"
import {
  ExactTextIndex,
  type ExactDelta,
  normalizeExactText
} from "./exactText"
import {
  type DocumentPayload,
  type EditorAppearance,
  type EditorMode,
  type EditorPreferences,
  type NativeEnvelope,
  type NativeDecoration,
  type NativeHandlerMap,
  type NativeMethod,
  type NativePayloadMap,
  type NativeReplyMap,
  type LinkActionPayload,
  type PatchPayload,
  type PatchAcknowledgement,
  type SelectionRange,
  type SnapshotPayload,
  type ViewStatePayload,
  validatePatchAcknowledgement,
  validatePatches
} from "./protocol"

const nativeChange = Annotation.define<boolean>()

type NativeMethodHandler<M extends NativeMethod> = (
  payload: NativePayloadMap[M]
) => NativeReplyMap[M] | Promise<NativeReplyMap[M]>

const continueMarkupWithQuoteExit: Command = view => {
  const emptyQuotes = view.state.selection.ranges.every(range => {
    if (!range.empty) return false
    return /^\s*>\s*$/.test(view.state.doc.lineAt(range.head).text)
  })
  if (!emptyQuotes) return insertNewlineContinueMarkup(view)
  view.dispatch(view.state.changeByRange(range => {
    const line = view.state.doc.lineAt(range.head)
    return {
      changes: {from: line.from, to: line.to, insert: ""},
      range: EditorSelection.cursor(line.from)
    }
  }))
  return true
}

const defaultPreferences: EditorPreferences = {
  fontSize: 16,
  width: "wide",
  editedAlignment: "center",
  focusMode: false
}

const defaultAppearance: EditorAppearance = {
  colorScheme: "light",
  increasedContrast: false,
  reduceMotion: false
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object"
}

function validMode(value: unknown): value is EditorMode {
  return value === "original" || value === "editedView" || value === "editedEditing"
}

function validUTF16Boundary(text: string, position: number): number {
  const clamped = Math.max(0, Math.min(text.length, position))
  if (clamped > 0 && clamped < text.length) {
    const previous = text.charCodeAt(clamped - 1)
    const next = text.charCodeAt(clamped)
    if (previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) return clamped - 1
  }
  return clamped
}

function clampedSelection(value: unknown, text: string): SelectionRange[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined
  const ranges: SelectionRange[] = []
  for (const range of value) {
    if (!isRecord(range) || !Number.isSafeInteger(range.anchor) || !Number.isSafeInteger(range.head)) return undefined
    ranges.push({
      anchor: validUTF16Boundary(text, range.anchor as number),
      head: validUTF16Boundary(text, range.head as number)
    })
  }
  return ranges
}

function validNativeDecoration(value: unknown, length: number): value is NativeDecoration {
  if (!isRecord(value) || !Number.isSafeInteger(value.from) || !Number.isSafeInteger(value.to)) return false
  const from = value.from as number
  const to = value.to as number
  return from >= 0 && to >= from && to <= length &&
    (value.kind === "playback" || value.kind === "search" || value.kind === "spokenWord" || value.kind === "speaker" ||
      value.kind === "unresolvedLink" || value.kind === "ambiguousLink") &&
    (value.data === undefined || isRecord(value.data))
}

function selectionFrom(ranges: SelectionRange[], mainIndex = 0): EditorSelection {
  return EditorSelection.create(
    ranges.map(range => EditorSelection.range(range.anchor, range.head)),
    Math.max(0, Math.min(mainIndex, ranges.length - 1))
  )
}

function percentile95(samples: readonly number[]): number {
  if (!samples.length) return 0
  const sorted = [...samples].sort((a, b) => a - b)
  return sorted[Math.ceil(sorted.length * 0.95) - 1] ?? 0
}

let searchCountScanCount = 0

interface ExactSeparatorTarget {
  separators: Array<{position: number, value: string}>
}

const exactSeparatorTarget = StateEffect.define<ExactSeparatorTarget>({
  map(value, mapping) {
    const separators = value.separators.flatMap(separator => {
      const position = mapping.mapPos(separator.position, 1, MapMode.TrackDel)
      return position == null ? [] : [{position, value: separator.value}]
    })
    return separators.length ? {separators} : undefined
  }
})

type ExactCompositionPiece =
  | {kind: "original", from: number, to: number}
  | {kind: "insert", text: string}

function compositionPieceLength(piece: ExactCompositionPiece): number {
  return piece.kind === "original" ? piece.to - piece.from : piece.text.length
}

function splitCompositionPieces(pieces: ExactCompositionPiece[], offset: number): number {
  let cursor = 0
  for (let index = 0; index < pieces.length; index++) {
    const piece = pieces[index]!
    const end = cursor + compositionPieceLength(piece)
    if (offset === cursor) return index
    if (offset === end) return index + 1
    if (offset > cursor && offset < end) {
      const local = offset - cursor
      const split = piece.kind === "original"
        ? [
            {kind: "original", from: piece.from, to: piece.from + local},
            {kind: "original", from: piece.from + local, to: piece.to}
          ] as ExactCompositionPiece[]
        : [
            {kind: "insert", text: piece.text.slice(0, local)},
            {kind: "insert", text: piece.text.slice(local)}
          ] as ExactCompositionPiece[]
      pieces.splice(index, 1, ...split)
      return index + 1
    }
    cursor = end
  }
  return pieces.length
}

function applyCompositionPatches(
  pieces: ExactCompositionPiece[],
  changes: readonly {from: number, to: number, insert: string}[]
): void {
  for (let index = changes.length - 1; index >= 0; index--) {
    const change = changes[index]!
    const fromIndex = splitCompositionPieces(pieces, change.from)
    const toIndex = splitCompositionPieces(pieces, change.to)
    pieces.splice(
      fromIndex,
      toIndex - fromIndex,
      ...(change.insert ? [{kind: "insert", text: change.insert} as ExactCompositionPiece] : [])
    )
  }
}

function compositionPatches(
  pieces: readonly ExactCompositionPiece[],
  baseLength: number
): Array<{from: number, to: number, insert: string}> {
  const result: Array<{from: number, to: number, insert: string}> = []
  let originalCursor = 0
  let pendingFrom: number | undefined
  let pendingInsert = ""
  const flush = (to: number): void => {
    if (pendingFrom === undefined) return
    result.push({from: pendingFrom, to, insert: pendingInsert})
    pendingFrom = undefined
    pendingInsert = ""
  }
  for (const piece of pieces) {
    if (piece.kind === "insert") {
      pendingFrom ??= originalCursor
      pendingInsert += piece.text
      continue
    }
    if (piece.from > originalCursor) pendingFrom ??= originalCursor
    flush(piece.from)
    originalCursor = piece.to
  }
  if (originalCursor < baseLength) pendingFrom ??= originalCursor
  flush(baseLength)
  return result
}

function searchCountExtension(): Extension {
  class SearchCountPlugin {
    constructor(readonly view: EditorView) { this.schedule() }
    update(update: ViewUpdate): void {
      const before = getSearchQuery(update.startState)
      const after = getSearchQuery(update.state)
      if (update.docChanged || !before.eq(after) || searchPanelOpen(update.startState) !== searchPanelOpen(update.state)) {
        this.schedule()
      }
    }
    private schedule(): void { queueMicrotask(() => this.refresh()) }
    private refresh(): void {
      const panel = this.view.dom.querySelector<HTMLElement>(".cm-search")
      if (!panel) return
      let status = panel.querySelector<HTMLElement>(".tc-search-count")
      if (!status) {
        status = document.createElement("span")
        status.className = "tc-search-count"
        status.setAttribute("role", "status")
        status.setAttribute("aria-live", "polite")
        panel.append(status)
      }
      const query = getSearchQuery(this.view.state)
      if (!query.valid || !query.search) { status.textContent = "0 matches"; return }
      searchCountScanCount++
      let count = 0
      let active = 0
      const selection = this.view.state.selection.main
      const cursor = query.getCursor(this.view.state)
      for (let match = cursor.next(); !match.done; match = cursor.next()) {
        count++
        if (selection.from >= match.value.from && selection.to <= match.value.to) active = count
      }
      status.textContent = count === 0 ? "0 matches" : `${active || 1} of ${count}`
    }
  }
  return ViewPlugin.fromClass<SearchCountPlugin>(SearchCountPlugin)
}

export class TranscrideEditor {
  readonly bridge: TypedBridge
  private view: EditorView
  private mode: EditorMode = "original"
  private frozen = false
  private preferences: EditorPreferences = {...defaultPreferences}
  private appearance: EditorAppearance = {...defaultAppearance}
  private readonly modeCompartment = new Compartment()
  private readonly appearanceCompartment = new Compartment()
  private composing = false
  private compositionBaseLength = 0
  private compositionPieces: ExactCompositionPiece[] | undefined
  private compositionWaiters: Array<() => void> = []
  private latencySamples: number[] = []
  private taskHistoryOwnsInput = false
  private taskUndoDepth = 0
  private taskRedoDepth = 0
  private lastInputStarted: number | undefined
  private originalState: EditorState | undefined
  private editedState: EditorState | undefined
  private exactMap = new ExactTextIndex("")
  private originalExactMap: ExactTextIndex | undefined
  private editedExactMap: ExactTextIndex | undefined
  private viewStateReportTimer: ReturnType<typeof setTimeout> | undefined
  private viewStateReportInFlight = false
  private viewStateReportQueued = false
  private programmaticScroll = false
  private readonly nativeHandlers: NativeHandlerMap = {
    configure: payload => {
      this.configure(payload)
      return {mode: this.mode}
    },
    replaceDocument: payload => {
      this.replaceDocument(payload)
      return {length: this.view.state.doc.length}
    },
    applyExternalChanges: payload => this.applyExternalChanges(payload),
    requestSnapshot: payload => {
      if (!isRecord(payload) || typeof payload.reason !== "string") {
        throw new TypeError("Invalid snapshot request")
      }
      return this.sendSnapshot(payload.reason)
    },
    captureViewState: async () => {
      const state = this.currentViewState()
      await this.bridge.send("viewState", state)
      return state
    },
    restoreViewState: payload => {
      this.restoreViewState(payload)
      return this.currentViewState()
    },
    setStableDecorations: payload => {
      if (!isRecord(payload) || !Array.isArray(payload.decorations)) {
        throw new TypeError("Invalid decorations")
      }
      if (!payload.decorations.every(value =>
        validNativeDecoration(value, this.exactMap.exactLength))) {
        throw new RangeError("Invalid native decoration range or kind")
      }
      const decorations = payload.decorations.map(item => ({
        ...item,
        from: this.exactMap.externalToInternal(item.from, this.view.state.doc),
        to: this.exactMap.externalToInternal(item.to, this.view.state.doc)
      }))
      this.view.dispatch({
        effects: setStableDecorations.of(decorations),
        annotations: nativeChange.of(true)
      })
      return {count: decorations.length}
    },
    setPlaybackDecoration: payload => {
      if (!isRecord(payload) || !("decoration" in payload)) {
        throw new TypeError("Invalid playback decoration")
      }
      const raw = payload.decoration
      if (raw !== null && !validNativeDecoration(raw, this.exactMap.exactLength)) {
        throw new RangeError("Invalid playback decoration range")
      }
      const playback = raw === null ? null : {
        ...raw,
        from: this.exactMap.externalToInternal(raw.from, this.view.state.doc),
        to: this.exactMap.externalToInternal(raw.to, this.view.state.doc)
      }
      if (playback && playback.kind !== "playback") {
        throw new TypeError("Invalid playback decoration kind")
      }
      const effects: StateEffect<unknown>[] = [setPlaybackDecoration.of(playback)]
      if (playback?.data?.follow === true) {
        effects.push(EditorView.scrollIntoView(playback.from, {y: "center", yMargin: 40}))
      }
      this.view.dispatch({effects, annotations: nativeChange.of(true)})
      return {active: playback !== null}
    },
    setFrozen: payload => {
      if (!isRecord(payload) || typeof payload.frozen !== "boolean") {
        throw new TypeError("Invalid frozen state")
      }
      this.frozen = payload.frozen
      if (this.frozen) this.clearTaskHistoryOwnership()
      this.setMode(this.mode)
      this.reportFocus(document.activeElement)
      return {frozen: this.frozen}
    },
    executeCommand: payload => this.executeCommand(payload)
  }

  private get exactText(): string { return this.exactMap.exactText(this.view.state.doc) }
  private set exactText(value: string) { this.exactMap = new ExactTextIndex(value) }

  constructor(parent: HTMLElement, bridge = new TypedBridge()) {
    this.bridge = bridge
    this.bridge.setNativeHandler(<M extends NativeMethod>(message: NativeEnvelope<M>) =>
      this.handleNativeEnvelope(message))
    this.bridge.setTransportFailureHandler(message => this.handleTransportFailure(message))
    this.view = new EditorView({
      parent,
      state: this.createState("")
    })
    this.originalState = this.view.state
    this.installCompositionObservers()
    this.view.contentDOM.addEventListener("beforeinput", () => { this.lastInputStarted = performance.now() })
    document.addEventListener("focusin", event => this.reportFocus(event.target))
    document.addEventListener("focusout", () => queueMicrotask(() => this.reportFocus(document.activeElement)))
    this.view.scrollDOM.addEventListener("wheel", () => {
      void this.bridge.send("action", {kind: "userScroll"})
    }, {passive: true})
    this.view.scrollDOM.addEventListener("scroll", () => {
      if (this.programmaticScroll) return
      this.scheduleViewStateReport(50)
    }, {passive: true})
  }

  private createState(text: string, selection?: EditorSelection): EditorState {
    return EditorState.create({
      doc: normalizeExactText(text),
      selection: selection ?? EditorSelection.cursor(0),
      extensions: this.baseExtensions()
    })
  }

  private handleTransportFailure(message: string): void {
    this.frozen = true
    this.clearTaskHistoryOwnership()
    this.reconfigureEditor()
    this.view.dom.setAttribute("aria-busy", "true")
    let status = this.view.dom.querySelector<HTMLElement>(".tc-transport-failure")
    if (!status) {
      status = document.createElement("div")
      status.className = "tc-transport-failure"
      status.setAttribute("role", "alert")
      this.view.dom.prepend(status)
    }
    status.textContent = `Editor connection interrupted: ${message}`
  }

  private baseExtensions(): Extension[] {
    return [
      history(),
      invertedEffects.of(transaction => {
        if (!transaction.docChanged || transaction.annotation(nativeChange)) return []
        const separators: Array<{position: number, value: string}> = []
        transaction.changes.iterChanges((fromA, toA) => {
          separators.push(...this.exactMap.separators(fromA, toA))
        })
        return separators.length ? [exactSeparatorTarget.of({separators})] : []
      }),
      drawSelection(),
      EditorState.allowMultipleSelections.of(true),
      indentOnInput(),
      bracketMatching(),
      markdown({extensions: [Strikethrough, Table, TaskList], addKeymap: false}),
      obsidianComments,
      search({top: true}),
      searchCountExtension(),
      stableNativeDecorations,
      playbackNativeDecoration,
      EditorState.transactionFilter.of(transaction => this.filterTransaction(transaction)),
      this.modeCompartment.of(this.modeExtensions()),
      this.appearanceCompartment.of(this.appearanceExtensions()),
      EditorView.updateListener.of(update => this.didUpdate(update)),
      EditorView.contentAttributes.of({
        spellcheck: "true",
        autocorrect: "off",
        autocapitalize: "off",
        "data-gramm": "false",
        "aria-label": "Transcript Markdown source editor"
      }),
      EditorView.theme({
        "&": {height: "100%", backgroundColor: "transparent", color: "var(--tc-primary)"},
        ".cm-scroller": {fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif", overflow: "auto"},
        ".cm-content": {padding: "24px 28px 80px", color: "var(--tc-primary)", caretColor: "var(--tc-caret)"},
        ".cm-line": {padding: "0 2px"},
        ".cm-gutters": {display: "none", width: "0", minWidth: "0", border: "none"},
        ".cm-activeLineGutter": {backgroundColor: "transparent"},
        ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {backgroundColor: "var(--tc-selection)"},
        ".cm-search": {backgroundColor: "var(--tc-panel)", color: "var(--tc-primary)", borderBottom: "1px solid var(--tc-border)"},
        ".cm-search input, .cm-search button": {font: "menu", color: "var(--tc-primary)", backgroundColor: "var(--tc-control)", borderColor: "var(--tc-border)"},
        ".cm-search label, .tc-search-count": {color: "var(--tc-secondary)"},
        ".tc-search-count": {font: "menu", marginInlineStart: ".5em", whiteSpace: "nowrap"},
        ".tc-heading": {fontWeight: "700", color: "var(--tc-primary)"},
        ".tc-heading-1": {fontSize: "1.6em"},
        ".tc-heading-2": {fontSize: "1.4em"},
        ".tc-heading-3": {fontSize: "1.2em"},
        ".tc-emphasis": {fontStyle: "italic"},
        ".tc-strong": {fontWeight: "700"},
        ".tc-strikethrough": {textDecoration: "line-through"},
        ".tc-inline-code, .tc-code-block": {fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "var(--tc-primary)", backgroundColor: "var(--tc-code-bg)"},
        ".tc-blockquote": {color: "var(--tc-secondary)"},
        ".tc-link, .tc-wikilink": {color: "var(--tc-link)", textDecoration: "underline", textUnderlineOffset: "2px"},
        ".tc-table-header": {fontWeight: "600"},
        ".tc-table-delimiter": {color: "var(--tc-secondary)"},
        ".tc-highlight": {color: "var(--tc-primary)", backgroundColor: "var(--tc-highlight)"},
        ".tc-comment": {color: "var(--tc-comment)", fontStyle: "italic"},
        ".tc-tag": {color: "var(--tc-tag)"},
        ".tc-callout": {fontWeight: "600", color: "var(--tc-callout)"},
        ".tc-task-marker": {color: "var(--tc-secondary)"},
        ".tc-task-control": {width: "1em", height: "1em", margin: "0 .25em", verticalAlign: "-.1em", accentColor: "AccentColor"},
        ".tc-native-playback": {color: "var(--tc-primary)", backgroundColor: "var(--tc-playback)", borderRadius: "3px"},
        ".tc-native-search, .cm-searchMatch": {color: "var(--tc-primary)", backgroundColor: "var(--tc-search-match)", borderRadius: "2px"},
        ".cm-searchMatch-selected": {backgroundColor: "var(--tc-search-selected)"},
        ".tc-native-unresolvedLink": {textDecoration: "underline dotted", textDecorationColor: "var(--tc-secondary)"},
        ".tc-native-ambiguousLink": {textDecoration: "underline dotted", textDecorationColor: "var(--tc-warning)"},
        ".tc-focus-dim": {opacity: "var(--tc-focus-opacity)"},
        ".tc-transport-failure": {color: "var(--tc-error-text)", backgroundColor: "var(--tc-error-bg)", borderBottom: "1px solid var(--tc-error-border)", padding: "8px 12px"},
        ".cm-panel.cm-search [name=case], .cm-panel.cm-search [name=re], .cm-panel.cm-search [name=word]": {display: "inline-block"}
      })
    ]
  }

  private modeExtensions(): Extension[] {
    const editable = this.mode === "editedEditing" && !this.frozen
    return [
      // Edited view keeps the DOM non-editable but permits the intentional
      // task transaction and its CodeMirror Undo/Redo history. Original is
      // the only state-level immutable document.
      EditorState.readOnly.of(this.mode === "original"),
      EditorView.editable.of(editable),
      EditorView.editorAttributes.of({class: `tc-mode-${this.mode}${this.frozen ? " tc-frozen" : ""}`}),
      markdownDecorationPlugin(() => this.mode, () => this.mode !== "original" && !this.frozen, () => {
        this.taskHistoryOwnsInput = true
        this.reportFocus(this.view.contentDOM)
      }),
      focusDecorationPlugin(() => this.preferences.focusMode, () => this.mode),
      keymap.of(this.editorKeymap()),
      EditorView.domEventHandlers({
        mousedown: (event, view) => this.handleMouseDown(event, view),
        keydown: (event, view) => this.handleLinkKeyDown(event, view),
        focusin: event => { this.reportFocus(event.target); return false },
        focusout: () => { queueMicrotask(() => this.reportFocus(document.activeElement)); return false }
      })
    ]
  }

  private filterTransaction(transaction: Transaction): readonly TransactionSpec[] | Transaction {
    if (!transaction.docChanged) return transaction
    if (transaction.annotation(nativeChange)) return transaction
    if (this.frozen || this.mode === "original") return []
    if (this.mode === "editedEditing") return transaction
    if (transaction.annotation(taskChange) && this.isSingleTaskToggle(transaction)) return transaction
    if (this.taskHistoryOwnsInput && transaction.isUserEvent("undo") &&
        this.taskUndoDepth > 0 && this.isSingleTaskToggle(transaction)) return transaction
    if (this.taskHistoryOwnsInput && transaction.isUserEvent("redo") &&
        this.taskRedoDepth > 0 && this.isSingleTaskToggle(transaction)) return transaction
    return []
  }

  private isSingleTaskToggle(transaction: Transaction): boolean {
    let count = 0
    let valid = true
    transaction.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
      count++
      const replacement = inserted.toString()
      const marker = fromA > 0 && toA < transaction.startState.doc.length
        ? transaction.startState.sliceDoc(fromA - 1, toA + 1)
        : ""
      if (toA !== fromA + 1 || ![" ", "x", "X"].includes(replacement) || !/^\[[ xX]\]$/.test(marker)) {
        valid = false
      }
    })
    return count === 1 && valid
  }

  private appearanceExtensions(): Extension {
    const width = this.preferences.width === "narrow" ? "620px" : this.preferences.width === "wide" ? "800px" : "none"
    const alignment = this.mode === "original" ? "center" : this.preferences.editedAlignment
    const dark = this.appearance.colorScheme === "dark"
    const increased = this.appearance.increasedContrast
    const palette = dark ? {
      primary: "#f0f3f6", secondary: increased ? "#e6edf3" : "#b8c0cc",
      caret: "#ffffff", link: "#79c0ff", tag: "#d2a8ff", callout: "#79c0ff",
      comment: increased ? "#e6edf3" : "#b8c0cc", panel: "#25292e", control: "#30363d",
      border: increased ? "#f0f3f6" : "#6e7681", selection: increased ? "#174ea6" : "#264f78",
      codeBackground: "#2d333b", highlight: "#6e5a00", playback: "#234d70",
      searchMatch: "#735c0f", searchSelected: "#704700", warning: "#ffdf5d",
      errorText: "#ffd8d3", errorBackground: "#5a1d1d", errorBorder: "#ff7b72",
      activeLine: increased ? "#30363d" : "#25292e", bracket: "#2f6f44",
      badBracket: "#7d2626", focus: "#79c0ff"
    } : {
      primary: "#1f2328", secondary: increased ? "#24292f" : "#4b5563",
      caret: "#111827", link: "#0550ae", tag: "#6f42c1", callout: "#0550ae",
      comment: increased ? "#24292f" : "#4b5563", panel: "#f6f8fa", control: "#ffffff",
      border: increased ? "#1f2328" : "#6e7781", selection: increased ? "#80bfff" : "#b6d7ff",
      codeBackground: "#eef1f4", highlight: "#fff1a8", playback: "#cfe8ff",
      searchMatch: "#fff1a8", searchSelected: "#ffd33d", warning: "#8a4600",
      errorText: "#7d1111", errorBackground: "#ffebe9", errorBorder: "#cf222e",
      activeLine: increased ? "#eef1f4" : "#f6f8fa", bracket: "#c7f0d8",
      badBracket: "#ffd7d5", focus: "#0550ae"
    }
    return EditorView.theme({
      "&": {
        colorScheme: this.appearance.colorScheme,
        color: palette.primary,
        backgroundColor: "transparent",
        "--tc-primary": palette.primary,
        "--tc-secondary": palette.secondary,
        "--tc-caret": palette.caret,
        "--tc-link": palette.link,
        "--tc-tag": palette.tag,
        "--tc-callout": palette.callout,
        "--tc-comment": palette.comment,
        "--tc-panel": palette.panel,
        "--tc-control": palette.control,
        "--tc-border": palette.border,
        "--tc-selection": palette.selection,
        "--tc-code-bg": palette.codeBackground,
        "--tc-highlight": palette.highlight,
        "--tc-playback": palette.playback,
        "--tc-search-match": palette.searchMatch,
        "--tc-search-selected": palette.searchSelected,
        "--tc-warning": palette.warning,
        "--tc-error-text": palette.errorText,
        "--tc-error-bg": palette.errorBackground,
        "--tc-error-border": palette.errorBorder,
        "--tc-focus-opacity": increased ? "0.9" : "0.72"
      },
      ".cm-content": {
        fontSize: `${this.preferences.fontSize}px`,
        lineHeight: "1.55",
        maxWidth: width,
        boxSizing: "border-box",
        margin: "0 auto"
      },
      ".cm-line": {textAlign: alignment},
      ".tc-structured-line": {textAlign: "left"},
      ".tc-comment, .tc-task-marker": {opacity: "1"},
      ".cm-scroller": {scrollBehavior: this.appearance.reduceMotion ? "auto" : "smooth"},
      ".cm-activeLine": {backgroundColor: palette.activeLine},
      ".cm-matchingBracket": {backgroundColor: palette.bracket, outline: `1px solid ${palette.focus}`},
      ".cm-nonmatchingBracket": {backgroundColor: palette.badBracket, outline: `1px solid ${palette.errorBorder}`},
      ".cm-dropCursor": {borderLeftColor: palette.caret},
      ".cm-cursor, .cm-dropCursor": {borderLeftColor: palette.caret},
      ".cm-searchMatch-selected": {color: palette.primary, backgroundColor: palette.searchSelected},
      "&.cm-focused": {outline: `${increased ? 2 : 1}px solid ${palette.focus}`, outlineOffset: "-2px"},
      ".tc-native-spokenWord": {color: palette.primary, textDecoration: `underline 2px ${palette.focus}`},
      ".tc-native-speaker": {color: palette.secondary, fontWeight: "600"},
      ".tc-task-control": {colorScheme: this.appearance.colorScheme, outlineColor: palette.focus},
      ...(this.mode === "editedEditing" ? {} : {
        ".cm-panel.cm-search [name=replace], .cm-panel.cm-search button[name=replace], .cm-panel.cm-search button[name=replaceAll]": {display: "none"}
      })
    }, {dark})
  }

  private editorKeymap(): Parameters<typeof keymap.of>[0] {
    const editableOnly = (command: Command): Command => view => this.mode === "editedEditing" && !this.frozen && command(view)
    const listOnly = (command: Command): Command => view => this.mode === "editedEditing" && !this.frozen && this.everySelectionInList() && command(view)
    return [
      {key: "Mod-b", run: editableOnly(toggleDelimiter("**"))},
      {key: "Mod-i", run: editableOnly(toggleDelimiter("*"))},
      {key: "Mod-k", run: editableOnly(toggleLink)},
      {key: "Enter", run: editableOnly(continueMarkupWithQuoteExit)},
      {key: "Tab", run: listOnly(indentMore)},
      {key: "Shift-Tab", run: listOnly(indentLess)},
      {key: "Mod-f", run: openSearchPanel},
      {key: "Mod-Alt-f", run: editableOnly(openSearchPanel)},
      {key: "Mod-+", run: () => this.adjustFont(1)},
      {key: "Mod-=", run: () => this.adjustFont(1)},
      {key: "Mod--", run: () => this.adjustFont(-1)},
      {key: "Mod-0", run: () => this.setFont(16)},
      ...searchKeymap,
      ...historyKeymap,
      ...defaultKeymap
    ]
  }

  private everySelectionInList(): boolean {
    return this.view.state.selection.ranges.every(range => {
      const lastPosition = Math.max(range.from, range.to - 1)
      const firstLine = this.view.state.doc.lineAt(range.from).number
      const lastLine = this.view.state.doc.lineAt(lastPosition).number
      for (let lineNumber = firstLine; lineNumber <= lastLine; lineNumber++) {
        const line = this.view.state.doc.line(lineNumber)
        const probe = Math.min(line.to, Math.max(line.from, range.from))
        let node = syntaxTree(this.view.state).resolveInner(probe, 1)
        let listItem = false
        while (node) {
          if (node.name === "ListItem") { listItem = true; break }
          if (!node.parent) break
          node = node.parent
        }
        if (!listItem) return false
      }
      return true
    })
  }

  private didUpdate(update: ViewUpdate): void {
    if (update.selectionSet && !update.transactions.some(transaction => transaction.annotation(nativeChange))) {
      this.scheduleViewStateReport(0)
    }
    if (!update.docChanged) return
    for (const transaction of update.transactions) {
      if (!transaction.docChanged || transaction.annotation(nativeChange)) continue
      if (transaction.annotation(taskChange)) {
        this.taskUndoDepth++
        this.taskRedoDepth = 0
      } else if (transaction.isUserEvent("undo") && this.taskHistoryOwnsInput) {
        this.taskUndoDepth = Math.max(0, this.taskUndoDepth - 1)
        this.taskRedoDepth++
      } else if (transaction.isUserEvent("redo") && this.taskHistoryOwnsInput) {
        this.taskRedoDepth = Math.max(0, this.taskRedoDepth - 1)
        this.taskUndoDepth++
      }
      const exactBeforeLength = this.exactMap.exactLength
      const combinedChanges: Array<{from: number, to: number, fromB: number, toB: number}> = []
      transaction.changes.iterChanges((fromA, toA, fromB, toB) => combinedChanges.push({
        from: this.exactMap.internalToExternal(fromA),
        to: this.exactMap.internalToExternal(toA),
        fromB,
        toB
      }))
      this.exactMap.applyDeltas(this.exactMap.deltas(transaction))
      for (const effect of transaction.effects) {
        if (!effect.is(exactSeparatorTarget)) continue
        for (const separator of effect.value.separators) {
          if (transaction.state.doc.sliceString(separator.position, separator.position + 1) !== "\n") {
            this.handleTransportFailure("Mapped exact separator no longer targets a line break")
            return
          }
          this.exactMap.setSeparator(separator.position, separator.value)
        }
      }
      const exactChanges = combinedChanges.map(change => ({
        from: change.from,
        to: change.to,
        insert: this.exactMap.exactSlice(transaction.state.doc, change.fromB, change.toB)
      }))
      if (this.mode === "original") this.originalExactMap = this.exactMap
      else this.editedExactMap = this.exactMap
      if (this.composing) {
        if (!this.compositionPieces) {
          this.compositionBaseLength = exactBeforeLength
          this.compositionPieces = [{kind: "original", from: 0, to: exactBeforeLength}]
        }
        applyCompositionPatches(this.compositionPieces, exactChanges)
        continue
      }
      const started = this.lastInputStarted ?? performance.now()
      this.lastInputStarted = undefined
      void this.sendPatchBatch(
        {
          baseLength: exactBeforeLength,
          intent: transaction.annotation(taskChange)
            ? "task"
            : transaction.isUserEvent("undo") || transaction.isUserEvent("redo")
              ? "history"
              : "text",
          changes: exactChanges
        },
        "patch-rejected"
      )
      requestAnimationFrame(() => this.recordLatency(performance.now() - started))
    }
  }

  private recordLatency(duration: number): void {
    this.latencySamples.push(duration)
    if (this.latencySamples.length < 200) return
    const maximum = Math.max(...this.latencySamples)
    void this.bridge.send("performance", {
      kind: "input",
      sampleCount: this.latencySamples.length,
      p95Milliseconds: percentile95(this.latencySamples),
      maximumMilliseconds: maximum,
      documentLength: this.view.state.doc.length,
      targetMet: percentile95(this.latencySamples) < 16.7 && maximum < 50
    })
    this.latencySamples = []
  }

  private installCompositionObservers(): void {
    this.view.contentDOM.addEventListener("compositionstart", () => {
      this.composing = true
      this.compositionBaseLength = this.exactMap.exactLength
      this.compositionPieces = [{kind: "original", from: 0, to: this.compositionBaseLength}]
      this.reportFocus(this.view.contentDOM)
    })
    this.view.contentDOM.addEventListener("compositionend", () => {
      this.composing = false
      if (this.compositionPieces) {
        const exactChanges = compositionPatches(this.compositionPieces, this.compositionBaseLength)
        if (exactChanges.length) {
        void this.sendPatchBatch(
          {
            baseLength: this.compositionBaseLength,
            intent: "text",
            changes: exactChanges
          },
          "composition-patch-rejected"
        )
        }
      }
      this.compositionPieces = undefined
      for (const resolve of this.compositionWaiters.splice(0)) resolve()
      this.reportFocus(this.view.contentDOM)
    })
  }

  private async sendPatchBatch(payload: PatchPayload, snapshotReason: string): Promise<void> {
    const reply = await this.bridge.send("patches", payload)
    if (!reply.ok) return
    if (!validatePatchAcknowledgement(reply.result)) {
      throw new Error("Native returned a malformed patch acknowledgement")
    }
    if (!reply.result.accepted) await this.sendSnapshot(snapshotReason)
  }

  private reportFocus(target: EventTarget | null): void {
    const element = target instanceof Element ? target : null
    if (!element?.closest?.(".cm-editor")) this.clearTaskHistoryOwnership()
    const searchInput = !!element?.closest?.(".cm-search") && (element.matches("input,textarea") || !!element.closest("input,textarea"))
    const editorInput = this.view.hasFocus && this.mode === "editedEditing" && !this.frozen
    void this.bridge.send("focusOwnership", {
      owner: searchInput ? "search" : editorInput ? "editor" : "application",
      acceptsTextInput: searchInput || editorInput,
      historyOwnership: this.taskHistoryOwnsInput,
      composing: this.composing,
      mode: this.mode
    })
  }

  private scheduleViewStateReport(delayMilliseconds: number): void {
    if (this.viewStateReportTimer !== undefined) clearTimeout(this.viewStateReportTimer)
    this.viewStateReportTimer = setTimeout(() => {
      this.viewStateReportTimer = undefined
      void this.reportViewState()
    }, delayMilliseconds)
  }

  private async reportViewState(): Promise<void> {
    if (this.viewStateReportInFlight) {
      this.viewStateReportQueued = true
      return
    }
    this.viewStateReportInFlight = true
    try {
      await this.bridge.send("viewState", this.currentViewState())
    } finally {
      this.viewStateReportInFlight = false
      if (this.viewStateReportQueued) {
        this.viewStateReportQueued = false
        this.scheduleViewStateReport(0)
      }
    }
  }

  private clearTaskHistoryOwnership(): void {
    this.taskHistoryOwnsInput = false
    this.taskUndoDepth = 0
    this.taskRedoDepth = 0
  }

  private linkAt(position: number): LinkActionPayload | undefined {
    if (markdownPositionIsInert(this.view.state, position) || obsidianCommentAt(this.view.state, position)) {
      return undefined
    }
    const line = this.view.state.doc.lineAt(position)
    for (const match of line.text.matchAll(/\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]/gu)) {
      const from = line.from + match.index
      const to = from + match[0].length
      if (from > line.from && this.view.state.sliceDoc(from - 1, from) === "!") continue
      if (position >= from && position < to) return {kind: "wikilink", target: match[1] ?? "", alias: match[2] ?? null, from, to}
    }
    for (const match of line.text.matchAll(/(?<!!)\[([^\]\n]*)\]\(([^)\n]*)\)/gu)) {
      const from = line.from + match.index
      const to = from + match[0].length
      if (position >= from && position < to) return {kind: "markdownLink", label: match[1] ?? "", destination: match[2] ?? "", from, to}
    }
    return undefined
  }

  private handleMouseDown(event: MouseEvent, view: EditorView): boolean {
    if (event.button !== 0) return false
    const position = view.posAtCoords({x: event.clientX, y: event.clientY})
    if (position == null) return false
    if (event.metaKey) {
      const link = this.linkAt(position)
      if (!link) return false
      event.preventDefault()
      void this.bridge.send("linkAction", {
        ...link,
        from: this.exactMap.internalToExternal(link.from as number),
        to: this.exactMap.internalToExternal(link.to as number)
      })
      return true
    }
    if (this.mode === "original") {
      void this.bridge.send("clickAction", {
        kind: "originalPosition",
        position: this.exactMap.internalToExternal(position)
      })
      return false
    }
    if (this.mode === "editedView" && !(event.target instanceof Element && event.target.closest(".tc-task-control"))) {
      event.preventDefault()
      void this.bridge.send("clickAction", {
        kind: "enterEditing",
        position: this.exactMap.internalToExternal(position)
      })
      return true
    }
    return false
  }

  private handleLinkKeyDown(event: KeyboardEvent, view: EditorView): boolean {
    if (!(event.metaKey && event.key === "Enter")) return false
    const link = this.linkAt(view.state.selection.main.head)
    if (!link) return false
    event.preventDefault()
    void this.bridge.send("linkAction", {
      ...link,
      from: this.exactMap.internalToExternal(link.from as number),
      to: this.exactMap.internalToExternal(link.to as number)
    })
    return true
  }

  private adjustFont(delta: number): boolean { return this.setFont(this.preferences.fontSize + delta) }
  private setFont(size: number): boolean {
    const clamped = Math.max(12, Math.min(28, size))
    void this.bridge.send("preferenceAction", {kind: "fontSize", value: clamped})
    return true
  }

  private currentViewState(): ViewStatePayload {
    return {
      selection: this.view.state.selection.ranges.map(range => ({
        anchor: this.exactMap.internalToExternal(range.anchor),
        head: this.exactMap.internalToExternal(range.head)
      })),
      mainSelectionIndex: this.view.state.selection.mainIndex,
      scrollTop: this.view.scrollDOM.scrollTop
    }
  }

  private async sendSnapshot(reason: string): Promise<SnapshotPayload> {
    if (this.composing) {
      await new Promise<void>(resolve => this.compositionWaiters.push(resolve))
    }
    const payload = {text: this.exactText, mode: this.mode, viewState: this.currentViewState(), reason}
    const reply = await this.bridge.send("snapshot", payload)
    if (!reply.ok) throw new Error(reply.error ?? "Snapshot was not acknowledged")
    return payload
  }

  private setMode(mode: EditorMode): void {
    this.mode = mode
    this.reconfigureEditor()
  }

  private reconfigureEditor(): void {
    const searchWasOpen = searchPanelOpen(this.view.state)
    this.view.dispatch({effects: [
      this.modeCompartment.reconfigure(this.modeExtensions()),
      this.appearanceCompartment.reconfigure(this.appearanceExtensions())
    ], annotations: nativeChange.of(true)})
    if (searchWasOpen) {
      closeSearchPanel(this.view)
      openSearchPanel(this.view)
    }
  }

  private configure(payload: unknown): void {
    if (!isRecord(payload)) throw new TypeError("Invalid configuration payload")
    if (payload.mode !== undefined && !validMode(payload.mode)) throw new TypeError("Invalid editor mode")
    if (payload.preferences !== undefined) {
      if (!isRecord(payload.preferences)) throw new TypeError("Invalid preferences")
      const fontSize = payload.preferences.fontSize
      const width = payload.preferences.width
      const editedAlignment = payload.preferences.editedAlignment
      const focusMode = payload.preferences.focusMode
      if (!Number.isFinite(fontSize) || (fontSize as number) < 12 || (fontSize as number) > 28 ||
          (width !== "narrow" && width !== "wide" && width !== "full") ||
          (editedAlignment !== "center" && editedAlignment !== "left") || typeof focusMode !== "boolean") {
        throw new TypeError("Invalid editor preferences")
      }
      this.preferences = {...defaultPreferences, ...payload.preferences} as EditorPreferences
    }
    if (payload.appearance !== undefined) {
      if (!isRecord(payload.appearance) ||
          (payload.appearance.colorScheme !== "light" && payload.appearance.colorScheme !== "dark") ||
          typeof payload.appearance.increasedContrast !== "boolean" ||
          typeof payload.appearance.reduceMotion !== "boolean") {
        throw new TypeError("Invalid editor appearance")
      }
      this.appearance = {
        colorScheme: payload.appearance.colorScheme,
        increasedContrast: payload.appearance.increasedContrast,
        reduceMotion: payload.appearance.reduceMotion
      }
    }
    if (payload.mode !== undefined && payload.mode !== this.mode) this.clearTaskHistoryOwnership()
    if (payload.mode !== undefined) this.mode = payload.mode
    this.reconfigureEditor()
    this.reportFocus(globalThis.document.activeElement)
  }

  private replaceDocument(payload: unknown): void {
    if (!isRecord(payload) || typeof payload.text !== "string" || !validMode(payload.mode)) throw new TypeError("Invalid document payload")
    const document = payload as unknown as DocumentPayload
    const ranges = clampedSelection(document.selection, document.text)
    const incomingMap = new ExactTextIndex(document.text)
    const normalizedDocument = normalizeExactText(document.text)
    const normalizedDocumentView = {
      length: normalizedDocument.length,
      sliceString: (from: number, to?: number) => normalizedDocument.slice(from, to)
    }
    const selection = ranges ? selectionFrom(ranges.map(range => ({
      anchor: incomingMap.externalToInternal(range.anchor, normalizedDocumentView),
      head: incomingMap.externalToInternal(range.head, normalizedDocumentView)
    })), document.mainSelectionIndex ?? 0) : undefined
    const previousMode = this.mode
    this.clearTaskHistoryOwnership()
    if (document.resetHistory) {
      this.taskUndoDepth = 0
      this.taskRedoDepth = 0
    }
    if (previousMode === "original") {
      this.originalState = this.view.state
      this.originalExactMap = this.exactMap
    } else {
      this.editedState = this.view.state
      this.editedExactMap = this.exactMap
    }
    this.mode = document.mode
    this.exactMap = incomingMap
    if (document.resetHistory) {
      this.view.setState(this.createState(
        document.text,
        selection ?? selectionFrom([{anchor: 0, head: 0}])
      ))
    } else {
      const saved = document.mode === "original" ? this.originalState : this.editedState
      const savedExact = document.mode === "original" ? this.originalExactMap : this.editedExactMap
      if (saved && savedExact && saved.doc.toString() === normalizedDocument &&
          savedExact.exactText(saved.doc) === document.text && previousMode !== document.mode) {
        this.exactMap = savedExact
        this.view.setState(saved)
        this.view.dispatch({
          ...(selection ? {selection} : {}),
          effects: [
            this.modeCompartment.reconfigure(this.modeExtensions()),
            this.appearanceCompartment.reconfigure(this.appearanceExtensions())
          ],
          annotations: nativeChange.of(true)
        })
      } else {
        this.view.dispatch({
          changes: {from: 0, to: this.view.state.doc.length, insert: document.text},
          ...(selection ? {selection} : {}),
          effects: [
            this.modeCompartment.reconfigure(this.modeExtensions()),
            this.appearanceCompartment.reconfigure(this.appearanceExtensions())
          ],
          annotations: [nativeChange.of(true), Transaction.addToHistory.of(false)]
        })
      }
    }
    if (document.mode === "original") {
      this.originalState = this.view.state
      this.originalExactMap = this.exactMap
    } else {
      this.editedState = this.view.state
      this.editedExactMap = this.exactMap
    }
    if (typeof document.scrollTop === "number" && Number.isFinite(document.scrollTop)) {
      requestAnimationFrame(() => {
        this.programmaticScroll = true
        this.view.scrollDOM.scrollTop = Math.max(0, document.scrollTop ?? 0)
        requestAnimationFrame(() => { this.programmaticScroll = false })
      })
    }
    this.reportFocus(globalThis.document.activeElement)
  }

  private restoreViewState(payload: unknown): void {
    if (!isRecord(payload)) throw new TypeError("Invalid view state")
    const ranges = clampedSelection(payload.selection, this.exactText)
    if (!ranges) throw new TypeError("Invalid view-state selection")
    const main = Number.isSafeInteger(payload.mainSelectionIndex) ? payload.mainSelectionIndex as number : 0
    this.view.dispatch({selection: selectionFrom(ranges.map(range => ({
      anchor: this.exactMap.externalToInternal(range.anchor, this.view.state.doc),
      head: this.exactMap.externalToInternal(range.head, this.view.state.doc)
    })), main), annotations: nativeChange.of(true)})
    if (typeof payload.scrollTop === "number" && Number.isFinite(payload.scrollTop)) {
      requestAnimationFrame(() => {
        this.programmaticScroll = true
        this.view.scrollDOM.scrollTop = Math.max(0, payload.scrollTop as number)
        requestAnimationFrame(() => { this.programmaticScroll = false })
      })
    }
  }

  private applyExternalChanges(payload: unknown): {text: string, length: number} {
    if (!isRecord(payload) || !validMode(payload.mode) || payload.mode !== this.mode ||
        !Array.isArray(payload.changes)) throw new TypeError("Invalid external-change payload")
    const exactBefore = this.exactText
    const rawChanges = payload.changes
    const patches = rawChanges.map(value => {
      if (!isRecord(value) || Object.keys(value).sort().join(",") !== "from,insert,to" ||
          !Number.isSafeInteger(value.from) || !Number.isSafeInteger(value.to) || typeof value.insert !== "string") {
        throw new TypeError("Invalid external patch")
      }
      return {from: value.from as number, to: value.to as number, insert: value.insert}
    })
    if (!validatePatches(exactBefore.length, patches) || patches.some(patch =>
      validUTF16Boundary(exactBefore, patch.from) !== patch.from ||
      validUTF16Boundary(exactBefore, patch.to) !== patch.to
    )) throw new RangeError("Invalid external patch range")

    const deltas: ExactDelta[] = patches.map(patch => ({
      ...patch,
      internalFrom: this.exactMap.externalToInternal(patch.from, this.view.state.doc),
      internalTo: this.exactMap.externalToInternal(patch.to, this.view.state.doc),
      removed: exactBefore.slice(patch.from, patch.to)
    }))
    let previousInternalTo = 0
    for (const delta of deltas) {
      if (this.exactMap.internalToExternal(delta.internalFrom) !== delta.from ||
          this.exactMap.internalToExternal(delta.internalTo) !== delta.to ||
          delta.internalFrom < previousInternalTo || delta.internalTo < delta.internalFrom) {
        throw new RangeError("External patches must preserve complete line-separator atoms")
      }
      previousInternalTo = delta.internalTo
    }
    const transaction = this.view.state.update({
      changes: deltas.map(delta => ({
        from: delta.internalFrom,
        to: delta.internalTo,
        insert: normalizeExactText(delta.insert)
      })),
      annotations: [nativeChange.of(true), Transaction.addToHistory.of(false)]
    })
    this.view.dispatch(transaction)
    this.exactMap.applyDeltas(deltas)
    if (this.mode === "original") this.originalExactMap = this.exactMap
    else this.editedExactMap = this.exactMap
    const text = this.exactText
    return {text, length: text.length}
  }

  private executeCommand(payload: unknown): boolean {
    if (!isRecord(payload) || typeof payload.command !== "string") throw new TypeError("Invalid command payload")
    const historyAllowed = !this.frozen && this.mode === "editedEditing"
    const commands: Record<string, Command> = {
      undo: view => (historyAllowed || (this.mode === "editedView" && this.taskHistoryOwnsInput && this.taskUndoDepth > 0)) && undo(view),
      redo: view => (historyAllowed || (this.mode === "editedView" && this.taskHistoryOwnsInput && this.taskRedoDepth > 0)) && redo(view),
      openFind: openSearchPanel, closeFind: closeSearchPanel,
      findNext, findPrevious,
      replaceNext: view => this.mode === "editedEditing" && !this.frozen && replaceNext(view),
      replaceAll: view => this.mode === "editedEditing" && !this.frozen && replaceAll(view),
      bold: view => this.mode === "editedEditing" && !this.frozen && toggleDelimiter("**")(view),
      italic: view => this.mode === "editedEditing" && !this.frozen && toggleDelimiter("*")(view),
      link: view => this.mode === "editedEditing" && !this.frozen && toggleLink(view)
    }
    const command = commands[payload.command]
    if (!command) return false
    return command(this.view)
  }

  private async handleNativeEnvelope<M extends NativeMethod>(
    message: NativeEnvelope<M>
  ): Promise<NativeReplyMap[M]> {
    // TypeScript cannot retain the correlation while indexing a mapped type
    // with a generic key, so this single adapter cast reconnects the method's
    // exact payload and reply. `nativeHandlers` itself is exhaustively checked
    // against NativeHandlerMap above.
    const handler = this.nativeHandlers[message.method] as NativeMethodHandler<M>
    return await handler(message.payload)
  }

  async ready(): Promise<void> {
    const loadToken = new URLSearchParams(window.location.hash.slice(1)).get("load")
    if (!loadToken) throw new Error("Missing native editor load token")
    await this.bridge.send("ready", {
      protocolVersion: 1,
      loadToken,
      utf16Coordinates: true,
      modes: ["original", "editedView", "editedEditing"],
      capabilities: ["patches", "snapshots", "viewState", "search", "replace", "tasks", "formatting", "performance"]
    })
  }

  diagnostics(): {searchCountScanCount: number} { return {searchCountScanCount} }

  destroy(): void { this.view.destroy() }
}
