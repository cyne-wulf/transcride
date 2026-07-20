import type {Text, Transaction} from "@codemirror/state"

interface TextLike {
  readonly length: number
  sliceString(from: number, to?: number): string
}

export interface ExactPatch {
  from: number
  to: number
  insert: string
}

export interface ExactDelta extends ExactPatch {
  internalFrom: number
  internalTo: number
  removed: string
}

interface SeparatorNode {
  key: number
  value: string
  priority: number
  extra: number
  subtreeExtra: number
  lazy: number
  left: SeparatorNode | undefined
  right: SeparatorNode | undefined
}

let prioritySequence = 0

function extraUnits(value: string): number { return value.length - 1 }
function subtreeExtra(node?: SeparatorNode): number { return node?.subtreeExtra ?? 0 }

function push(node?: SeparatorNode): void {
  if (!node?.lazy) return
  if (node.left) { node.left.key += node.lazy; node.left.lazy += node.lazy }
  if (node.right) { node.right.key += node.lazy; node.right.lazy += node.lazy }
  node.lazy = 0
}

function update(node: SeparatorNode): SeparatorNode {
  node.subtreeExtra = node.extra + subtreeExtra(node.left) + subtreeExtra(node.right)
  return node
}

function split(node: SeparatorNode | undefined, key: number): [SeparatorNode | undefined, SeparatorNode | undefined] {
  if (!node) return [undefined, undefined]
  push(node)
  if (node.key < key) {
    const [left, right] = split(node.right, key)
    node.right = left
    return [update(node), right]
  }
  const [left, right] = split(node.left, key)
  node.left = right
  return [left, update(node)]
}

function merge(left?: SeparatorNode, right?: SeparatorNode): SeparatorNode | undefined {
  if (!left) return right
  if (!right) return left
  push(left); push(right)
  if (left.priority < right.priority) {
    left.right = merge(left.right, right)
    return update(left)
  }
  right.left = merge(left, right.left)
  return update(right)
}

function node(key: number, value: string): SeparatorNode {
  const priority = (Math.imul(key + 1, 0x9E3779B1) ^ ++prioritySequence) >>> 0
  return {
    key,
    value,
    priority,
    extra: extraUnits(value),
    subtreeExtra: extraUnits(value),
    lazy: 0,
    left: undefined,
    right: undefined
  }
}

function insert(root: SeparatorNode | undefined, item: SeparatorNode): SeparatorNode {
  const [left, right] = split(root, item.key)
  return merge(merge(left, item), right)!
}

function shift(node: SeparatorNode | undefined, amount: number): void {
  if (!node || amount === 0) return
  node.key += amount
  node.lazy += amount
}

function visitRange(
  node: SeparatorNode | undefined,
  from: number,
  to: number,
  body: (position: number, value: string) => void
): void {
  if (!node) return
  push(node)
  if (node.key >= from) visitRange(node.left, from, to, body)
  if (node.key >= from && node.key < to) body(node.key, node.value)
  if (node.key < to) visitRange(node.right, from, to, body)
}

function prefixExtra(node: SeparatorNode | undefined, key: number): number {
  if (!node) return 0
  push(node)
  if (node.key >= key) return prefixExtra(node.left, key)
  return subtreeExtra(node.left) + node.extra + prefixExtra(node.right, key)
}

function neighboringSeparator(node: SeparatorNode | undefined, key: number): string | undefined {
  let current = node
  let predecessor: SeparatorNode | undefined
  let successor: SeparatorNode | undefined
  while (current) {
    push(current)
    if (current.key < key) { predecessor = current; current = current.right }
    else { successor = current; current = current.left }
  }
  return successor?.value ?? predecessor?.value
}

function separatorsIn(text: string): Array<{position: number, value: string}> {
  const result: Array<{position: number, value: string}> = []
  let removed = 0
  for (const match of text.matchAll(/\r\n|\r|\n/gu)) {
    result.push({position: match.index - removed, value: match[0]})
    removed += match[0].length - 1
  }
  return result
}

function normalizedLength(text: string): number {
  let length = text.length
  for (const separator of separatorsIn(text)) length -= separator.value.length - 1
  return length
}

function validUTF16Boundary(text: TextLike, position: number): number {
  const clamped = Math.max(0, Math.min(text.length, position))
  if (clamped > 0 && clamped < text.length) {
    const neighbors = text.sliceString(clamped - 1, clamped + 1)
    const previous = neighbors.charCodeAt(0)
    const next = neighbors.charCodeAt(1)
    if (previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) return clamped - 1
  }
  return clamped
}

export function normalizeExactText(text: string): string {
  return text.replace(/\r\n|\r/gu, "\n")
}

export class ExactTextIndex {
  private root: SeparatorNode | undefined
  normalizedLength: number

  constructor(text: string) {
    this.normalizedLength = normalizedLength(text)
    for (const separator of separatorsIn(text)) {
      this.root = insert(this.root, node(separator.position, separator.value))
    }
  }

  get exactLength(): number { return this.normalizedLength + subtreeExtra(this.root) }

  internalToExternal(offset: number): number {
    const clamped = Math.max(0, Math.min(this.normalizedLength, offset))
    return clamped + prefixExtra(this.root, clamped)
  }

  externalToInternal(offset: number, normalized: TextLike): number {
    const clamped = Math.max(0, Math.min(this.exactLength, offset))
    let low = 0
    let high = this.normalizedLength
    while (low < high) {
      const middle = (low + high + 1) >>> 1
      if (this.internalToExternal(middle) <= clamped) low = middle
      else high = middle - 1
    }
    return validUTF16Boundary(normalized, low)
  }

  preferredSeparator(internalOffset: number): string {
    return neighboringSeparator(this.root, internalOffset) ?? "\n"
  }

  exactSlice(document: Text, from: number, to: number): string {
    const source = document.sliceString(from, to)
    const chunks: string[] = []
    let cursor = 0
    visitRange(this.root, from, to, (position, value) => {
      const local = position - from
      chunks.push(source.slice(cursor, local), value)
      cursor = local + 1
    })
    chunks.push(source.slice(cursor))
    return chunks.join("")
  }

  exactText(document: Text): string {
    return this.exactSlice(document, 0, document.length)
  }

  separators(from: number, to: number): Array<{position: number, value: string}> {
    const result: Array<{position: number, value: string}> = []
    visitRange(this.root, from, to, (position, value) => result.push({position, value}))
    return result
  }

  setSeparator(position: number, value: string): void {
    const [before, atPosition] = split(this.root, position)
    const [_existing, after] = split(atPosition, position + 1)
    this.root = insert(merge(before, after), node(position, value))
  }

  deltas(transaction: Transaction): ExactDelta[] {
    const result: ExactDelta[] = []
    transaction.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
      const separator = this.preferredSeparator(fromA)
      const insertText = inserted.toString().replace(/\n/gu, separator)
      result.push({
        internalFrom: fromA,
        internalTo: toA,
        from: this.internalToExternal(fromA),
        to: this.internalToExternal(toA),
        insert: insertText,
        removed: this.exactSlice(transaction.startState.doc, fromA, toA)
      })
    })
    return result
  }

  applyDeltas(deltas: readonly ExactDelta[]): void {
    for (let index = deltas.length - 1; index >= 0; index--) {
      const delta = deltas[index]!
      const insertedNormalized = normalizeExactText(delta.insert)
      const change = insertedNormalized.length - (delta.internalTo - delta.internalFrom)
      const [before, atStart] = split(this.root, delta.internalFrom)
      const [_removed, after] = split(atStart, delta.internalTo)
      shift(after, change)
      this.root = merge(before, after)
      for (const separator of separatorsIn(delta.insert)) {
        this.root = insert(this.root, node(delta.internalFrom + separator.position, separator.value))
      }
      this.normalizedLength += change
    }
  }
}

export function invertExactDeltas(deltas: readonly ExactDelta[]): ExactDelta[] {
  let offset = 0
  return deltas.map(delta => {
    const from = delta.internalFrom + offset
    const insertedLength = normalizeExactText(delta.insert).length
    const removedLength = delta.internalTo - delta.internalFrom
    const result: ExactDelta = {
      internalFrom: from,
      internalTo: from + insertedLength,
      from: 0,
      to: 0,
      insert: delta.removed,
      removed: delta.insert
    }
    offset += insertedLength - removedLength
    return result
  })
}
