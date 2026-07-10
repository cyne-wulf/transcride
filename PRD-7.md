# PRD-7 — Milestone 7: The Editor Becomes a Workbench

> **Before starting:** read `PRD-7-start-here.md` (written at the end of Milestone 6) and [master-prd-backup.md](master-prd-backup.md) §5.7, §5.10. **Do not start until the human confirms Milestone 6's checklist is verified.** This doc is sized for a single ~200K-token implementation session; orchestrate with full-context forks (PRD-5 procedure) if context runs low. New actions register in Milestone 6's CommandRegistry — no orphan shortcuts.

## Goal

Make the markdown editor the reason the app feels like an IDE rather than a notepad: text that styles itself as you write, structure you can navigate (outline, links, tags), and honest tooling over the two-layer model (diff). At the end of this milestone the edited layer is somewhere a knowledge worker *prefers* to write, and notes connect to each other the way they do in Obsidian.

## Scope

**In:** live markdown styling, smart list/task editing, find & replace, outline panel, editor typography preferences + focus mode, wikilinks with autocomplete + backlinks (LNK-1/2), tags (LIB-5), diff view (EDT-5).
**Out:** motion/appearance polish of these panels (Milestone 9); menu-bar capture (Milestone 8); AI anything (post-program). Obsidian-syntax *preservation* is a v1 guarantee already — this milestone adds rendering/affordances on top, never new mangling.

## Requirements

### Live markdown styling (EDX-1)
- The `MarkdownBodyEditor` styles as you type — headings sized by level, **bold**/*italic* rendered with their delimiters dimmed (visible, never hidden: this is "live preview lite", not WYSIWYG), inline code in mono with a subtle background, blockquotes indented with a bar, links/wikilinks tinted. Styling is attribute-only over the plain text: the saved file remains byte-exact, undo/redo and the M4 dedicated undo manager are untouched, and styling latency must be imperceptible on a 10,000-word note (restyle only the edited paragraph ± neighbors, not the whole document, on each keystroke).
- The read-only original layer gets the same visual treatment for its (speaker-label) markdown.

### Smart editing (EDX-2)
- Return inside a `- ` / `1. ` / `> ` block continues it; Return on an empty item ends the block. Tab/⇧Tab indent/outdent list items. `- [ ]` renders a real checkbox glyph; clicking it toggles `[ ]`↔`[x]` in the text (an edit like any other — forks/autosaves normally).

### Find & replace (EDX-3)
- The M4 ⌘F bar gains a replace row (⌥⌘F): replace-one, replace-all (single undo step), match count, works only in the edited layer while editing (original is immutable — find still works there, replace controls hidden).

### Outline panel (EDX-4)
- A toggleable sidebar panel listing the note's headings hierarchically; click scrolls the editor there; the current section highlights while scrolling. Works on both layers.

### Typography & focus (EDX-5)
- Settings (and palette commands): editor font size (⌘+/⌘−/⌘0), line-width presets (narrow/wide/full), and a focus mode that dims all paragraphs but the one with the caret. All persist; Zen recording is untouched.

### Wikilinks (LNK-1) and backlinks (LNK-2) — new
- **LNK-1:** typing `[[` in the editor pops fuzzy entry-title autocomplete (switcher-backed); `[[Title]]` and `[[Title|alias]]` are tinted and ⌘-clickable to open that entry (in a tab, pushing navigation history). Unresolved links render distinct (dotted underline); following one offers to create a note-only entry with that title. Links resolve by entry title, case-insensitive.
- **LNK-2:** a "Linked mentions" panel on each entry lists every note whose edited layer links here, with snippet + click-to-open. Renaming an entry updates inbound `[[links]]` across the vault (single undoable pass, atomic per-file writes, hand-edited or not — links are user content); the confirm sheet lists affected notes. Index lives beside the search index (rebuildable cache; deleting it loses nothing).

### Tags (LIB-5, master P2)
- `#tag` tokens in the edited layer (word-boundary, Obsidian rules: letters/digits/-/_/nested `a/b`) are tinted; a sidebar tag pane lists all tags with counts; clicking one filters the entry list; tags join the ⌘⇧F filter row (M5 SRCH-5) and combine with existing filters. Frontmatter `tags:` (a real YAML list, per the Obsidian-compat doc) is read and unioned with body tags; the tag pane writes frontmatter only through the line-preserving document.

### Diff view (EDT-5, master P2)
- A "Compare Layers" command on forked entries: side-by-side original vs edited with word-level diff highlighting (insertions/deletions tinted), read-only, synchronized scrolling, a jump-to-next-change control. Uses the same whitespace normalization philosophy as `isGeneratedBody` so pure-reflow edits don't light up as changes.

## Decisions already made (do not relitigate)
- Live preview never hides syntax characters (no cursor-proximity reveal tricks) — dimmed delimiters, v1 of the concept. WYSIWYG is explicitly out of the program.
- Wikilinks resolve by title, not path; ambiguous titles resolve to most-recently-edited and the link gets a tooltip noting ambiguity. (Folder-qualified `[[Folder/Title]]` accepted but not auto-generated.)
- Rename-updates-inbound-links is **on** and not optional; the link index must therefore be correct before rename commits (block rename with a progress state if the index is mid-rebuild).
- Tags are parsed from the **edited layer and frontmatter only** (original is engine output — never scanned for tags).
- Diff is read-only in this milestone (no partial-revert buttons; that's post-program if ever).

## Definition of done
- All requirements implemented; unit tests for: markdown-styling range invalidation (paragraph-local restyle), list-continuation/checkbox toggling edits, wikilink parsing/resolution/ambiguity, rename link-rewrite planning, tag extraction (body + frontmatter union), diff hunk computation. `xcodebuild test` passes, no regressions.
- Styling keystroke latency imperceptible on a 10,000-word note; link index rebuild on TestVault-1000 < 5 s cold.

## Verification checklist (human-run)

**Interactive, one item at a time, human confirms each** (same protocol as prior milestones). *Preparation: TestVault-1000 fixture; one real entry with a long hand-edited note.*

- [ ] Type a document using `#`/`##` headings, bold, italic, inline code, a blockquote, and a list: everything styles live as typed, delimiters dimmed but visible; the saved `.md` in Finder is byte-plain markdown.
- [ ] Styling stays instant while typing mid-document in a very long note (paste a 10,000-word body first).
- [ ] Return continues list and quote blocks; empty-item Return exits; Tab/⇧Tab re-nest a list item; a `- [ ]` checkbox click flips to `- [x]` in the file and forks/autosaves normally.
- [ ] ⌥⌘F: replace one occurrence, then replace-all; a single ⌘Z undoes the replace-all; the original layer shows find but no replace controls.
- [ ] Outline panel lists the note's headings; clicking jumps; scrolling tracks the current section; works on the original layer of a diarized entry.
- [ ] ⌘+ / ⌘− / ⌘0 resize the editor; line-width presets apply; focus mode dims all but the caret paragraph; all survive relaunch.
- [ ] Type `[[` and 3 letters: autocomplete offers the right entry; accept, ⌘-click the link — it opens in a new tab and ⌘[ returns. An `[[Unresolved Link]]` renders dotted; following it offers creation and creates a working note-only entry.
- [ ] Link three notes to a target entry; the target's Linked-mentions panel lists all three with snippets; click one to jump.
- [ ] Rename the target entry: confirm sheet lists the three linking notes; after rename all three files on disk show the new title in their links; ⌘Z in the renamed entry is unaffected.
- [ ] Add `#projectx` in two entries and `tags: [projectx]` frontmatter in a third: tag pane shows projectx (3); clicking filters the list to those three; ⌘⇧F filtered to the tag + a text query narrows correctly.
- [ ] Open the vault in Obsidian: wikilinks navigate, tags appear in its tag pane, checkboxes toggle — nothing Transcride wrote confuses it (Tier-2 compat holds).
- [ ] Compare Layers on a hand-edited entry: word-level changes highlighted both sides, synced scroll, jump-to-next-change cycles; a whitespace-only edit shows an empty diff.
- [ ] Regression: karaoke highlight, click-to-seek, search cue, and Copy as Markdown still correct on a diarized original layer (styling didn't shift coordinates).
- [ ] Regression: external edit in Obsidian while Transcride runs still round-trips losslessly (unknown frontmatter, callouts, `==highlights==` survive).
- [ ] All new commands appear in the palette and menu bar with working shortcuts (registry check).
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-8-start-here.md`**: state summary; build/run/test; updated file map; **the contracts Milestone 8 consumes** — the notification/queue hooks (where "transcription finished" lands, for CAP-2), the recording pipeline seams (`RecorderService` tap, seam function names, for REC-7/AUD-4/AUD-5), and the waveform-selection component from M5 trim (AUD-4 reuses it); link/tag index schema for completeness; deviations; known issues. Append deviations to `PROJECT-STATE.md`. Close with the fresh-model assumption line.
