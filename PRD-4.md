# PRD-4 — Milestone 4: The Workbench — Synced Playback, Editing & Search

> **Before starting:** read `PRD-4-start-here.md` (written at the end of Milestone 3). Full product context: [master-prd-backup.md](master-prd-backup.md) §5.6, §5.7, §5.9, §5.11 (EXP-1), §7. Do not start until the human confirms Milestone 3's checklist is verified.

## Operating procedure — orchestrate to preserve context

This milestone is large; implement it by delegating to subagents rather than doing all implementation in the main conversation, so the coordinating context never runs out mid-milestone.

- The main conversation acts as **orchestrator**: it reads the PRDs/handoff, decides the work breakdown, launches subagents, reviews their reports, and talks to the human. It should not write most of the code itself.
- Use **forked subagents that inherit the full conversation context** and run on the **same (top-tier) model as the orchestrator** — never delegate implementation to a smaller/cheaper model; quality is not to be sacrificed for context savings.
- Give each subagent one bounded work package (e.g. "search index + service", "editor layer UI") with: the exact files to read first, the decisions already made (verbatim), what to build, and the requirement to build/test before reporting back.
- Run packages **sequentially** when they regenerate the Xcode project or build (xcodegen/xcodebuild must not run concurrently); parallelize only pure-code or pure-research packages that touch disjoint files.
- Each subagent reports back a concise summary (files created/changed, decisions taken, test/build status, open risks); the orchestrator records milestone state in persistent memory after each package so compaction never loses progress.
- Interactive checklist verification with the human is always done by the orchestrator, never a subagent.

## Goal

This milestone delivers the product's soul — the IDE-for-transcriptions experience. Audio and text become one surface: playback highlights the current word and follows it, clicking a word seeks the audio, the transcript is editable as a layered markdown note with the original always recoverable, and the whole vault is full-text searchable with jump-to-moment. After this milestone the app is usable end-to-end for its core purpose.

## Scope

**In:** karaoke word-highlight + auto-scroll, click-word-to-seek, waveform↔text sync, Skip Silence, layered editing (original/edited, toggle badge), markdown editing, Copy as Markdown, vault-wide search (exact default + fuzzy toggle) with jump-to-position/moment, search index.

**Out:** delete-audio-keep-note and Recently Deleted audio flows (M5), diarization display (M5), export-to-folder (M5), tags/favorites (M5).

## Requirements

### Synced playback (PLY-1, PLY-2, PLY-5)
- **PLY-1:** During playback, the word at the playhead is visibly highlighted; the viewport auto-scrolls to keep it comfortably in view. Highlight drift < 100 ms. Manual scrolling pauses auto-follow and shows a "resume following" affordance (Voice Memos/teleprompter pattern); auto-follow resumes on click or on seek.
- **PLY-2:** Clicking any word seeks the audio to that word's start time (works while playing or paused). Scrubbing the waveform scrolls the text to match (M2 scrubbing + this milestone's mapping).
- **PLY-5:** **Skip Silence** toggle in the transport bar: playback jumps gaps between consecutive words longer than a threshold (~1.5 s, tunable constant). State persists per app, not per entry.
- Sync applies to the **original layer**. In the edited layer, best-effort highlight is acceptable where text still aligns; edited regions that no longer map to audio simply don't highlight (no crashes, no wrong-word flicker).

### Layered editing (EDT-1, EDT-2, EDT-3, EDT-4)
- **EDT-2:** Two layers per entry: immutable **Original** (rendered from `transcript.original.json`) and editable **Edited** (`transcript.md`). A toggle badge sits next to the Copy as Markdown button, top-right of the note view, showing the active layer; Original view is read-only with visibly distinct (subtle) styling. Entries whose `transcript.md` was never hand-edited show no badge until the first edit forks the layer (EDT-3).
- **EDT-1:** The edited layer is a real markdown editor: typing, headings, lists, bold/italic, undo/redo. Autosave (debounced, atomic) to `transcript.md`; frontmatter preserved. Obsidian must render the result correctly.
- **EDT-4:** Confirm the M3 retranscribe rule end-to-end: retranscribing an entry with a hand-edited layer never touches `transcript.md` and notifies that the original changed underneath.
- A `hand_edited: true` frontmatter flag (or equivalent, per M3 handoff) distinguishes forked entries.

### Copy as Markdown (EXP-1)
- Top-right button copies the **currently viewed layer** as clean markdown (frontmatter stripped) to the clipboard, with brief confirmation feedback.

### Search (SRCH-1..SRCH-4)
- **SRCH-1:** Vault-wide full-text search (⌘⇧F) over both layers of every entry; results grouped by entry showing title + matching snippet with the hit highlighted; edited-layer hits rank above original-only hits.
- **SRCH-2:** A prominent **fuzzy toggle switch** on the search bar. **Exact substring match (case-insensitive) is the default.** Fuzzy mode tolerates typos/close spellings (e.g. trigram or edit-distance based). Toggle state persists.
- **SRCH-3:** Choosing a result opens the entry, scrolls to and highlights the matched text; if the entry has audio and the match maps to a word with timing, the playhead cues to that moment (not auto-playing).
- **SRCH-4:** Index is SQLite FTS5 (or equivalent) in Application Support or a vault dot-folder — a rebuildable cache. It updates incrementally on entry changes (including external edits via the FS watcher) and rebuilds automatically if deleted/corrupt. Deleting it loses nothing.
- Also: in-note find (⌘F) with match cycling in the detail view.

## Decisions already made
- Exact match is the default; fuzzy is opt-in via the switch. Non-negotiable (explicit in the vision).
- The original layer is never editable through any UI path.
- Search index lives outside the vault's user-visible files (dot-folder or App Support).

## Definition of done
- All requirements implemented; unit tests for: word-index↔character-position mapping, silence-gap computation, exact vs fuzzy query behavior on fixture text, index incremental-update on file change, markdown round-trip (edit → save → reload → identical). `xcodebuild test` passes.
- Highlight sync verified at 0.5× and 2× speeds; search < 200 ms on a 1,000-entry fixture vault.

## Verification checklist (human-run — all boxes required before Milestone 5)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: present one item at a time, give the human the exact steps and materials needed, wait for their pass/fail answer, and keep a running tally. On a fail: fix it, then re-verify that item plus any already-passed items the fix could have affected. Write the handoff document only after the human confirms every item.

Use a clear multi-paragraph recording from M3 testing, plus the 500–1,000-entry fixture vault for search scale.

- [ ] Play a transcribed memo: current word highlights and tracks accurately at 1×; still sane at 0.5× and 2×.
- [ ] Auto-scroll follows the highlight; scrolling up mid-playback pauses following and shows the resume affordance; clicking it snaps back to the live word.
- [ ] Click a word mid-transcript: audio jumps there (playing and paused both). Click a word near the end of a long file: no lag or misalignment.
- [ ] Scrub the waveform: transcript view scrolls to match the playhead position.
- [ ] Record a memo with deliberate 3–4 s pauses; Skip Silence on: playback hops the gaps; off: plays them.
- [ ] Type into a transcript: badge appears showing Edited layer; changes autosave (verify in Finder that `transcript.md` updated; frontmatter intact).
- [ ] Toggle to Original: read-only, shows the untouched engine output; toggle back: your edit is still there.
- [ ] Add headings/lists/bold in the edited layer; open the vault in Obsidian: the note renders correctly, frontmatter recognized.
- [ ] Retranscribe a hand-edited entry with a different model: edited layer untouched, notification shown, Original view shows the new transcript.
- [ ] Copy as Markdown on each layer: pasted result matches the viewed layer, no frontmatter.
- [ ] Undo/redo works through a multi-step edit session.
- [ ] ⌘⇧F, exact mode: search a distinctive phrase you spoke — the right entry surfaces; clicking the result opens it, highlights the phrase, and cues the audio to that moment.
- [ ] Search a word that appears only in your edited text (not the original): found, edited-hit ranked first.
- [ ] Fuzzy toggle on: a misspelled query ("transcirde") still finds the target; exact mode: it doesn't. Toggle state persists across relaunch.
- [ ] Search stays < ~200 ms perceived on the 1,000-entry fixture vault.
- [ ] Edit a `transcript.md` in an external editor; search finds the new text within a few seconds (index incrementally updated).
- [ ] Delete the index file; relaunch; search still works (index rebuilt).
- [ ] ⌘F in-note find cycles matches within the open entry.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-5-start-here.md`**: updated file map and build/run/test; the word↔character mapping design and its limits in edited layers; the layer/fork model and `hand_edited` semantics; the search index schema, location, and update triggers; the Skip Silence gap model (M5's trim feature must reconcile with word timings); UI component inventory for the detail view (M5 adds/greys controls on it); known issues. M5 finishes lifecycle features and Voice Memos parity on top of your surfaces.
