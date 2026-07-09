# PRD-5 — Milestone 5: Audio Lifecycle, Diarization & Voice Memos Parity

> **Before starting:** read `PRD-5-start-here.md` (written at the end of Milestone 4). Full product context: [master-prd-backup.md](master-prd-backup.md) §5.3 (TRN-6), §5.8, §5.10, §5.11, §5.12, §11. Do not start until the human confirms Milestone 4's checklist is verified.

## Operating procedure — orchestrate to preserve context

This milestone is large; implement it by delegating to subagents rather than doing all implementation in the main conversation, so the coordinating context never runs out mid-milestone.

- The main conversation acts as **orchestrator**: it reads the PRDs/handoff, decides the work breakdown, launches subagents, reviews their reports, and talks to the human. It should not write most of the code itself.
- Use **forked subagents that inherit the full conversation context** and run on the **same (top-tier) model as the orchestrator** — never delegate implementation to a smaller/cheaper model; quality is not to be sacrificed for context savings.
- Give each subagent one bounded work package (e.g. "delete-audio-keep-note flow", "diarization engine + rendering") with: the exact files to read first, the decisions already made (verbatim), what to build, and the requirement to build/test before reporting back.
- Run packages **sequentially** when they regenerate the Xcode project or build (xcodegen/xcodebuild must not run concurrently); parallelize only pure-code or pure-research packages that touch disjoint files.
- Each subagent reports back a concise summary (files created/changed, decisions taken, test/build status, open risks); the orchestrator records milestone state in persistent memory after each package so compaction never loses progress.
- Interactive checklist verification with the human is always done by the orchestrator, never a subagent.

## Goal

Complete v1. This milestone delivers the app's signature move — **delete the audio, keep the knowledge** — plus speaker detection, audio trim, the remaining organization and export features, and final polish. Exit criterion is the master PRD's §11 success scenario running end-to-end.

## Scope

**In:** delete-audio-keep-note, audio in Recently Deleted, trim, speaker diarization + renaming, favorites/duplicate/sort, search filters, vocabulary re-apply, export entry to folder, share audio, storage overview, settings completion, keyboard shortcuts pass.

**Out (declared done-for-v1 without them):** replace re-record (AUD-4), Enhance Recording (AUD-5), tags, diff view, bulk export, global hotkey, cloud engines, sync. (Live transcription was originally out for v1 but shipped early as an M3 addendum — see PRD-3.)

## Requirements

### Delete audio, keep transcript (AUD-1, AUD-2 completion)
- **AUD-1:** A "Delete Audio…" action on every entry with audio (overflow menu + storage overview). Warning dialog states the audio file's size, that the transcript is kept, and that the audio is recoverable from Recently Deleted for 30 days.
- On confirm: `audio.m4a` and `waveform.json` move to `.trash/` (reusing the M1 trash manifest); frontmatter gets `audio_deleted: true`.
- The entry becomes a plain note: waveform/transport hidden, audio-dependent actions (retranscribe, trim, speaker detection, share audio) greyed out with an explanatory tooltip. Both transcript layers, editing, search, and Copy as Markdown keep working exactly as before.
- Restoring the audio from Recently Deleted fully reverses the state (controls return, `audio_deleted` cleared).
- The 30-day purge (M1) covers audio-only trash items.

### Trim (AUD-3)
- Select a range on the waveform; trim to selection (crop) with a confirmation that this re-transcribes the file. The pre-trim audio goes to `.trash/` (recoverable); the trimmed file becomes the entry's audio; retranscription is enqueued automatically; prior original archived per M3 rules; a hand-edited layer is left untouched with the standard divergence notice.

### Speaker diarization (TRN-6)
- The speaker-detection toggle in transcribe/retranscribe dialogs goes live, backed by FluidAudio's diarization stack, exposed via the M3 engine capability flag (engines without support show the toggle disabled).
- Diarized transcripts fill `speaker` in the JSON segments; the original layer renders speaker-labeled sections ("Speaker 1", "Speaker 2").
- Speaker rename: "Speaker 1" → a chosen name, applied across the entry's rendered views and stored in entry metadata (the JSON keeps stable machine ids).
- Regenerated `transcript.md` for never-edited entries includes speaker labels as markdown (e.g. `**Alice:**` paragraphs).

### Organization (LIB-3, LIB-4)
- Favorite toggle (frontmatter-backed) with a Favorites smart filter in the sidebar; Duplicate Entry (new timestamp folder, all files copied, title "… copy").
- Sort options for the entry list: date (default), duration, title, recently edited.

### Search filters & vocabulary re-apply (SRCH-5, VOC-4)
- **SRCH-5:** Vault search gains filters: by folder, date range, has-audio vs note-only, favorites. Filters combine with exact/fuzzy text queries.
- **VOC-4:** Adding a word to the custom vocabulary offers to re-run the correction backstop across existing transcripts, with a preview of affected entries before applying. Corrections follow the M3 rules (`corrected_from` in the JSON, hand-edited `transcript.md` never touched).

### Export & share (EXP-2, EXP-3)
- **EXP-2:** "Export Markdown…" writes the chosen layer as a clean `.md` to a user-picked folder (e.g. an Obsidian vault), with options: include speaker labels, include paragraph timestamps. Remembers the last destination.
- **EXP-3:** Share the audio file via the macOS share sheet; Quick-Look-style drag-out of the audio from the detail view is a plus.

### Storage overview & settings completion (AUD-6, SET-1, SET-2)
- Settings gains a Storage pane: total vault size, audio vs text split, largest-audio entries ranked, each with a Delete Audio… button (the AUD-1 flow inline).
- Recently Deleted retention (default 30 days) configurable; all settings panes from the master PRD (SET-1/SET-2) complete and functional.

### Final polish
- Keyboard shortcut pass per master PRD §7: ⌘N new recording, space play/pause, ⌘F in-note find, ⌘⇧F vault search, plus a menu bar with everything reachable.
- Empty states (empty vault, empty folder, empty trash, no search results) are designed, not blank.
- App icon and About window.

## Decisions already made
- Delete Audio trashes rather than hard-deletes (30-day recovery) — this supersedes any wording implying immediate permanent deletion.
- Trim is the only audio-mutating operation in v1; it always re-transcribes.
- Diarization ships if FluidAudio's quality is acceptable on real two-speaker audio; if it is genuinely not, it may be descoped **only with the human's explicit sign-off**, documented in the final handoff.

## Definition of done
- All requirements implemented; unit tests for: audio-delete/restore state transitions, trim + retrigger flow, favorite/sort logic, export file naming/options. `xcodebuild test` passes.
- The master PRD §11 success criteria pass in full (final checklist item below).

## Verification checklist (human-run — completes v1)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: present one item at a time, give the human the exact steps and materials needed, wait for their pass/fail answer, and keep a running tally. On a fail: fix it, then re-verify that item plus any already-passed items the fix could have affected. Write the handoff document only after the human confirms every item.

- [ ] Delete Audio on a transcribed entry: warning shows the real file size; after confirm, waveform/transport disappear, retranscribe/trim/share grey out with tooltips, and both transcript layers still view/edit/search/copy normally.
- [ ] The freed space is real (compare vault folder size in Finder before/after) and the audio sits in `.trash/`.
- [ ] Restore the audio from Recently Deleted: playback, waveform, and all audio actions return.
- [ ] Trim a recording to a middle selection: confirmation mentions retranscription; trimmed audio plays correctly; new transcript matches the kept region; pre-trim audio is recoverable from Recently Deleted.
- [ ] Record or import a genuine two-person conversation; retranscribe with speaker detection ON: transcript shows Speaker 1/2 sections that match reality reasonably well.
- [ ] Rename Speaker 1 to a real name: label updates throughout the entry; the JSON keeps stable ids (spot-check in Finder).
- [ ] Favorite three entries; the Favorites filter shows exactly those; unfavorite works. Duplicate an entry: independent copy, editing it doesn't touch the source.
- [ ] Each sort option orders the list correctly.
- [ ] Search filters: restrict a query to one folder, a date range, and note-only entries — each narrows results correctly and combines with the fuzzy toggle.
- [ ] Add a new vocabulary word that appears mistranscribed in an old entry: the re-apply flow previews the affected entries, applying fixes the old transcript, and a hand-edited entry's `transcript.md` is left untouched.
- [ ] Export Markdown to a real Obsidian vault folder with speaker labels on: the note opens in Obsidian rendering correctly.
- [ ] Share sheet sends the audio (test AirDrop or Messages).
- [ ] Storage pane totals roughly match Finder; deleting audio from its ranked list works and updates the numbers.
- [ ] All keyboard shortcuts work; every feature is reachable from the menu bar.
- [ ] Empty vault, empty folder, empty trash, and no-results search all show designed empty states.
- [ ] `xcodebuild test` passes.
- [ ] **v1 acceptance (master PRD §11):** in one sitting — record a thought → it transcribes automatically → clean it up in markdown → delete the audio → quit, relaunch, find it by search → Copy as Markdown into Obsidian. Then: open the vault directly in Obsidian (all notes render), and confirm every artifact on disk is human-readable and sensibly named in Finder.

## Handoff (required, after the checklist is verified)

Write **`PROJECT-STATE.md`** — the living document for all post-v1 work: final architecture and file map; every deviation from the master PRD across all five milestones (consolidated from the start-here docs); known issues and tech debt ranked; the deferred list (P2s and anything descoped) with pointers to where each would hook in; and how to build, test, and release. Future milestones (cloud engines, sync, AI features) start from this document plus [master-prd-backup.md](master-prd-backup.md).
