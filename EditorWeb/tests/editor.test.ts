import {describe, expect, it, vi} from "vitest"
import {Transaction} from "@codemirror/state"
import {isolateHistory} from "@codemirror/commands"
import {EditorView} from "@codemirror/view"
import {TypedBridge} from "../src/bridge"
import {focusBlock, obsidianCommentDiagnostics} from "../src/decorations"
import {TranscrideEditor} from "../src/editor"
import type {Envelope} from "../src/protocol"

interface Harness {
  editor: TranscrideEditor
  sent: Envelope[]
  call(method: string, payload?: unknown): Promise<{ok: boolean, result?: unknown, error?: string}>
}

function harness(
  nativeReply: (message: Envelope) => unknown = () => ({accepted: true})
): Harness {
  const parent = document.createElement("main")
  parent.style.height = "600px"
  document.body.append(parent)
  const sent: Envelope[] = []
  window.webkit = {messageHandlers: {editorBridge: {postMessage: vi.fn(async message => {
    sent.push(message as Envelope)
    return nativeReply(message as Envelope)
  })}}}
  const bridge = new TypedBridge("test-session")
  const editor = new TranscrideEditor(parent, bridge)
  let sequence = 0
  return {
    editor,
    sent,
    call(method, payload = {}) {
      return bridge.receive({protocolVersion: 1, sessionID: "test-session", requestID: `n-${sequence}`, sequence: sequence++, method, payload})
    }
  }
}

describe("CodeMirror workbench", () => {
  it("reports selection and scroll changes without manufacturing a text patch", async () => {
    const h = harness()
    const text = "😀 one\ntwo\nthree"
    await h.call("replaceDocument", {
      text,
      mode: "editedEditing",
      resetHistory: true,
      selection: [{anchor: 0, head: 0}],
      scrollTop: 0
    })
    await new Promise(resolve => setTimeout(resolve, 20))
    h.sent.splice(0)
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({selection: {anchor: 3, head: 6}})
    view.scrollDOM.scrollTop = 24
    view.scrollDOM.dispatchEvent(new Event("scroll"))
    await new Promise(resolve => setTimeout(resolve, 80))

    const viewStates = h.sent.filter(message => message.method === "viewState")
    expect(viewStates.length).toBeGreaterThan(0)
    expect(viewStates.at(-1)?.payload).toEqual({
      selection: [{anchor: 3, head: 6}],
      mainSelectionIndex: 0,
      scrollTop: 24
    })
    expect(h.sent.some(message => message.method === "patches")).toBe(false)
    h.editor.destroy()
  })

  it("decorates every supported syntax while keeping every delimiter and unsupported source inert", async () => {
    const h = harness()
    const text = [
      "# Heading",
      "*italic* **bold** ~~gone~~",
      "- unordered",
      "1. ordered",
      "- [ ] task",
      "> quote",
      "[label](https://example.com)",
      "",
      "| a | b |",
      "|---|---|",
      "| c | d |",
      "",
      "---",
      "`inline`",
      "```js",
      "const value = 1",
      "```",
      "==mark==",
      "> [!NOTE] callout",
      "%%comment%%",
      "body #tag [[Note]]",
      "![image](asset.png) ![[embed]] $math$ [^footnote] <span>raw</span>"
    ].join("\n")
    expect((await h.call("replaceDocument", {text, mode: "original", resetHistory: true})).ok).toBe(true)
    const visibleSource = document.querySelector(".cm-content")?.textContent ?? ""
    for (const delimited of [
      "# Heading", "*italic*", "**bold**", "~~gone~~", "- unordered", "1. ordered",
      "[ ]", "> quote", "[label](https://example.com)", "|---|---|", "---", "`inline`",
      "```js", "==mark==", "> [!NOTE]", "%%comment%%", "#tag", "[[Note]]",
      "![image](asset.png)", "![[embed]]", "$math$", "[^footnote]", "<span>raw</span>"
    ]) expect(visibleSource).toContain(delimited)

    for (const selector of [
      ".tc-heading", ".tc-emphasis", ".tc-strong", ".tc-strikethrough", ".tc-list",
      ".tc-task-marker", ".tc-task-control", ".tc-blockquote", ".tc-link", ".tc-table",
      ".tc-rule", ".tc-inline-code", ".tc-code-block", ".tc-highlight", ".tc-callout",
      ".tc-comment", ".tc-tag", ".tc-wikilink"
    ]) expect(document.querySelector(selector), selector).not.toBeNull()
    expect(document.querySelector(".tc-unordered-list")?.textContent)
      .toContain("- unordered")
    expect(document.querySelector(".tc-ordered-list")?.textContent)
      .toContain("1. ordered")
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    expect(document.querySelectorAll("img:not(.cm-widgetBuffer),iframe,svg,canvas,math"))
      .toHaveLength(0)
    expect((await h.call("requestSnapshot", {reason: "syntax-source"})).result)
      .toMatchObject({text})
    h.editor.destroy()
  })

  it("styles complete structured blocks and keeps code comments raw HTML and embeds inert", async () => {
    const h = harness()
    const text = [
      "- list item",
      "  wrapped continuation",
      "",
      "    indented code",
      "",
      "~~~md",
      "- [ ] fenced [[Fence]]",
      "~~~",
      "",
      "%%",
      "- [ ] commented [[Comment]]",
      "%%",
      "",
      "<div>",
      "- [ ] raw [[Raw]]",
      "</div>",
      "",
      "| a | b |",
      "|---|---|",
      "| c | d |",
      "",
      "- [ ] live [[Live]] and `[[Inline]]` ![[Embed]]"
    ].join("\n")
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})

    const lines = [...document.querySelectorAll<HTMLElement>(".cm-line")]
    const structured = (content: string) => lines.find(line => line.textContent === content)?.classList
      .contains("tc-structured-line")
    expect(structured("- list item")).toBe(true)
    expect(structured("  wrapped continuation")).toBe(true)
    expect(structured("    indented code")).toBe(true)
    expect(structured("~~~md")).toBe(true)
    expect(structured("- [ ] fenced [[Fence]]")).toBe(true)
    expect(structured("~~~")).toBe(true)
    expect(structured("| c | d |")).toBe(true)

    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    expect(document.querySelector(".tc-comment")).not.toBeNull()

    const linkAt = (h.editor as unknown as {
      linkAt(position: number): Record<string, unknown> | undefined
    }).linkAt.bind(h.editor)
    expect(linkAt(text.indexOf("Live") + 1)).toMatchObject({kind: "wikilink", target: "Live"})
    expect(linkAt(text.indexOf("Fence") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Comment") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Raw") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Inline") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Embed") + 1)).toBeUndefined()
    const liveEnd = text.indexOf("[[Live]]") + "[[Live]]".length
    expect(linkAt(liveEnd)).toBeUndefined()
    h.editor.destroy()
  })

  it("keeps an off-viewport Obsidian comment inert after mapped edits", async () => {
    const h = harness()
    const hidden = "- [ ] hidden [[Hidden]] [Hidden web](https://invalid.example)"
    const live = "- [ ] live [[Live]] [Live web](https://example.com)"
    const text = [
      "%%",
      ...Array.from({length: 700}, (_, index) => `before ${index}`),
      hidden,
      ...Array.from({length: 700}, (_, index) => `after ${index}`),
      "%%",
      live
    ]
      .join("\n")
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({
      changes: {from: 0, insert: "mapped prefix\n"},
      annotations: Transaction.userEvent.of("input.type")
    })
    const mappedText = `mapped prefix\n${text}`
    const hiddenPosition = mappedText.indexOf("Hidden")
    view.dispatch({
      selection: {anchor: hiddenPosition},
      effects: EditorView.scrollIntoView(hiddenPosition, {y: "center"})
    })
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(0)
    expect(document.querySelectorAll(".tc-wikilink,.tc-link")).toHaveLength(0)

    const livePosition = mappedText.indexOf("Live")
    view.dispatch({
      selection: {anchor: livePosition},
      effects: EditorView.scrollIntoView(livePosition, {y: "center"})
    })
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    h.editor.destroy()
  })

  it("ignores comment delimiters in syntax-inert source and limits inline HTML inertness", async () => {
    const h = harness()
    const text = [
      "```md",
      "%% [[Fenced]]",
      "```",
      "inline `%% [[Inline]]`",
      "<span>%% [[Raw]] [Raw web](https://invalid.example)</span>",
      "- [ ] valid <span>[[Inside]]</span> [[Live]] [Web](https://example.com)"
    ].join("\n")
    await h.call("replaceDocument", {text, mode: "editedView", resetHistory: true})
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-link")).toHaveLength(1)

    const linkAt = (h.editor as unknown as {
      linkAt(position: number): Record<string, unknown> | undefined
    }).linkAt.bind(h.editor)
    expect(linkAt(text.indexOf("Fenced") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Inline") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Raw") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Inside") + 1)).toBeUndefined()
    expect(linkAt(text.indexOf("Live") + 1)).toMatchObject({kind: "wikilink", target: "Live"})
    h.editor.destroy()
  })

  it("invalidates mapped comments when a local edit opens or recloses a fenced block", async () => {
    const h = harness()
    const text = [
      "```",
      "x",
      "```",
      "%%",
      "comment - [ ] [[Commented]] [Hidden](https://invalid.example)",
      "%%",
      "- [ ] after [[After]] [Web](https://example.com)"
    ].join("\n")
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    expect(document.querySelectorAll(".tc-comment").length).toBeGreaterThan(0)
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-link")).toHaveLength(1)

    view.dispatch({
      changes: {from: 0, to: 1},
      annotations: Transaction.userEvent.of("delete.backward")
    })
    expect(document.querySelectorAll(".tc-comment")).toHaveLength(0)
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(0)
    expect(document.querySelectorAll(".tc-wikilink,.tc-link")).toHaveLength(0)
    expect(obsidianCommentDiagnostics(view.state).syntaxExpanded).toBe(true)

    view.dispatch({
      changes: {from: 0, insert: "`"},
      annotations: Transaction.userEvent.of("input.type")
    })
    expect(document.querySelectorAll(".tc-comment").length).toBeGreaterThan(0)
    expect(document.querySelectorAll(".tc-task-control")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-wikilink")).toHaveLength(1)
    expect(document.querySelectorAll(".tc-link")).toHaveLength(1)
    h.editor.destroy()
  })

  it("bounds ordinary comment-index edits in a 50000-character paragraph", async () => {
    const h = harness()
    const text = "word %% hidden %% ".repeat(3_000)
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    expect(view.state.doc.length).toBeGreaterThan(50_000)
    const position = text.indexOf("word", 25_000) + 2
    view.dispatch({
      changes: {from: position, insert: "x"},
      annotations: Transaction.userEvent.of("input.type")
    })
    const diagnostics = obsidianCommentDiagnostics(view.state)
    expect(diagnostics.syntaxExpanded).toBe(false)
    expect(diagnostics.rebuiltAllIntervals).toBe(false)
    expect(diagnostics.scannedUTF16).toBeLessThanOrEqual(8)
    expect(diagnostics.delimiterVisits).toBeLessThan(10)
    h.editor.destroy()
  })

  it("classifies a long structural suffix from cached metadata without rescanning its line", async () => {
    const h = harness()
    const text = `lead ${"word %% hidden %% ".repeat(3_000)}<span>%% raw %%</span>`
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    expect(view.state.doc.length).toBeGreaterThan(50_000)
    expect(obsidianCommentDiagnostics(view.state).literalDelimiterCount).toBeGreaterThan(6_000)
    view.dispatch({
      changes: {from: 5, insert: "`"},
      annotations: Transaction.userEvent.of("input.type")
    })
    const diagnostics = obsidianCommentDiagnostics(view.state)
    expect(diagnostics.syntaxExpanded).toBe(true)
    expect(diagnostics.invalidatedUTF16).toBeGreaterThan(50_000)
    expect(diagnostics.delimiterVisits).toBeGreaterThan(6_000)
    expect(diagnostics.scannedUTF16).toBeLessThanOrEqual(12)
    h.editor.destroy()
  })

  it("keeps incremental percent-run tokenization equivalent to a full rebuild", async () => {
    const h = harness()
    const view = (h.editor as unknown as {view: EditorView}).view
    const signature = () => ({
      comments: [...document.querySelectorAll<HTMLElement>(".tc-comment")]
        .map(element => element.textContent ?? ""),
      active: obsidianCommentDiagnostics(view.state).activeDelimiterCount
    })
    const verify = async (before: string, from: number, to: number, insert: string) => {
      await h.call("replaceDocument", {text: before, mode: "editedEditing", resetHistory: true})
      view.dispatch({changes: {from, to, insert}, annotations: Transaction.userEvent.of("input.type")})
      const incremental = signature()
      const after = before.slice(0, from) + insert + before.slice(to)
      await h.call("replaceDocument", {text: after, mode: "editedEditing", resetHistory: true})
      expect(incremental, `${JSON.stringify({before, from, to, insert, after})}`).toEqual(signature())
    }

    for (let length = 1; length <= 6; length++) {
      const run = "%".repeat(length)
      const before = `lead ${run}hidden`
      const start = 5
      for (let boundary = 0; boundary <= length; boundary++) {
        await verify(before, start + boundary, start + boundary, "%")
        await verify(before, start + boundary, start + boundary, "x")
        if (boundary < length) {
          await verify(before, start + boundary, start + boundary + 1, "")
          await verify(before, start + boundary, start + boundary + 1, "x")
        }
      }
    }
    await verify("lead %x%%%hidden", 6, 7, "")
    await verify("lead %%%%%hidden", 7, 7, "x")
    h.editor.destroy()
  }, 20_000)

  it("maps closed and unmatched comment boundaries through edits and Undo Redo", async () => {
    const h = harness()
    const view = (h.editor as unknown as {view: EditorView}).view
    const markedComment = () => [...document.querySelectorAll<HTMLElement>(".tc-comment")]
      .map(element => element.textContent ?? "")
      .join("")
    const commentSignature = () => ({
      marked: markedComment(),
      active: obsidianCommentDiagnostics(view.state).activeDelimiterCount
    })
    const load = async (text: string) => {
      await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    }
    const userEdit = (from: number, to: number, insert: string) => view.dispatch({
      changes: {from, to, insert},
      annotations: [Transaction.userEvent.of("input.type"), isolateHistory.of("full")]
    })

    const closed = "%%hidden%%after"
    for (const item of [
      {position: 0, expected: "%%hidden%%"},
      {position: 2, expected: "%%Xhidden%%"},
      {position: 8, expected: "%%hiddenX%%"},
      {position: 10, expected: "%%hidden%%"}
    ]) {
      await load(closed)
      userEdit(item.position, item.position, "X")
      expect(markedComment()).toBe(item.expected)
    }

    for (const {from, to} of [
      {from: 0, to: 1}, {from: 1, to: 2},
      {from: 8, to: 9}, {from: 9, to: 10}
    ]) {
      for (const insert of ["", "X"]) {
        await load(closed)
        userEdit(from, to, insert)
        const incremental = commentSignature()
        const after = closed.slice(0, from) + insert + closed.slice(to)
        await load(after)
        expect(incremental, `${JSON.stringify({from, to, insert, after})}`).toEqual(commentSignature())
      }
    }

    for (const item of [
      {text: "A%%hidden%%after", from: 0, to: 1},
      {text: "%%Ahidden%%after", from: 2, to: 3},
      {text: "%%hiddenA%%after", from: 8, to: 9},
      {text: "%%hidden%%Aafter", from: 10, to: 11}
    ]) {
      await load(item.text)
      userEdit(item.from, item.to, "")
      expect(markedComment()).toBe("%%hidden%%")
    }

    for (const item of [
      {text: "A%%hidden%%after", from: 0, to: 1, expected: "%%hidden%%"},
      {text: "%%Ahidden%%after", from: 2, to: 3, expected: "%%Xhidden%%"},
      {text: "%%hiddenA%%after", from: 8, to: 9, expected: "%%hiddenX%%"},
      {text: "%%hidden%%Aafter", from: 10, to: 11, expected: "%%hidden%%"}
    ]) {
      await load(item.text)
      userEdit(item.from, item.to, "X")
      expect(markedComment()).toBe(item.expected)
    }

    await load(closed)
    userEdit(10, 10, "X")
    expect(markedComment()).toBe("%%hidden%%")
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect(markedComment()).toBe("%%hidden%%")
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect(markedComment()).toBe("%%hidden%%")

    const unmatched = "prefix %%hidden"
    await load(unmatched)
    userEdit(unmatched.length, unmatched.length, "X")
    expect(markedComment()).toBe("%%hiddenX")
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect(markedComment()).toBe("%%hidden")
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect(markedComment()).toBe("%%hiddenX")
    h.editor.destroy()
  })

  it("recomputes comment inertness when a backslash escapes or restores inline code", async () => {
    const h = harness()
    const text = "`code %%` after"
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    expect(document.querySelectorAll(".tc-comment")).toHaveLength(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(0)

    view.dispatch({
      changes: {from: 0, insert: "\\"},
      annotations: Transaction.userEvent.of("input.type")
    })
    expect(document.querySelectorAll(".tc-comment").length).toBeGreaterThan(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(1)
    expect(obsidianCommentDiagnostics(view.state).syntaxExpanded).toBe(true)

    view.dispatch({
      changes: {from: 0, to: 1},
      annotations: Transaction.userEvent.of("delete.backward")
    })
    expect(document.querySelectorAll(".tc-comment")).toHaveLength(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(0)
    expect(obsidianCommentDiagnostics(view.state).syntaxExpanded).toBe(true)
    h.editor.destroy()
  })

  it("recomputes comment inertness when an edit creates or destroys four-space code", async () => {
    const h = harness()
    const text = "    code %%"
    await h.call("replaceDocument", {text, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    expect(document.querySelectorAll(".tc-comment")).toHaveLength(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(0)

    view.dispatch({
      changes: {from: 0, insert: "x"},
      annotations: Transaction.userEvent.of("input.type")
    })
    expect(document.querySelectorAll(".tc-comment").length).toBeGreaterThan(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(1)
    expect(obsidianCommentDiagnostics(view.state).syntaxExpanded).toBe(true)

    view.dispatch({
      changes: {from: 0, to: 1},
      annotations: Transaction.userEvent.of("delete.backward")
    })
    expect(document.querySelectorAll(".tc-comment")).toHaveLength(0)
    expect(obsidianCommentDiagnostics(view.state).activeDelimiterCount).toBe(0)
    expect(obsidianCommentDiagnostics(view.state).syntaxExpanded).toBe(true)
    h.editor.destroy()
  })

  it("toggles Edited tasks as one patch and keeps Original immutable", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "- [ ] accessible task", mode: "editedView", resetHistory: true})
    const checkbox = document.querySelector<HTMLInputElement>(".tc-task-control")
    expect(checkbox?.getAttribute("aria-label")).toBe("Task: accessible task")
    checkbox?.click()
    await new Promise(resolve => setTimeout(resolve, 0))
    const patch = h.sent.find(message => message.method === "patches")
    expect(patch?.payload).toEqual({
      baseLength: 21,
      intent: "task",
      changes: [{from: 3, to: 4, insert: "x"}]
    })

    await h.call("replaceDocument", {text: "- [ ] immutable", mode: "original", resetHistory: true})
    const originalTask = document.querySelector<HTMLInputElement>(".tc-task-control")
    expect(originalTask?.disabled).toBe(true)
    h.editor.destroy()
  })

  it("honors collapsed and selected Bold/Italic contracts only in Edited editing", async () => {
    const h = harness()
    for (const [command, wrapped, inside] of ([
      ["bold", "**word**", {anchor: 2, head: 6}],
      ["italic", "*word*", {anchor: 1, head: 5}]
    ] as const)) {
      await h.call("replaceDocument", {
        text: "word", mode: "editedEditing",
        selection: [{anchor: 0, head: 4}], resetHistory: true
      })
      expect((await h.call("executeCommand", {command})).result).toBe(true)
      expect((await h.call("requestSnapshot", {reason: `${command}-wrap`})).result)
        .toMatchObject({text: wrapped, viewState: {selection: [inside]}})
      expect((await h.call("executeCommand", {command})).result).toBe(true)
      expect((await h.call("requestSnapshot", {reason: `${command}-unwrap`})).result)
        .toMatchObject({text: "word", viewState: {selection: [{anchor: 0, head: 4}]}})
    }

    for (const [command, text, caret] of ([
      ["bold", "wo****rd", 4],
      ["italic", "wo**rd", 3]
    ] as const)) {
      await h.call("replaceDocument", {
        text: "word", mode: "editedEditing",
        selection: [{anchor: 2, head: 2}], resetHistory: true
      })
      expect((await h.call("executeCommand", {command})).result).toBe(true)
      expect((await h.call("requestSnapshot", {reason: `${command}-collapsed`})).result)
        .toMatchObject({
          text,
          viewState: {selection: [{anchor: caret, head: caret}]}
        })
    }

    await h.call("replaceDocument", {text: "word", mode: "original", selection: [{anchor: 0, head: 4}], resetHistory: true})
    expect((await h.call("executeCommand", {command: "italic"})).result).toBe(false)
    await h.call("replaceDocument", {text: "word", mode: "editedView", selection: [{anchor: 0, head: 4}], resetHistory: true})
    expect((await h.call("executeCommand", {command: "bold"})).result).toBe(false)
    await h.call("replaceDocument", {text: "word", mode: "editedEditing", selection: [{anchor: 0, head: 4}], resetHistory: true})
    await h.call("setFrozen", {frozen: true, reason: "test"})
    expect((await h.call("executeCommand", {command: "italic"})).result).toBe(false)
    h.editor.destroy()
  })

  it("handles nested full-source and collapsed-word formatting without touching images", async () => {
    const h = harness()
    await h.call("replaceDocument", {
      text: "**word**", mode: "editedEditing",
      selection: [{anchor: 0, head: 8}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "bold"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "bold-source-unwrap"})).result)
      .toMatchObject({text: "word"})

    await h.call("replaceDocument", {
      text: "**word**", mode: "editedEditing",
      selection: [{anchor: 2, head: 6}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "italic"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "nested-italic"})).result)
      .toMatchObject({text: "***word***"})

    await h.call("replaceDocument", {
      text: "word", mode: "editedEditing",
      selection: [{anchor: 2, head: 2}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "link"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "empty-link"})).result)
      .toMatchObject({text: "wo[]()rd", viewState: {selection: [{anchor: 5, head: 5}]}})

    await h.call("replaceDocument", {
      text: "word", mode: "editedEditing",
      selection: [{anchor: 0, head: 4}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "link"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "selected-link"})).result)
      .toMatchObject({text: "[word]()", viewState: {selection: [{anchor: 7, head: 7}]}})
    expect((await h.call("executeCommand", {command: "link"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "link-unwrap"})).result)
      .toMatchObject({text: "word"})

    for (const selection of [
      [{anchor: 3, head: 7}],
      [{anchor: 0, head: 10}]
    ]) {
      await h.call("replaceDocument", {
        text: "***word***", mode: "editedEditing", selection, resetHistory: true
      })
      expect((await h.call("executeCommand", {command: "italic"})).result).toBe(true)
      expect((await h.call("requestSnapshot", {reason: "nested-italic-unwrap"})).result)
        .toMatchObject({text: "**word**"})
    }

    await h.call("replaceDocument", {
      text: "![alt](image.png)", mode: "editedEditing",
      selection: [{anchor: 3, head: 3}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "link"})).result).toBe(false)
    expect((await h.call("requestSnapshot", {reason: "image-inert"})).result)
      .toMatchObject({text: "![alt](image.png)"})
    h.editor.destroy()
  })

  it("continues and exits unordered ordered task and quote blocks and conditionally indents lists", async () => {
    const h = harness()
    const key = (view: EditorView, value: string, shiftKey = false) => view.contentDOM.dispatchEvent(
      new KeyboardEvent("keydown", {key: value, shiftKey, bubbles: true, cancelable: true})
    )
    const view = (h.editor as unknown as {view: EditorView}).view
    for (const [source, continued] of ([
      ["- item", "- item\n- "],
      ["1. item", "1. item\n2. "],
      ["- [ ] task", "- [ ] task\n- [ ] "],
      ["> quote", "> quote\n> "]
    ] as const)) {
      await h.call("replaceDocument", {
        text: source, mode: "editedEditing",
        selection: [{anchor: source.length, head: source.length}], resetHistory: true
      })
      key(view, "Enter")
      expect((await h.call("requestSnapshot", {reason: "block-continue"})).result)
        .toMatchObject({text: continued})
    }

    for (const source of ["- ", "1. ", "- [ ] ", "> "]) {
      await h.call("replaceDocument", {
        text: source, mode: "editedEditing",
        selection: [{anchor: source.length, head: source.length}], resetHistory: true
      })
      key(view, "Enter")
      expect((await h.call("requestSnapshot", {reason: "block-exit"})).result)
        .toMatchObject({text: ""})
    }

    await h.call("replaceDocument", {
      text: "- one\n- two", mode: "editedEditing",
      selection: [{anchor: 0, head: 11}], resetHistory: true
    })
    expect(key(view, "Tab")).toBe(false)
    expect((await h.call("requestSnapshot", {reason: "list-indent"})).result)
      .toMatchObject({text: "  - one\n  - two"})
    expect(key(view, "Tab", true)).toBe(false)
    expect((await h.call("requestSnapshot", {reason: "list-outdent"})).result)
      .toMatchObject({text: "- one\n- two"})

    await h.call("replaceDocument", {
      text: "plain", mode: "editedEditing",
      selection: [{anchor: 0, head: 5}], resetHistory: true
    })
    expect(key(view, "Tab")).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "plain-tab"})).result)
      .toMatchObject({text: "plain"})
    h.editor.destroy()
  })

  it("selects the most-specific bounded Focus Mode block", async () => {
    const h = harness()
    const text = [
      "> outer",
      ">",
      "> - first paragraph",
      ">   continuation",
      "> - second",
      "",
      "tail"
    ].join("\n")
    await h.call("replaceDocument", {
      text, mode: "editedEditing",
      selection: [{anchor: text.indexOf("continuation"), head: text.indexOf("continuation")}],
      resetHistory: true
    })
    const view = (h.editor as unknown as {view: EditorView}).view
    const block = focusBlock(view)
    const listItem = view.state.sliceDoc(block.from, block.to)
    expect(listItem.trimStart().startsWith("- first paragraph")).toBe(true)
    expect(listItem).toContain("continuation")
    expect(listItem).not.toContain("second")

    const quote = "> quoted line\n> continuation\n\nplain"
    await h.call("replaceDocument", {
      text: quote, mode: "editedEditing",
      selection: [{anchor: quote.indexOf("continuation"), head: quote.indexOf("continuation")}],
      resetHistory: true
    })
    const quoteBlock = focusBlock(view)
    const activeQuote = view.state.sliceDoc(quoteBlock.from, quoteBlock.to)
    expect(activeQuote.startsWith("> quoted line")).toBe(true)
    expect(activeQuote).toContain("> continuation")
    expect(activeQuote).not.toContain("plain")

    const long = Array.from({length: 10_000}, (_, index) => `word${index}`).join("\n")
    await h.call("replaceDocument", {
      text: long, mode: "editedEditing",
      selection: [{anchor: Math.floor(long.length / 2), head: Math.floor(long.length / 2)}],
      resetHistory: true
    })
    const longBlock = focusBlock(view)
    expect(longBlock).toEqual({from: 0, to: long.length})
    h.editor.destroy()
  })

  it("opens in-surface find in every mode and gates replace commands", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "find find", mode: "original", resetHistory: true})
    expect((await h.call("executeCommand", {command: "openFind"})).result).toBe(true)
    expect(document.querySelector(".cm-search")).not.toBeNull()
    expect((await h.call("executeCommand", {command: "replaceAll"})).result).toBe(false)
    await h.call("configure", {mode: "editedEditing", preferences: {fontSize: 18, width: "narrow", editedAlignment: "left", focusMode: true}})
    expect(document.querySelector(".cm-editor")?.className).toContain("tc-mode-editedEditing")
    expect(getComputedStyle(document.querySelector(".cm-content")!).fontSize).toBe("18px")
    h.editor.destroy()
  })

  it("supports case whole-word regex navigation and one-transaction replacement", async () => {
    const h = harness()
    await h.call("replaceDocument", {
      text: "Alpha alpha alphabet ALPHA", mode: "editedEditing",
      selection: [{anchor: 0, head: 0}], resetHistory: true
    })
    await h.call("executeCommand", {command: "openFind"})
    const input = document.querySelector<HTMLInputElement>(".cm-search input[name=search]")!
    const replacement = document.querySelector<HTMLInputElement>(".cm-search input[name=replace]")!
    const setInput = async (element: HTMLInputElement, value: string) => {
      element.value = value
      element.dispatchEvent(new KeyboardEvent("keyup", {key: "a", bubbles: true}))
      await new Promise(resolve => setTimeout(resolve, 0))
    }
    await setInput(input, "alpha")
    expect(document.querySelector(".tc-search-count")?.textContent).toContain("4")
    document.querySelector<HTMLElement>(".cm-search [name=case]")?.click()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(document.querySelector(".tc-search-count")?.textContent).toContain("1")
    document.querySelector<HTMLElement>(".cm-search [name=case]")?.click()
    document.querySelector<HTMLElement>(".cm-search [name=word]")?.click()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(document.querySelector(".tc-search-count")?.textContent).toContain("3")
    document.querySelector<HTMLElement>(".cm-search [name=word]")?.click()
    document.querySelector<HTMLElement>(".cm-search [name=re]")?.click()
    await setInput(input, "A[a-z]+a")
    expect(document.querySelector(".tc-search-count")?.textContent).toContain("4")
    document.querySelector<HTMLElement>(".cm-search [name=re]")?.click()

    await setInput(input, "alpha")
    await setInput(replacement, "X")
    expect((await h.call("executeCommand", {command: "findNext"})).result).toBe(true)
    expect((await h.call("executeCommand", {command: "findPrevious"})).result).toBe(true)
    expect((await h.call("executeCommand", {command: "replaceNext"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "replace-one"})).result)
      .toMatchObject({text: "Alpha alpha alphabet X"})
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("executeCommand", {command: "replaceAll"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "replace-all"})).result)
      .toMatchObject({text: "X X Xbet X"})
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "replace-all-undo"})).result)
      .toMatchObject({text: "Alpha alpha alphabet ALPHA"})
    h.editor.destroy()
  })

  it("does not echo native replacement and emits UTF-16 patch coordinates", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "😀 word", mode: "editedEditing", selection: [{anchor: 3, head: 7}], resetHistory: true})
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(h.sent.some(message => message.method === "patches")).toBe(false)
    await h.call("executeCommand", {command: "italic"})
    await new Promise(resolve => setTimeout(resolve, 0))
    const patch = h.sent.find(message => message.method === "patches")
    expect(patch?.payload).toEqual({
      baseLength: 7,
      intent: "text",
      changes: [{from: 3, to: 3, insert: "*"}, {from: 7, to: 7, insert: "*"}]
    })
    h.editor.destroy()
  })

  it("snapshots immediately after a rejected patch and accepts the following edit", async () => {
    let rejectPatch = true
    const h = harness(message => {
      if (message.method === "patches" && rejectPatch) {
        rejectPatch = false
        return {accepted: false, requiresSnapshot: true}
      }
      return {accepted: true}
    })
    await h.call("replaceDocument", {
      text: "word", mode: "editedEditing",
      selection: [{anchor: 0, head: 4}], resetHistory: true
    })
    await h.call("executeCommand", {command: "bold"})
    await new Promise(resolve => setTimeout(resolve, 0))
    const patchFlow = h.sent.filter(message => message.method === "patches" || message.method === "snapshot")
    expect(patchFlow.map(message => message.method)).toEqual(["patches", "snapshot"])
    expect((patchFlow[1]?.payload as {text: string}).text).toBe("**word**")

    const secondBoldAfterSnapshot = await h.call("executeCommand", {command: "bold"})
    expect(secondBoldAfterSnapshot.error).toBeUndefined()
    expect(secondBoldAfterSnapshot).toMatchObject({ok: true, result: true})
    await vi.waitFor(() => expect(h.sent.at(-1)?.method).toBe("patches"))
    expect(h.sent.map(message => message.sequence)).toEqual(h.sent.map((_, index) => index))
    h.editor.destroy()
  })

  it("restores selection and reports exact body snapshots", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "alpha\nbeta", mode: "editedEditing", resetHistory: true})
    await h.call("restoreViewState", {selection: [{anchor: 6, head: 10}], mainSelectionIndex: 0, scrollTop: 12})
    const result = await h.call("captureViewState")
    expect(result.result).toMatchObject({selection: [{anchor: 6, head: 10}], mainSelectionIndex: 0})
    const snapshot = await h.call("requestSnapshot", {reason: "save"})
    expect(snapshot.result).toMatchObject({text: "alpha\nbeta", mode: "editedEditing", reason: "save"})
    h.editor.destroy()
  })

  it("preserves CRLF, CR, and mixed separators through no-op snapshots and edits", async () => {
    const h = harness()
    const mixed = "one\r\ntwo\rthree\nfour"
    await h.call("replaceDocument", {
      text: mixed,
      mode: "editedEditing",
      selection: [{anchor: 5, head: 8}],
      resetHistory: true
    })
    expect((await h.call("requestSnapshot", {reason: "mixed-no-op"})).result).toMatchObject({text: mixed})

    expect((await h.call("executeCommand", {command: "bold"})).result).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 0))
    const expected = "one\r\n**two**\rthree\nfour"
    expect((await h.call("requestSnapshot", {reason: "mixed-edit"})).result).toMatchObject({text: expected})
    const patch = h.sent.find(message => message.method === "patches")
    expect(patch?.payload).toMatchObject({
      baseLength: mixed.length,
      changes: [{from: 5, to: 5, insert: "**"}, {from: 8, to: 8, insert: "**"}]
    })
    h.editor.destroy()
  })

  it("reports click and link positions in exact mixed-ending UTF-16 coordinates", async () => {
    const h = harness()
    const text = "one\r\n[[Target]]\rtail"
    await h.call("replaceDocument", {
      text,
      mode: "original",
      selection: [{anchor: 7, head: 7}],
      resetHistory: true
    })
    const internals = h.editor as unknown as {
      view: EditorView
      handleMouseDown(event: MouseEvent, view: EditorView): boolean
    }
    vi.spyOn(internals.view, "posAtCoords").mockReturnValue(6)
    internals.handleMouseDown(new MouseEvent("mousedown", {
      button: 0, clientX: 1, clientY: 1
    }), internals.view)
    internals.view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", {
      key: "Enter", metaKey: true, bubbles: true, cancelable: true
    }))
    await vi.waitFor(() => expect(h.sent.filter(message =>
      message.method === "clickAction" || message.method === "linkAction"
    )).toHaveLength(2))
    expect(h.sent.find(message => message.method === "clickAction")?.payload).toEqual({
      kind: "originalPosition", position: 7
    })
    expect(h.sent.find(message => message.method === "linkAction")?.payload).toMatchObject({
      kind: "wikilink", from: 5, to: 15
    })
    h.editor.destroy()
  })

  it("applies live appearance without gutters or document and selection loss", async () => {
    const h = harness()
    const text = "# Heading\n\nFind **text** [[Note]]"
    await h.call("replaceDocument", {
      text, mode: "editedEditing", selection: [{anchor: 13, head: 17}], resetHistory: true
    })
    await h.call("executeCommand", {command: "openFind"})
    await h.call("configure", {
      mode: "editedEditing",
      preferences: {fontSize: 16, width: "wide", editedAlignment: "center", focusMode: false},
      appearance: {colorScheme: "dark", increasedContrast: false, reduceMotion: false}
    })
    const root = document.querySelector<HTMLElement>(".cm-editor")!
    const content = document.querySelector<HTMLElement>(".cm-content")!
    expect(document.querySelector(".cm-lineNumbers")).toBeNull()
    expect(document.querySelector(".cm-gutters")).toBeNull()
    expect(getComputedStyle(root).colorScheme).toBe("dark")
    expect(getComputedStyle(root).color).toBe("rgb(240, 243, 246)")
    expect(getComputedStyle(root).backgroundColor).toBe("rgba(0, 0, 0, 0)")
    expect(getComputedStyle(content).paddingLeft).toBe("28px")
    expect(document.querySelector(".cm-search")).not.toBeNull()

    await h.call("configure", {
      mode: "editedEditing",
      preferences: {fontSize: 16, width: "wide", editedAlignment: "center", focusMode: false},
      appearance: {colorScheme: "light", increasedContrast: true, reduceMotion: true}
    })
    expect(getComputedStyle(root).colorScheme).toBe("light")
    expect((await h.call("requestSnapshot", {reason: "appearance"})).result).toMatchObject({
      text,
      viewState: {selection: [{anchor: 13, head: 17}]}
    })
    h.editor.destroy()
  })

  it("preserves Edited history across rapid Original and Edited view switches", async () => {
    const h = harness()
    await h.call("replaceDocument", {
      text: "word", mode: "editedEditing",
      selection: [{anchor: 0, head: 4}], resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "bold"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "edited"})).result).toMatchObject({text: "**word**"})

    await h.call("replaceDocument", {text: "engine original", mode: "original", resetHistory: false})
    await h.call("replaceDocument", {text: "**word**", mode: "editedView", resetHistory: false})
    await h.call("replaceDocument", {text: "engine original", mode: "original", resetHistory: false})
    await h.call("replaceDocument", {text: "**word**", mode: "editedEditing", resetHistory: false})

    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "edited-undo"})).result).toMatchObject({text: "word"})
    h.editor.destroy()
  })

  it("carries mixed separator identity through grouped Undo and Redo", async () => {
    const h = harness()
    const original = "one\r\ntwo\rthree\nfour"
    await h.call("replaceDocument", {text: original, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({
      changes: {from: 3, to: 4},
      annotations: Transaction.userEvent.of("delete.backward")
    })
    view.dispatch({
      changes: {from: 3, insert: "!"},
      annotations: Transaction.userEvent.of("input.type")
    })
    const edited = "one!two\rthree\nfour"
    expect((await h.call("requestSnapshot", {reason: "grouped-edit"})).result).toMatchObject({text: edited})

    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "grouped-undo"})).result).toMatchObject({text: original})
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(false)
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "grouped-redo"})).result).toMatchObject({text: edited})
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(false)
    h.editor.destroy()
  })

  it("rebases local exact history through a disjoint native CRLF hunk", async () => {
    const h = harness()
    const original = "local\r\nexternal\r\n"
    await h.call("replaceDocument", {
      text: original,
      mode: "editedEditing",
      selection: [{anchor: 0, head: 5}],
      resetHistory: true
    })
    expect((await h.call("executeCommand", {command: "bold"})).result).toBe(true)
    await vi.waitFor(() => expect(h.sent.some(message => message.method === "patches")).toBe(true))
    const local = "**local**\r\nexternal\r\n"
    expect((await h.call("requestSnapshot", {reason: "local-before-external"})).result).toMatchObject({text: local})

    const from = local.indexOf("external")
    const applied = await h.call("applyExternalChanges", {
      mode: "editedEditing",
      changes: [{from, to: from + "external".length, insert: "outside"}]
    })
    expect(applied.error).toBeUndefined()
    expect(applied).toMatchObject({ok: true, result: {text: "**local**\r\noutside\r\n"}})
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "external-undo"})).result).toMatchObject({
      text: "local\r\noutside\r\n"
    })
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "external-redo"})).result).toMatchObject({
      text: "**local**\r\noutside\r\n"
    })
    h.editor.destroy()
  })

  it("lets CodeMirror map exact history across two temporal groups and a middle external insertion", async () => {
    const h = harness()
    const initial = "abcdef\r\nZ"
    await h.call("replaceDocument", {text: initial, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({
      changes: {from: 2, insert: "XX"},
      annotations: [Transaction.userEvent.of("input.type"), isolateHistory.of("full")]
    })
    view.dispatch({
      changes: {from: 0, insert: "YY"},
      annotations: [Transaction.userEvent.of("input.type"), isolateHistory.of("full")]
    })
    expect((await h.call("requestSnapshot", {reason: "two-groups"})).result).toMatchObject({
      text: "YYabXXcdef\r\nZ"
    })
    expect((await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 3, to: 3, insert: "E"}]
    })).ok).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "two-groups-external"})).result).toMatchObject({
      text: "YYaEbXXcdef\r\nZ"
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "two-groups-undo-2"})).result).toMatchObject({
      text: "aEbXXcdef\r\nZ"
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "two-groups-undo-1"})).result).toMatchObject({
      text: "aEbcdef\r\nZ"
    })
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "two-groups-redo-1"})).result).toMatchObject({
      text: "aEbXXcdef\r\nZ"
    })
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "two-groups-redo-2"})).result).toMatchObject({
      text: "YYaEbXXcdef\r\nZ"
    })
    h.editor.destroy()
  })

  it("applies complete external separator tokens and rejects CRLF-interior endpoints", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "a\r\nb", mode: "editedEditing", resetHistory: true})
    expect((await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 1, to: 3, insert: "\n"}]
    })).ok).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "crlf-to-lf"})).result).toMatchObject({text: "a\nb"})
    expect((await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 1, to: 2, insert: "\r"}]
    })).ok).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "lf-to-cr"})).result).toMatchObject({text: "a\rb"})
    expect((await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 1, to: 2, insert: "\r\n"}]
    })).ok).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "cr-to-crlf"})).result).toMatchObject({text: "a\r\nb"})
    const invalid = await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 1, to: 2, insert: "\n"}]
    })
    expect(invalid.ok).toBe(false)
    expect(invalid.error).toContain("separator")
    expect((h.editor as unknown as {exactText: string}).exactText).toBe("a\r\nb")
    h.editor.destroy()
  })

  it("maps an overlapped stored separator restoration away without a phantom node", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "a\r\nb", mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({
      changes: {from: 1, to: 2, insert: "X"},
      annotations: [Transaction.userEvent.of("input.type"), isolateHistory.of("full")]
    })
    expect((await h.call("requestSnapshot", {reason: "separator-replaced"})).result).toMatchObject({text: "aXb"})
    expect((await h.call("applyExternalChanges", {
      mode: "editedEditing", changes: [{from: 0, to: 2, insert: ""}]
    })).ok).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "separator-overlapped"})).result).toMatchObject({text: "b"})
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "separator-overlap-undo"})).result).toMatchObject({text: "\nb"})
    expect((h.editor as unknown as {exactText: string}).exactText).toBe("\nb")
    h.editor.destroy()
  })

  it("restores every mixed separator after a multi-line replacement Undo", async () => {
    const h = harness()
    const original = "a\r\nb\nc\rd"
    await h.call("replaceDocument", {text: original, mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.dispatch({
      changes: [
        {from: 1, to: 2, insert: "\n\n"},
        {from: 3, to: 4, insert: "\n\n"},
        {from: 5, to: 6, insert: "\n\n"}
      ],
      annotations: Transaction.userEvent.of("input.type")
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "replace-lines-undo"})).result).toMatchObject({text: original})
    expect((await h.call("executeCommand", {command: "redo"})).result).toBe(true)
    expect((await h.call("requestSnapshot", {reason: "replace-lines-redo"})).result).toMatchObject({
      text: "a\r\n\r\nb\n\nc\r\rd"
    })
    h.editor.destroy()
  })

  it("coalesces composition as one exact CRLF patch without normalizing separators", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "a\r\nb", mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", {data: ""}))
    view.dispatch({
      changes: {from: 0, to: 3, insert: "x\ny"},
      annotations: Transaction.userEvent.of("input.type.compose")
    })
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", {data: "x\ny"}))
    await vi.waitFor(() => expect(h.sent.filter(message => message.method === "patches")).toHaveLength(1))
    expect(h.sent.find(message => message.method === "patches")?.payload).toEqual({
      baseLength: 4,
      intent: "text",
      changes: [{from: 0, to: 4, insert: "x\r\ny"}]
    })
    expect((await h.call("requestSnapshot", {reason: "composition-crlf"})).result).toMatchObject({
      text: "x\r\ny"
    })
    h.editor.destroy()
  })

  it("splices a selected composition range without retaining deleted source", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "abcdef", mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart"))
    view.dispatch({
      changes: {from: 2, to: 4, insert: "X"},
      annotations: Transaction.userEvent.of("input.type.compose")
    })
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", {data: "X"}))
    await vi.waitFor(() => expect(h.sent.filter(message => message.method === "patches")).toHaveLength(1))
    expect(h.sent.find(message => message.method === "patches")?.payload).toEqual({
      baseLength: 6,
      intent: "text",
      changes: [{from: 2, to: 4, insert: "X"}]
    })
    expect((await h.call("requestSnapshot", {reason: "composition-selection"})).result).toMatchObject({text: "abXef"})
    h.editor.destroy()
  })

  it("coalesces sequential mixed-separator composition updates into one patch batch", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "a\r\nb\rc", mode: "editedEditing", resetHistory: true})
    const view = (h.editor as unknown as {view: EditorView}).view
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart"))
    view.dispatch({
      changes: {from: 2, to: 3, insert: "B\nD"},
      annotations: Transaction.userEvent.of("input.type.compose")
    })
    view.dispatch({
      changes: {from: 5, insert: "\nE"},
      annotations: Transaction.userEvent.of("input.type.compose")
    })
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", {data: "B\nD\nE"}))
    await vi.waitFor(() => expect(h.sent.filter(message => message.method === "patches")).toHaveLength(1))
    const patch = h.sent.find(message => message.method === "patches")
    expect(patch?.payload).toMatchObject({baseLength: 6, intent: "text"})
    const exact = (await h.call("requestSnapshot", {reason: "composition-sequential"})).result as {text: string}
    expect((patch?.payload as {changes: Array<{from: number, to: number, insert: string}>}).changes)
      .toEqual([{from: 3, to: 4, insert: "B\rD\rE"}])
    expect(exact.text).toBe("a\r\nB\rD\rE\rc")
    h.editor.destroy()
  })

  it("isolates consecutive task toggles to one task-shaped Undo step", async () => {
    const h = harness()
    await h.call("replaceDocument", {
      text: "- [ ] first\n- [ ] second",
      mode: "editedView",
      resetHistory: true
    })
    document.querySelectorAll<HTMLInputElement>(".tc-task-control")[0]?.click()
    document.querySelectorAll<HTMLInputElement>(".tc-task-control")[1]?.click()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect((await h.call("requestSnapshot", {reason: "two-tasks"})).result).toMatchObject({
      text: "- [x] first\n- [x] second"
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect((await h.call("requestSnapshot", {reason: "one-task-undo"})).result).toMatchObject({
      text: "- [x] first\n- [ ] second"
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect((await h.call("requestSnapshot", {reason: "two-task-undo"})).result).toMatchObject({
      text: "- [ ] first\n- [ ] second"
    })
    expect((await h.call("executeCommand", {command: "undo"})).result).toBe(false)
    h.editor.destroy()
  })

  it("clamps recovery view state and rejects invalid native decoration ranges", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "short", mode: "editedEditing", resetHistory: true})
    const restored = await h.call("restoreViewState", {
      selection: [{anchor: -10, head: 99}], mainSelectionIndex: 8, scrollTop: -20
    })
    expect(restored.result).toMatchObject({selection: [{anchor: 0, head: 5}], mainSelectionIndex: 0})
    const invalid = await h.call("setStableDecorations", {
      decorations: [{from: 0, to: 7, kind: "playback"}]
    })
    expect(invalid.ok).toBe(false)
    expect(invalid.error).toContain("range")
    h.editor.destroy()
  })

  it("snaps restored selections away from emoji surrogate interiors", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "A😀B", mode: "editedEditing", resetHistory: true})
    const restored = await h.call("restoreViewState", {
      selection: [{anchor: 2, head: 2}], mainSelectionIndex: 0, scrollTop: 0
    })
    expect(restored.result).toMatchObject({selection: [{anchor: 1, head: 1}]})
    h.editor.destroy()
  })

  it("does not rescan search counts for 30 Hz native playback decorations", async () => {
    const h = harness()
    await h.call("replaceDocument", {text: "word ".repeat(10_000), mode: "original", resetHistory: true})
    await h.call("executeCommand", {command: "openFind"})
    await new Promise(resolve => setTimeout(resolve, 0))
    const before = h.editor.diagnostics().searchCountScanCount
    for (let index = 0; index < 30; index++) {
      await h.call("setPlaybackDecoration", {
        decoration: {from: index, to: index + 1, kind: "playback"}
      })
    }
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(h.editor.diagnostics().searchCountScanCount).toBe(before)
    h.editor.destroy()
  })

  it("keeps 200 edits responsive in a 10000-word document", async () => {
    const h = harness()
    await h.call("replaceDocument", {
      text: "word ".repeat(10_000), mode: "editedEditing",
      selection: [{anchor: 0, head: 4}], resetHistory: true
    })
    const samples: number[] = []
    for (let index = 0; index < 200; index++) {
      const started = performance.now()
      await h.call("executeCommand", {command: "bold"})
      samples.push(performance.now() - started)
    }
    const sorted = [...samples].sort((a, b) => a - b)
    expect(sorted[Math.ceil(sorted.length * .95) - 1]).toBeLessThan(16.7)
    expect(Math.max(...samples)).toBeLessThan(50)
    await new Promise(resolve => setTimeout(resolve, 20))
    const performanceReport = h.sent.find(message => message.method === "performance")
    expect(performanceReport?.payload).toMatchObject({
      kind: "input",
      sampleCount: 200,
      documentLength: 50_000
    })
    const reportIndex = h.sent.indexOf(performanceReport!)
    expect((await h.call("executeCommand", {command: "italic"})).ok).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(h.sent.slice(reportIndex + 1).some(message => message.method === "patches")).toBe(true)
    expect(h.sent.map(message => message.sequence)).toEqual(h.sent.map((_, index) => index))
    h.editor.destroy()
  })
})
