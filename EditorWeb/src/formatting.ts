import {EditorSelection, type EditorState, type SelectionRange} from "@codemirror/state"
import {type Command} from "@codemirror/view"

function wordRange(state: EditorState, range: SelectionRange): {from: number, to: number} {
  if (!range.empty) return {from: range.from, to: range.to}
  const line = state.doc.lineAt(range.head)
  const offset = range.head - line.from
  const before = line.text.slice(0, offset).match(/[\p{L}\p{N}_-]+$/u)?.[0]?.length ?? 0
  const after = line.text.slice(offset).match(/^[\p{L}\p{N}_-]+/u)?.[0]?.length ?? 0
  return {from: range.head - before, to: range.head + after}
}

function consecutiveAsterisks(source: string, fromStart: boolean): number {
  let count = 0
  if (fromStart) {
    while (count < source.length && source[count] === "*") count++
  } else {
    while (count < source.length && source[source.length - count - 1] === "*") count++
  }
  return count
}

function adjacentAsterisks(state: EditorState, position: number, before: boolean): number {
  let count = 0
  while (before ? position - count - 1 >= 0 : position + count < state.doc.length) {
    const from = before ? position - count - 1 : position + count
    if (state.sliceDoc(from, from + 1) !== "*") break
    count++
  }
  return count
}

function delimiterIsActive(delimiter: "**" | "*", before: number, after: number): boolean {
  const paired = Math.min(before, after)
  // Odd asterisk depth carries italic emphasis: *italic* and ***bold italic***
  // are active, while **bold** is not. Bold is active at every depth >= 2.
  return delimiter === "*" ? paired % 2 === 1 : paired >= 2
}

export function toggleDelimiter(delimiter: "**" | "*"): Command {
  return view => {
    const transaction = view.state.changeByRange(range => {
      if (range.empty) {
        return {
          changes: {from: range.head, insert: delimiter + delimiter},
          range: EditorSelection.cursor(range.head + delimiter.length)
        }
      }
      const target = wordRange(view.state, range)
      const delimiterLength = delimiter.length
      const selectedSource = view.state.sliceDoc(target.from, target.to)
      const selectedBefore = delimiter === "*"
        ? consecutiveAsterisks(selectedSource, true)
        : (selectedSource.startsWith("**") ? 2 : 0)
      const selectedAfter = delimiter === "*"
        ? consecutiveAsterisks(selectedSource, false)
        : (selectedSource.endsWith("**") ? 2 : 0)
      const selectedWrapped = !range.empty && selectedSource.length >= delimiterLength * 2 &&
        delimiterIsActive(delimiter, selectedBefore, selectedAfter)
      if (selectedWrapped) {
        return {
          changes: [
            {from: target.from, to: target.from + delimiterLength, insert: ""},
            {from: target.to - delimiterLength, to: target.to, insert: ""}
          ],
          range: EditorSelection.range(
            target.from,
            target.to - delimiterLength * 2
          )
        }
      }
      const before = delimiter === "*"
        ? adjacentAsterisks(view.state, target.from, true)
        : (view.state.sliceDoc(Math.max(0, target.from - 2), target.from) === "**" ? 2 : 0)
      const after = delimiter === "*"
        ? adjacentAsterisks(view.state, target.to, false)
        : (view.state.sliceDoc(target.to, target.to + 2) === "**" ? 2 : 0)
      const wrapped = delimiterIsActive(delimiter, before, after)
      if (wrapped) {
        return {
          changes: [
            {from: target.from - delimiterLength, to: target.from, insert: ""},
            {from: target.to, to: target.to + delimiterLength, insert: ""}
          ],
          range: EditorSelection.range(target.from - delimiterLength, target.to - delimiterLength)
        }
      }
      return {
        changes: [
          {from: target.from, insert: delimiter},
          {from: target.to, insert: delimiter}
        ],
        range: EditorSelection.range(target.from + delimiterLength, target.to + delimiterLength)
      }
    })
    view.dispatch(transaction)
    return true
  }
}

function markdownLinkAt(state: EditorState, position: number): {from: number, to: number, label: string} | undefined {
  const line = state.doc.lineAt(position)
  const expression = /\[([^\]\n]*)\]\(([^)\n]*)\)/gu
  for (const match of line.text.matchAll(expression)) {
    const from = line.from + match.index
    const to = from + match[0].length
    if (from > line.from && state.sliceDoc(from - 1, from) === "!") continue
    if (position >= from && position <= to) return {from, to, label: match[1] ?? ""}
  }
  return undefined
}

function markdownImageAt(state: EditorState, position: number): boolean {
  const line = state.doc.lineAt(position)
  for (const match of line.text.matchAll(/!\[[^\]\n]*\]\([^\)\n]*\)/gu)) {
    const from = line.from + match.index
    const to = from + match[0].length
    if (position >= from && position <= to) return true
  }
  return false
}

export const toggleLink: Command = view => {
  if (view.state.selection.ranges.some(range => markdownImageAt(view.state, range.head))) {
    return false
  }
  const transaction = view.state.changeByRange(range => {
    const existing = markdownLinkAt(view.state, range.head)
    if (existing) {
      return {
        changes: {from: existing.from, to: existing.to, insert: existing.label},
        range: EditorSelection.range(existing.from, existing.from + existing.label.length)
      }
    }
    const target = range.empty
      ? {from: range.head, to: range.head}
      : {from: range.from, to: range.to}
    const label = view.state.sliceDoc(target.from, target.to)
    const replacement = `[${label}]()`
    const destination = target.from + label.length + 3
    return {
      changes: {from: target.from, to: target.to, insert: replacement},
      range: EditorSelection.cursor(destination)
    }
  })
  view.dispatch(transaction)
  return true
}
