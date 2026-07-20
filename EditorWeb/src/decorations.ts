import {syntaxTree} from "@codemirror/language"
import {isolateHistory} from "@codemirror/commands"
import {
  Annotation,
  RangeSet,
  RangeValue,
  StateEffect,
  StateField,
  Transaction,
  type EditorState,
  type Extension,
  type Range
} from "@codemirror/state"
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
  WidgetType
} from "@codemirror/view"
import type {EditorMode, NativeDecoration} from "./protocol"

export const setStableDecorations = StateEffect.define<readonly NativeDecoration[]>()
export const setPlaybackDecoration = StateEffect.define<NativeDecoration | null>()
export const taskChange = Annotation.define<boolean>()

function decorationSet(
  decorations: readonly NativeDecoration[],
  documentLength: number
): DecorationSet {
  return Decoration.set(decorations
    .filter(item => item.from >= 0 && item.to >= item.from && item.to <= documentLength)
    .map(item => Decoration.mark({class: `tc-native-${item.kind}`, attributes: {
      "data-native-kind": item.kind,
      "data-native-payload": JSON.stringify(item.data ?? {}),
      ...(typeof item.data?.tooltip === "string" ? {title: item.data.tooltip} : {})
    }}).range(item.from, item.to)), true)
}

export const stableNativeDecorations = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    value = value.map(transaction.changes)
    for (const effect of transaction.effects) {
      if (effect.is(setStableDecorations)) value = decorationSet(effect.value, transaction.state.doc.length)
    }
    return value
  },
  provide: field => EditorView.decorations.from(field)
})

export const playbackNativeDecoration = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    value = value.map(transaction.changes)
    for (const effect of transaction.effects) {
      if (effect.is(setPlaybackDecoration)) {
        value = decorationSet(effect.value ? [effect.value] : [], transaction.state.doc.length)
      }
    }
    return value
  },
  provide: field => EditorView.decorations.from(field)
})

class TaskWidget extends WidgetType {
  constructor(
    readonly markerFrom: number,
    readonly checked: boolean,
    readonly label: string,
    readonly mode: EditorMode,
    readonly canToggle: boolean,
    readonly onHistoryOwnership: () => void
  ) { super() }

  eq(other: TaskWidget): boolean {
    return this.markerFrom === other.markerFrom && this.checked === other.checked &&
      this.label === other.label && this.mode === other.mode && this.canToggle === other.canToggle
  }

  toDOM(view: EditorView): HTMLElement {
    const checkbox = document.createElement("input")
    checkbox.type = "checkbox"
    checkbox.checked = this.checked
    checkbox.disabled = !this.canToggle
    checkbox.className = "tc-task-control"
    checkbox.setAttribute("aria-label", this.label ? `Task: ${this.label}` : "Task")
    checkbox.addEventListener("mousedown", event => event.stopPropagation())
    checkbox.addEventListener("click", event => {
      event.preventDefault()
      event.stopPropagation()
      if (!this.canToggle) return
      const current = view.state.sliceDoc(this.markerFrom, this.markerFrom + 3)
      if (!/^\[[ xX]\]$/.test(current)) return
      view.dispatch({
        changes: {from: this.markerFrom + 1, to: this.markerFrom + 2, insert: this.checked ? " " : "x"},
        annotations: [
          taskChange.of(true),
          isolateHistory.of("full"),
          Transaction.userEvent.of("input.task")
        ]
      })
      this.onHistoryOwnership()
      view.focus()
    })
    return checkbox
  }

  ignoreEvent(): boolean { return false }
}

const nodeClasses: Record<string, string> = {
  ATXHeading1: "tc-heading tc-heading-1",
  ATXHeading2: "tc-heading tc-heading-2",
  ATXHeading3: "tc-heading tc-heading-3",
  ATXHeading4: "tc-heading tc-heading-4",
  ATXHeading5: "tc-heading tc-heading-5",
  ATXHeading6: "tc-heading tc-heading-6",
  SetextHeading1: "tc-heading tc-heading-1",
  SetextHeading2: "tc-heading tc-heading-2",
  Emphasis: "tc-emphasis",
  StrongEmphasis: "tc-strong",
  Strikethrough: "tc-strikethrough",
  InlineCode: "tc-inline-code",
  FencedCode: "tc-code-block",
  CodeBlock: "tc-code-block",
  Blockquote: "tc-blockquote",
  Link: "tc-link",
  Autolink: "tc-link",
  URL: "tc-link",
  Table: "tc-table",
  TableHeader: "tc-table tc-table-header",
  TableRow: "tc-table",
  TableCell: "tc-table",
  TableDelimiter: "tc-table tc-table-delimiter",
  HorizontalRule: "tc-rule",
  BulletList: "tc-list tc-unordered-list",
  OrderedList: "tc-list tc-ordered-list"
}

function addRegexMarks(
  text: string,
  offset: number,
  expression: RegExp,
  className: string,
  output: Range<Decoration>[],
  excluded: readonly SourceRange[] = [],
  include: (from: number, to: number) => boolean = () => true
): void {
  for (const match of text.matchAll(expression)) {
    const start = offset + match.index
    const end = start + match[0].length
    if (!overlapsAny(start, end, excluded) && include(start, end)) {
      output.push(Decoration.mark({class: className}).range(start, end))
    }
  }
}

export interface SourceRange {from: number, to: number}

const inertSyntaxNodes = new Set([
  "InlineCode", "FencedCode", "CodeBlock", "CodeText",
  "Comment", "CommentBlock", "HTMLBlock", "HTMLTag"
])

const structuredSyntaxNodes = new Set([
  "ListItem", "BulletList", "OrderedList", "Blockquote",
  "FencedCode", "CodeBlock", "Table"
])

function overlapsAny(from: number, to: number, ranges: readonly SourceRange[]): boolean {
  return ranges.some(range => from < range.to && to > range.from)
}

function mergedRanges(ranges: readonly SourceRange[]): SourceRange[] {
  const sorted = [...ranges].sort((left, right) => left.from - right.from || left.to - right.to)
  const merged: SourceRange[] = []
  for (const range of sorted) {
    const previous = merged.at(-1)
    if (previous && range.from <= previous.to) previous.to = Math.max(previous.to, range.to)
    else merged.push({...range})
  }
  return merged
}

function scanInlineRawHTMLRanges(
  state: EditorState,
  from: number,
  to: number,
  diagnostics?: ObsidianCommentDiagnostics
): SourceRange[] {
  const firstLine = state.doc.lineAt(from).number
  const lastLine = state.doc.lineAt(Math.max(from, to - 1)).number
  const ranges: SourceRange[] = []
  for (let lineNumber = firstLine; lineNumber <= lastLine; lineNumber++) {
    const line = state.doc.line(lineNumber)
    if (diagnostics) diagnostics.scannedUTF16 += line.length
    const stack: Array<{name: string, from: number}> = []
    for (const match of line.text.matchAll(/<\/?([A-Za-z][\w:-]*)\b[^>]*>/gu)) {
      const start = line.from + match.index
      const end = start + match[0].length
      const name = (match[1] ?? "").toLowerCase()
      if (match[0].startsWith("</")) {
        const openIndex = stack.findLastIndex(item => item.name === name)
        if (openIndex >= 0) {
          const [open] = stack.splice(openIndex, 1)
          if (open) ranges.push({from: open.from, to: end})
        } else ranges.push({from: start, to: end})
      } else if (match[0].endsWith("/>") || /^(?:br|hr|img|input|meta|link)$/u.test(name)) {
        ranges.push({from: start, to: end})
      } else {
        stack.push({name, from: start})
      }
    }
    for (const open of stack) ranges.push({from: open.from, to: line.to})
  }
  return mergedRanges(ranges)
}

class InlineRawHTMLInterval extends RangeValue {
  startSide = 1
  endSide = -1
}
const inlineRawHTMLInterval = new InlineRawHTMLInterval()

function rangeSetOverlaps<T extends RangeValue>(set: RangeSet<T>, from: number, to: number): boolean {
  let found = false
  const queryFrom = from === to ? Math.max(0, from - 1) : from
  const queryTo = from === to ? from + 1 : to
  set.between(queryFrom, queryTo, (start, end) => {
    if (from === to ? from > start && from < end : from < end && to > start) found = true
  })
  return found
}

function inlineHTMLRanges(
  ranges: RangeSet<InlineRawHTMLInterval>,
  from: number,
  to: number
): SourceRange[] {
  const result: SourceRange[] = []
  ranges.between(from, to, (start, end) => {
    if (start < to && end > from) result.push({from: start, to: end})
  })
  return result
}

function positionIsInert(
  state: EditorState,
  position: number,
  rawHTML: RangeSet<InlineRawHTMLInterval>
): boolean {
  let node = syntaxTree(state).resolveInner(Math.max(0, Math.min(state.doc.length, position)), -1)
  while (node) {
    if (inertSyntaxNodes.has(node.name)) return true
    if (!node.parent) break
    node = node.parent
  }
  return position < state.doc.length && rangeSetOverlaps(rawHTML, position, position + 1)
}

export function markdownPositionIsInert(state: EditorState, position: number): boolean {
  const cached = state.field(obsidianComments, false)?.inlineHTML
  if (cached) return positionIsInert(state, position, cached)
  const line = state.doc.lineAt(position)
  const fallback = RangeSet.of(scanInlineRawHTMLRanges(state, line.from, line.to)
    .map(range => inlineRawHTMLInterval.range(range.from, range.to)))
  return positionIsInert(state, position, fallback)
}

class ObsidianCommentToken extends RangeValue {}
class ObsidianCommentInterval extends RangeValue {}
class ClosedObsidianCommentInterval extends ObsidianCommentInterval {
  /// Text inserted immediately after %% belongs to following source, not to
  /// the closed comment whose mapped range ends at that boundary.
  endSide = -1
}
class OpenObsidianCommentInterval extends ObsidianCommentInterval {
  /// The default end affinity deliberately grows an unmatched comment when
  /// text is appended at the document end.
  endSide = 0
}
const commentToken = new ObsidianCommentToken()
const closedCommentInterval = new ClosedObsidianCommentInterval()
const openCommentInterval = new OpenObsidianCommentInterval()

export interface ObsidianCommentDiagnostics {
  scannedUTF16: number
  delimiterVisits: number
  invalidatedUTF16: number
  literalDelimiterCount: number
  activeDelimiterCount: number
  rebuiltAllIntervals: boolean
  syntaxExpanded: boolean
}

interface ObsidianCommentIndex {
  /// Every literal %% delimiter, including delimiters currently made inert by
  /// Markdown syntax. Keeping these mapped lets a fence close reactivate
  /// comments without rescanning the text hidden behind the old fence.
  literals: RangeSet<ObsidianCommentToken>
  active: RangeSet<ObsidianCommentToken>
  intervals: RangeSet<ObsidianCommentInterval>
  inlineHTML: RangeSet<InlineRawHTMLInterval>
  diagnostics: ObsidianCommentDiagnostics
}

function scanLiteralCommentTokens(
  state: EditorState,
  range: SourceRange,
  diagnostics: ObsidianCommentDiagnostics
): Range<ObsidianCommentToken>[] {
  const tokens: Range<ObsidianCommentToken>[] = []
  const from = Math.max(0, range.from)
  const to = Math.min(state.doc.length, range.to)
  if (to <= from) return tokens
  const source = state.sliceDoc(from, to)
  diagnostics.scannedUTF16 += to - from
  for (const match of source.matchAll(/%%/gu)) {
    const position = from + match.index
    tokens.push(commentToken.range(position, position + 2))
  }
  return tokens
}

function activeTokensFromLiterals(
  state: EditorState,
  literals: RangeSet<ObsidianCommentToken>,
  inlineHTML: RangeSet<InlineRawHTMLInterval>,
  range: SourceRange,
  diagnostics: ObsidianCommentDiagnostics
): Range<ObsidianCommentToken>[] {
  const active: Range<ObsidianCommentToken>[] = []
  literals.between(range.from, range.to, (from, to) => {
    diagnostics.delimiterVisits += 1
    if (!positionIsInert(state, from, inlineHTML)) active.push(commentToken.range(from, to))
  })
  return active.sort((left, right) => left.from - right.from)
}

function tokenBounds(
  tokens: RangeSet<ObsidianCommentToken>,
  range: SourceRange
): Array<readonly [number, number]> {
  const bounds: Array<readonly [number, number]> = []
  tokens.between(range.from, range.to, (from, to) => { bounds.push([from, to]) })
  return bounds.sort((left, right) => left[0] - right[0] || left[1] - right[1])
}

function equalBounds(
  left: readonly (readonly [number, number])[],
  right: readonly (readonly [number, number])[]
): boolean {
  return left.length === right.length && left.every((bounds, index) =>
    bounds[0] === right[index]?.[0] && bounds[1] === right[index]?.[1])
}

function commentIntervals(
  tokens: RangeSet<ObsidianCommentToken>,
  documentLength: number,
  diagnostics: ObsidianCommentDiagnostics
): RangeSet<ObsidianCommentInterval> {
  const intervals: Range<ObsidianCommentInterval>[] = []
  const cursor = tokens.iter()
  let open: number | undefined
  while (cursor.value) {
    diagnostics.delimiterVisits += 1
    if (open === undefined) open = cursor.from
    else {
      intervals.push(closedCommentInterval.range(open, Math.min(documentLength, cursor.to)))
      open = undefined
    }
    cursor.next()
  }
  if (open !== undefined && documentLength > open) {
    intervals.push(openCommentInterval.range(open, documentLength))
  }
  return RangeSet.of(intervals)
}

function topLevelSyntaxRange(state: EditorState, from: number, to: number): SourceRange {
  const at = (position: number, bias: -1 | 1) => {
    const clamped = Math.max(0, Math.min(state.doc.length, position))
    let node = syntaxTree(state).resolveInner(clamped, bias)
    while (node.parent && node.parent.name !== "Document") node = node.parent
    return node.name === "Document" ? {from: clamped, to: clamped} : {from: node.from, to: node.to}
  }
  const boundaries = [
    at(from, -1), at(from, 1),
    at(Math.max(from, to), -1), at(Math.max(from, to), 1)
  ]
  return {
    from: Math.min(...boundaries.map(range => range.from)),
    to: Math.max(...boundaries.map(range => range.to))
  }
}

function countedSlice(
  state: EditorState,
  from: number,
  to: number,
  diagnostics: ObsidianCommentDiagnostics
): string {
  diagnostics.scannedUTF16 += Math.max(0, to - from)
  return state.sliceDoc(from, to)
}

function expandPercentRunBoundaries(
  state: EditorState,
  range: SourceRange,
  diagnostics: ObsidianCommentDiagnostics
): SourceRange {
  let from = range.from
  let to = range.to
  while (from > 0 && countedSlice(state, from - 1, from, diagnostics) === "%") from--
  while (to < state.doc.length && countedSlice(state, to, to + 1, diagnostics) === "%") to++
  return {from, to}
}

function smallChangedRanges(
  transaction: Transaction,
  diagnostics: ObsidianCommentDiagnostics
): SourceRange[] {
  const ranges: SourceRange[] = []
  transaction.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    ranges.push(expandPercentRunBoundaries(transaction.state, {
      from: Math.max(0, fromB - 2),
      to: Math.min(transaction.state.doc.length, Math.max(fromB, toB) + 2)
    }, diagnostics))
  })
  return mergedRanges(ranges)
}

interface ChangedTextSample {
  fromA: number
  toA: number
  fromB: number
  toB: number
  removed: string
  added: string
}

function changedTextSamples(
  transaction: Transaction,
  diagnostics: ObsidianCommentDiagnostics
): ChangedTextSample[] {
  const samples: ChangedTextSample[] = []
  transaction.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    const removed = transaction.startState.sliceDoc(fromA, toA)
    const added = inserted.sliceString(0)
    diagnostics.scannedUTF16 += removed.length + added.length
    samples.push({fromA, toA, fromB, toB, removed, added})
  })
  return samples
}

function syntaxSensitiveChange(
  transaction: Transaction,
  samples: readonly ChangedTextSample[],
  oldInlineHTML: RangeSet<InlineRawHTMLInterval>,
  newInlineHTML: RangeSet<InlineRawHTMLInterval>
): boolean {
  let sensitive = false
  for (const {fromA, fromB, toB, removed, added} of samples) {
    if (sensitive) break
    if (/[`~<>%\\\n\r]/u.test(removed + added)) {
      sensitive = true
      break
    }
    const oldLine = transaction.startState.doc.lineAt(fromA)
    const newLine = transaction.state.doc.lineAt(fromB)
    const touchesIndentBoundary = fromA - oldLine.from <= 4 || fromB - newLine.from <= 4
    sensitive = touchesIndentBoundary ||
      positionIsInert(transaction.startState, Math.min(fromA, transaction.startState.doc.length), oldInlineHTML) ||
      positionIsInert(transaction.state, Math.min(fromB, transaction.state.doc.length), newInlineHTML) ||
      (toB > fromB && positionIsInert(transaction.state, toB - 1, newInlineHTML))
  }
  return sensitive
}

function changedLineRanges(transaction: Transaction): SourceRange[] {
  const ranges: SourceRange[] = []
  transaction.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    const first = transaction.state.doc.lineAt(fromB)
    const last = transaction.state.doc.lineAt(Math.max(fromB, toB))
    ranges.push({from: first.from, to: last.to})
  })
  return mergedRanges(ranges)
}

function inlineHTMLInvalidationRanges(
  transaction: Transaction,
  samples: readonly ChangedTextSample[],
  oldInlineHTML: RangeSet<InlineRawHTMLInterval>
): SourceRange[] {
  const sensitive = samples.some(({fromA, toA, removed, added}) =>
    /[<>\n\r]/u.test(removed + added) || rangeSetOverlaps(oldInlineHTML, fromA, toA))
  return sensitive ? changedLineRanges(transaction) : []
}

/// Expand through the old syntax tree, map that invalidation forward, and
/// expand the mapped region again through the new tree. The second expansion
/// is essential when a local edit turns a former closing fence into a new
/// unclosed FencedCode that reaches far beyond the old node boundary.
function syntaxInvalidationRanges(transaction: Transaction): SourceRange[] {
  const ranges: SourceRange[] = []
  transaction.changes.iterChangedRanges((fromA, toA, fromB, toB) => {
    const oldRange = topLevelSyntaxRange(
      transaction.startState,
      Math.max(0, fromA - 1),
      Math.min(transaction.startState.doc.length, Math.max(fromA, toA) + 1)
    )
    const mappedOld = {
      from: transaction.changes.mapPos(oldRange.from, -1),
      to: transaction.changes.mapPos(oldRange.to, 1)
    }
    const seed = {
      from: Math.max(0, Math.min(mappedOld.from, fromB - 1)),
      to: Math.min(transaction.state.doc.length, Math.max(mappedOld.to, Math.max(fromB, toB) + 1))
    }
    const expandedNew = topLevelSyntaxRange(transaction.state, seed.from, seed.to)
    ranges.push({
      from: Math.min(seed.from, expandedNew.from),
      to: Math.max(seed.to, expandedNew.to)
    })
  })
  return mergedRanges(ranges).map(range => ({
    from: range.from,
    // A newly closed fence can end before delimiters that were inert in the
    // old unclosed fence, so neither the mapped old node nor the new local
    // node necessarily reaches them. Structural edits are rare; invalidate
    // the suffix using the mapped literal-token metadata (without rescanning
    // suffix text) so both opening and re-closing directions are exact.
    to: transaction.state.doc.length
  }))
}

function replaceRanges<T extends RangeValue>(
  set: RangeSet<T>,
  ranges: readonly SourceRange[],
  additions: (range: SourceRange) => readonly Range<T>[]
): RangeSet<T> {
  let updated = set
  for (const range of ranges) {
    updated = updated.update({
      filterFrom: range.from,
      filterTo: range.to,
      filter: (from, to) => from >= range.to || to <= range.from,
      add: additions(range),
      sort: true
    })
  }
  return updated
}

export const obsidianComments = StateField.define<ObsidianCommentIndex>({
  create(state) {
    const diagnostics: ObsidianCommentDiagnostics = {
      scannedUTF16: 0,
      delimiterVisits: 0,
      invalidatedUTF16: state.doc.length,
      literalDelimiterCount: 0,
      activeDelimiterCount: 0,
      rebuiltAllIntervals: true,
      syntaxExpanded: true
    }
    const literals = RangeSet.of(scanLiteralCommentTokens(
      state,
      {from: 0, to: state.doc.length},
      diagnostics
    ))
    const inlineHTML = RangeSet.of(scanInlineRawHTMLRanges(
      state,
      0,
      state.doc.length,
      diagnostics
    ).map(range => inlineRawHTMLInterval.range(range.from, range.to)))
    const active = RangeSet.of(activeTokensFromLiterals(
      state,
      literals,
      inlineHTML,
      {from: 0, to: state.doc.length},
      diagnostics
    ))
    diagnostics.literalDelimiterCount = literals.size
    diagnostics.activeDelimiterCount = active.size
    return {
      literals,
      active,
      intervals: commentIntervals(active, state.doc.length, diagnostics),
      inlineHTML,
      diagnostics
    }
  },
  update(value, transaction) {
    if (!transaction.docChanged) return value
    const diagnostics: ObsidianCommentDiagnostics = {
      scannedUTF16: 0,
      delimiterVisits: 0,
      invalidatedUTF16: 0,
      literalDelimiterCount: 0,
      activeDelimiterCount: 0,
      rebuiltAllIntervals: false,
      syntaxExpanded: false
    }
    const literalRanges = smallChangedRanges(transaction, diagnostics)
    let literals = value.literals.map(transaction.changes)
    literals = replaceRanges(literals, literalRanges, range =>
      scanLiteralCommentTokens(transaction.state, range, diagnostics))

    const samples = changedTextSamples(transaction, diagnostics)
    const inlineHTMLRangesToReplace = inlineHTMLInvalidationRanges(transaction, samples, value.inlineHTML)
    let inlineHTML = value.inlineHTML.map(transaction.changes)
    inlineHTML = replaceRanges(inlineHTML, inlineHTMLRangesToReplace, range =>
      scanInlineRawHTMLRanges(transaction.state, range.from, range.to, diagnostics)
        .map(source => inlineRawHTMLInterval.range(source.from, source.to)))

    const expandSyntax = syntaxSensitiveChange(transaction, samples, value.inlineHTML, inlineHTML)
    diagnostics.syntaxExpanded = expandSyntax
    const activeRanges = mergedRanges([
      ...(expandSyntax ? syntaxInvalidationRanges(transaction) : literalRanges),
      ...inlineHTMLRangesToReplace
    ])
    diagnostics.invalidatedUTF16 = activeRanges.reduce(
      (total, range) => total + range.to - range.from,
      0
    )
    let active = value.active.map(transaction.changes)
    let activeChanged = false
    for (const range of activeRanges) {
      const before = tokenBounds(active, range)
      const additions = activeTokensFromLiterals(transaction.state, literals, inlineHTML, range, diagnostics)
      if (!equalBounds(before, additions.map(token => [token.from, token.to] as const))) activeChanged = true
      active = replaceRanges(active, [range], () => additions)
    }

    let intervals = value.intervals.map(transaction.changes)
    if (activeChanged) {
      diagnostics.rebuiltAllIntervals = true
      intervals = commentIntervals(active, transaction.state.doc.length, diagnostics)
    }
    diagnostics.literalDelimiterCount = literals.size
    diagnostics.activeDelimiterCount = active.size
    return {literals, active, intervals, inlineHTML, diagnostics}
  }
})

export function obsidianCommentDiagnostics(state: EditorState): ObsidianCommentDiagnostics {
  return state.field(obsidianComments).diagnostics
}

function obsidianCommentRanges(state: EditorState, from: number, to: number): SourceRange[] {
  const ranges: SourceRange[] = []
  state.field(obsidianComments).intervals.between(from, to, (start, end) => {
    if (start < to && end > from) ranges.push({from: start, to: end})
  })
  return ranges
}

export function obsidianCommentAt(state: EditorState, position: number): boolean {
  return obsidianCommentRanges(state, position, Math.min(state.doc.length, position + 1)).length > 0
}

function markdownDecorations(
  view: EditorView,
  mode: EditorMode,
  canToggleTasks: boolean,
  onHistoryOwnership: () => void
): DecorationSet {
  const ranges: Range<Decoration>[] = []
  const structuredLines = new Set<number>()
  for (const visible of view.visibleRanges) {
    const firstLine = view.state.doc.lineAt(visible.from)
    const lastLine = view.state.doc.lineAt(visible.to)
    const from = firstLine.from
    const to = lastLine.to
    const documentComments = obsidianCommentRanges(view.state, from, to)
    const inertRanges: SourceRange[] = inlineHTMLRanges(view.state.field(obsidianComments).inlineHTML, from, to)
    const structuredRanges: SourceRange[] = []
    syntaxTree(view.state).iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        const className = nodeClasses[node.name]
        const linkClass = node.name === "Link" || node.name === "Autolink" || node.name === "URL"
        let linkAncestor = node.node.parent
        let nestedLink = false
        while (linkClass && linkAncestor) {
          if (linkAncestor.name === "Link" || linkAncestor.name === "Autolink") {
            nestedLink = true
            break
          }
          linkAncestor = linkAncestor.parent
        }
        const embeddedLink = linkClass && node.from >= 2 && view.state.sliceDoc(node.from - 2, node.from) === "!["
        const wikilinkSyntax = linkClass && node.from > 0 && node.to < view.state.doc.length &&
          view.state.sliceDoc(node.from - 1, node.from) === "[" &&
          view.state.sliceDoc(node.to, node.to + 1) === "]"
        if (className && node.to > node.from &&
            (!linkClass || (!nestedLink && !embeddedLink && !wikilinkSyntax &&
              !overlapsAny(node.from, node.to, documentComments) &&
              !overlapsAny(node.from, node.to, inertRanges)))) {
          ranges.push(Decoration.mark({class: className}).range(node.from, node.to))
        }
        if (inertSyntaxNodes.has(node.name) && node.to > node.from) {
          inertRanges.push({from: node.from, to: node.to})
        }
        if (structuredSyntaxNodes.has(node.name) && node.to > node.from) {
          structuredRanges.push({from: node.from, to: node.to})
        }
      }
    })
    const source = view.state.sliceDoc(from, to)
    const commentRanges = documentComments.filter(comment => overlapsAny(from, to, [comment]))
    for (const comment of commentRanges) {
      const start = Math.max(from, comment.from)
      const end = Math.min(to, comment.to)
      if (end > start) ranges.push(Decoration.mark({class: "tc-comment"}).range(start, end))
    }
    const semanticExclusions = [...inertRanges, ...commentRanges]
    addRegexMarks(source, from, /==[^=\n](?:.*?[^=])?==/gu, "tc-highlight", ranges, semanticExclusions)
    addRegexMarks(source, from, /(?:^|(?<=\s))#[\p{L}\p{N}_-]+(?:\/[\p{L}\p{N}_-]+)*/gmu, "tc-tag", ranges, semanticExclusions)
    addRegexMarks(
      source,
      from,
      /\[\[[^\]\n]+\]\]/gu,
      "tc-wikilink",
      ranges,
      semanticExclusions,
      start => start === 0 || view.state.sliceDoc(start - 1, start) !== "!"
    )
    addRegexMarks(source, from, /^\s*>\s*\[![^\]\n]+\][^\n]*/gmu, "tc-callout", ranges, semanticExclusions)
    const task = /^(\s*(?:[-+*]|\d+[.)])\s+)(\[([ xX])\])\s*(.*)$/gmu
    for (const match of source.matchAll(task)) {
      const markerText = match[2]
      if (!markerText) continue
      const markerFrom = from + match.index + (match[1]?.length ?? 0)
      if (overlapsAny(markerFrom, markerFrom + markerText.length, semanticExclusions)) continue
      ranges.push(Decoration.mark({class: "tc-task-marker", attributes: {"aria-hidden": "true"}})
        .range(markerFrom, markerFrom + markerText.length))
      ranges.push(Decoration.widget({
        widget: new TaskWidget(
          markerFrom,
          (match[3] ?? " ").toLowerCase() === "x",
          match[4]?.trim() ?? "",
          mode,
          canToggleTasks,
          onHistoryOwnership
        ),
        side: 1
      }).range(markerFrom + markerText.length))
    }
    for (const structured of structuredRanges) {
      const startLine = view.state.doc.lineAt(structured.from).number
      const endLine = view.state.doc.lineAt(Math.max(structured.from, structured.to - 1)).number
      for (let lineNumber = startLine; lineNumber <= endLine; lineNumber++) {
        if (lineNumber >= firstLine.number && lineNumber <= lastLine.number) {
          structuredLines.add(lineNumber)
        }
      }
    }
  }
  for (const lineNumber of structuredLines) {
    ranges.push(Decoration.line({class: "tc-structured-line"}).range(view.state.doc.line(lineNumber).from))
  }
  return Decoration.set(ranges, true)
}

export function markdownDecorationPlugin(
  mode: () => EditorMode,
  canToggleTasks: () => boolean,
  onHistoryOwnership: () => void
): Extension {
  class MarkdownDecorationValue {
    decorations: DecorationSet
    constructor(view: EditorView) {
      this.decorations = markdownDecorations(view, mode(), canToggleTasks(), onHistoryOwnership)
    }
    update(update: ViewUpdate): void {
      if (update.docChanged || update.viewportChanged || update.geometryChanged) {
        this.decorations = markdownDecorations(update.view, mode(), canToggleTasks(), onHistoryOwnership)
      }
    }
  }
  return ViewPlugin.fromClass<MarkdownDecorationValue>(MarkdownDecorationValue, {decorations: value => value.decorations})
}

export function focusBlock(view: EditorView): {from: number, to: number} {
  const position = view.state.selection.main.head
  const directBlockNames = new Set([
    "FencedCode", "CodeBlock", "Table",
    "ATXHeading1", "ATXHeading2", "ATXHeading3", "ATXHeading4", "ATXHeading5", "ATXHeading6",
    "SetextHeading1", "SetextHeading2"
  ])
  let node = syntaxTree(view.state).resolveInner(position, -1)
  let paragraph: {from: number, to: number} | undefined
  while (node) {
    // Paragraph is a parser container inside lists and quotes. Prefer the
    // nearest semantic wrapper so its visible marker is part of the active
    // block, while still retaining Paragraph for ordinary prose.
    if (node.name === "ListItem" || node.name === "Blockquote") {
      return {from: node.from, to: node.to}
    }
    if (directBlockNames.has(node.name)) return {from: node.from, to: node.to}
    if (node.name === "Paragraph" && !paragraph) paragraph = {from: node.from, to: node.to}
    if (!node.parent) break
    node = node.parent
  }
  if (paragraph) return paragraph
  // A malformed/incomplete parse still stays bounded to the caret line. A
  // giant paragraph is represented by the Paragraph node above and never
  // scanned line-by-line on selection or playback updates.
  const line = view.state.doc.lineAt(position)
  return {from: line.from, to: line.to}
}

export function focusDecorationPlugin(enabled: () => boolean, mode: () => EditorMode): Extension {
  class FocusDecorationValue {
    decorations = Decoration.none
    constructor(view: EditorView) { this.rebuild(view) }
    update(update: ViewUpdate): void {
      if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged) this.rebuild(update.view)
    }
    rebuild(view: EditorView): void {
      if (!enabled() || mode() !== "editedEditing") { this.decorations = Decoration.none; return }
      const active = focusBlock(view)
      const ranges: Range<Decoration>[] = []
      for (const visible of view.visibleRanges) {
        if (visible.from < active.from) ranges.push(Decoration.mark({class: "tc-focus-dim"}).range(visible.from, Math.min(visible.to, active.from)))
        if (visible.to > active.to) ranges.push(Decoration.mark({class: "tc-focus-dim"}).range(Math.max(visible.from, active.to), visible.to))
      }
      this.decorations = Decoration.set(ranges, true)
    }
  }
  return ViewPlugin.fromClass<FocusDecorationValue>(FocusDecorationValue, {decorations: value => value.decorations})
}
