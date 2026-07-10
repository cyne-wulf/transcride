# PRD-5 Start Here — Milestone 4 handoff

> Assume you are a fresh model with zero context beyond PRD-5.md and this document.

## Project summary

Transcride is a native macOS (Swift 6 + SwiftUI, macOS 15+, Apple Silicon, App Sandbox) voice recorder + transcription workbench whose data layer is a plain-folder **vault**. M1 = vault foundation; M2 = Voice Memos core (recording, import, playback); M3 = automatic local transcription (engines, queue, data contract). Milestone 4 (verified 2026-07-09, tag `milestone-4`) delivered the workbench: karaoke word-highlight with auto-follow, click-word-to-seek, waveform↔text sync, Skip Silence, the layered Original/Edited markdown editor with explicit-save + debounced-autosave, Copy as Markdown, vault-wide FTS5 search (exact default, fuzzy toggle) with jump-to-position *and* jump-to-audio-moment, and ⌘F in-note find. Verification passed 19/19 checklist items; three items failed on first attempt and were fixed during the quiz (undo/redo, search cue in edited notes, post-recording refresh jank — details under Known issues fixed).

**Read PRD-5.md and PRD-4.md's "Operating procedure — orchestrate to preserve context" before starting**: implementation is delegated to full-context forked subagents on the same top-tier model, run sequentially whenever they build; the orchestrator reviews reports, records state in memory, owns commits, and runs checklist verification with the human personally.

## Build / run / test

- `project.yml` (XcodeGen) defines the project; `Transcride.xcodeproj` is generated — **never edit it by hand**; run `xcodegen generate` after adding/removing files.
- Build/test: `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build` / `… test` — **142 tests, 24 suites**. The test target compiles `Transcride/Core` directly with no app host and no packages — Core must never import FluidAudio/WhisperKit/AppKit/SwiftUI (Foundation + SQLite3 are fine).
- Run: after every build, deploy and launch from /Applications (user preference):
  `ditto ~/Library/Developer/Xcode/DerivedData/Transcride-*/Build/Products/Debug/Transcride.app /Applications/Transcride.app && pkill -x Transcride; open /Applications/Transcride.app`
- Fixtures: `Scripts/make-fixture-vault.sh [count] [dir]`. `TestVault-500/` is the user's live test vault (real transcribed/hand-edited entries); `TestVault-1000/` was generated for search-scale verification. Both gitignored.
- `obsidian-compatibility.md` (repo root, untracked) captures the Obsidian-compat tiers; Tier 2 items (audio embeds `![[recording.m4a]]`, `tags` as a real YAML list) fold naturally into M5's LIB-5/export work.

## File map (M4 additions; PRD-4-start-here.md's M1–M3 map is still accurate)

**Transcride/Core** (pure, unit-tested):
- `TranscriptWordMap.swift` — the word↔character↔time mapping (see below).
- `SilenceGap.swift` — silence-gap model for Skip Silence (see below).
- `TranscriptEditDocument.swift` — frontmatter-preserving edit primitive: `replaceBody` (no-op assignment does not fork; first real edit sets `hand_edited: true`), `markHandEdited`/`clearHandEdited`, atomic `save`, and `isForked(_:comparedTo:)` — explicit flag wins, generated-body comparison is the backstop for external editors that don't know the flag.
- `VaultSearchIndex.swift` — the SQLite search cache (see below).

**Transcride/App**:
- `PlayerService.swift` (extended) — pitch-preserved speed ladder `speeds = [0.5…4.0]` + `stepSpeed(±1)`; `skipSilence` persisted under UserDefaults key `skipSilence`; `setTranscriptForSilenceSkipping(_:)` installs gaps; the 30 Hz periodic observer performs gap jumps via an internal seek that deliberately does **not** bump `seekRevision` (so silence skips don't re-enable transcript follow). `seekRevision` increments on every *user* seek — transcript views key auto-follow resume on it.
- `AppModel.swift` (extended) — vault search state (`vaultSearchQuery/Results/IsRunning/Error`, `fuzzyVaultSearch` persisted, `searchIndexState`), `transcriptNavigationRequest: TranscriptNavigationRequest?` (identity-keyed search-hit navigation), `externalVaultRevision` (bumped only for FSEvents changes) vs `transcriptRevision` (bumped only when a transcription lands), `selectSearchHit`, `requestInNoteFind`, and the single local **key monitor** (`installKeyMonitor`) that owns all plain-key shortcuts: Space (recorder pause/resume, else play/pause), ⇧Space handled by menu, Z (Zen), ⇧⌫ (delete entry), ⌘F (in-note find), ⌘⇧F (vault search), `[`/`]` (speed step), `\` (speed 1×). It defers to any editable NSTextView so typing always wins. `refresh(apply:)` runs a closure in the same main-actor turn that publishes a rescanned snapshot — required whenever a selection change depends on the rescan (see Known issues fixed).
- `VaultService.swift` (extended) — `initializeSearchIndex()`, `synchronizeSearchIndex(changedAbsolutePaths:)`, `synchronizeSearchEntry(at:)`, `search(_:fuzzy:)`, `saveTranscriptBody(_:markHandEdited:clearHandEdited:atEntryPath:)`.

**Transcride/UI**:
- `TranscriptWorkbenchView.swift` — the layered note surface inside the detail view (component inventory below). Contains `SyncedOriginalTextView` (NSViewRepresentable, read-only, karaoke highlight + click-to-seek + user-scroll detection) and `MarkdownBodyEditor` (NSViewRepresentable NSTextView; **owns a dedicated `UndoManager` via `undoManager(for:)`** — hosted text views otherwise resolve undo through the SwiftUI window and ⌘Z is dead; external text replacement clears the undo stack).
- `VaultSearchView.swift` — ⌘⇧F overlay: query field, prominent fuzzy toggle, grouped results with highlighted snippets.
- `EntryDetailView.swift` (reworked) — Voice Memos-style layout (inventory below).
- `KeyboardShortcutsView.swift` — Help → Keyboard Shortcuts window (⌘?); update it when adding shortcuts.

**TranscrideTests** new/extended suites: `TranscriptSyncTests` (word map + silence gaps + edited-match cueing), `TranscriptEditDocumentTests`, `VaultSearchIndexTests`.

## Word ↔ character ↔ time mapping (`TranscriptWordMap`) and its edited-layer limits

- Built from `TranscriptOriginal.allWords`. Whitespace-only words are skipped **without renumbering** (span.wordIndex stays the index into `allWords`). Words are joined with `" "`, or `"\n\n"` when `word.start − previousEnd ≥ TranscriptMarkdown.paragraphPauseThreshold` (2.0 s) — this makes `renderedText` **byte-identical to `TranscriptMarkdown.body(from:)`**, asserted by test. All offsets are UTF-16, so span ranges convert to `NSRange` directly.
- Lookups: `wordIndex(containingUTF16Offset:)` (strict — separators return nil), `wordIndex(atOrBeforeUTF16Offset:)` (nearest previous; used for clicks/search offsets on separators), `wordIndex(atTime:)` (half-open `[start, end)`, gaps resolve to nearest previous word, time before first word → nil), `startTime(forWordAt:)`, `startTime(atOrBeforeUTF16Offset:)`.
- **Original layer**: search-index content for the original layer is the same rendered text, so `SearchHit.matchRange` (UTF-16 in full layer content) indexes into the map directly — highlight and audio cue share one coordinate space.
- **Edited layer**: character offsets are meaningless after real edits. Two best-effort mechanisms, both silent-fail by design (PRD: no crashes, no wrong-word flicker):
  - *Karaoke highlight* (`editedHighlightRange` in TranscriptWorkbenchView): enabled only while the body is still exactly the rendered original plus surrounding whitespace; any real edit disables it entirely.
  - *Search cue* (`startTime(forMatch:inEditedBody:)`): re-locates the matched phrase in `renderedText` by **case-insensitive occurrence ordinal** (the Nth "go" in the body cues the Nth spoken "go"). Text that exists nowhere in the original (user-typed additions) returns nil — found by search, highlighted in text, but no audio moment.
- Word-click-to-seek exists only in the original layer (`SyncedOriginalTextView.onCharacterClick`).

## Layer / fork model and `hand_edited` semantics

- Two layers per entry: immutable **Original** rendered from `transcript.original.json`; editable **Edited** = the markdown body of `transcript.md` (`FrontmatterDocument` is line-preserving — unknown frontmatter survives byte-for-byte, which is what keeps Obsidian round-trips safe).
- `viewedLayer` resolution: no original → edited; editing → edited; **not forked → original** (unforked entries show the synced original with *no* badge — the layer toggle appears only after the first fork); else the user's `activeLayer` toggle.
- Fork = `hand_edited: true` in frontmatter, set by `TranscriptEditDocument.replaceBody` on the first real change. `isForked` also treats a non-generated, non-stub body as forked (external-edit backstop). If an edit session that *began unforked* ends with the body back to the original text, Save calls `clearHandEdited` — a debounced intermediate write may already have set the flag, and Save must be able to restore the genuinely unforked state.
- Edit flow: **Edit** button → `beginEditing`; keystrokes → `applyUserEdit` → 600 ms debounced atomic autosave (`saveTranscriptBody`); **Save** button → `saveAndFinishEditing` (cancels/awaits pending save, final write, exits editing). The detail view's reload `taskKey` deliberately excludes `entry.snippet` so an in-app autosave never reloads the editor over newer unsaved keystrokes; `externalVaultRevision` (FSEvents only) is what reloads on genuine external edits.
- Retranscribe (M3 rule, verified end-to-end in M4): a hand-edited `transcript.md` is never touched — `Outcome.markdownLeftAlone` drives the "Original refreshed, Edited untouched" notice.

## Search index — schema, location, triggers

- **Location**: `~/Library/Application Support/Transcride/Search/<fnv1a64-of-vault-path>.sqlite` (one DB per vault; `VaultSearchIndex.defaultDatabaseURL(forVault:)`). Pure cache: deleting it loses nothing; missing/invalid DB rebuilds from the vault on next open.
- **Schema**: `search_records(entry_path, layer, title, content)` + `search_fts` — an FTS5 virtual table (`tokenize='trigram'`, title/content indexed, entry_path/layer unindexed) kept in sync by AFTER INSERT/DELETE/UPDATE triggers. Per entry there are up to two records: `original` (content = `TranscriptMarkdown.body(from:)` rendering) and `edited` (only when forked — unforked entries index the original layer only).
- **Query model**: exact = case-insensitive substring (trigram-FTS-accelerated; queries too short for trigrams fall back to a scan); fuzzy = trigram candidates re-ranked by bounded Damerau-Levenshtein (`SearchHit.score` = edit distance, 0 for exact). Ranking: edited-layer hits (`SearchLayer.rank` 0) above original-only, then by match position. `SearchHit` carries `matchRange` (UTF-16 in the full layer content — used for both text highlight and audio cue) and `snippetMatchRange` (for the result row).
- **Update triggers**: vault open → `initializeSearchIndex()` after the first scan (off the main actor, on the VaultService actor); every in-app write (autosave, Save, recording stop, transcription landing) → `synchronizeSearchEntry(at:)`; external changes → FSEventsWatcher → `synchronizeSearchIndex(changedAbsolutePaths:)`; entry delete/rename paths evict/repoint. The fuzzy toggle and open search re-run automatically (`refreshVaultSearchIfVisible`).
- **Navigation**: clicking a hit → `AppModel.selectSearchHit` (pauses playback, selects entry, publishes an identity-keyed `TranscriptNavigationRequest`). TranscriptWorkbenchView handles it: switches to the hit's layer, sets the highlight range, and cues audio via the word map (retried on `player.url` change because the player may not have loaded yet when the request is handled).

## Skip Silence gap model (M5 trim must reconcile with this)

- `SilenceGap.compute(from:threshold:)` walks consecutive *rendered* words (whitespace-only words don't split gaps) and records gaps where `next.start − prev.end` is **strictly greater** than the threshold (`defaultThreshold = 1.5` s, a tunable constant). Gaps are half-open: `skipDestination(at:in:)` returns the gap's end for times inside `[gapStart, gapEnd)`.
- PlayerService checks `skipDestination` on each 30 Hz tick while playing with `skipSilence` on and seeks internally (no `seekRevision` bump, so auto-follow doesn't reset). State persists app-wide in UserDefaults (`skipSilence`), per PRD.
- **M5 trim warning**: gaps are derived *entirely from word timings in `transcript.original.json`*. Any audio trim/delete feature must shift or regenerate those timings (and re-render/re-map), or Skip Silence, karaoke sync, click-to-seek, and search cueing all drift. The word map and gaps recompute from the JSON — fix the JSON and everything downstream follows.

## Detail-view UI component inventory (M5 adds/greys controls on these)

- **EntryDetailView** — centered title + created time + duration header; `TranscriptWorkbenchView` (max width 900); inline transcription status row (waiting/preparing/transcribing/failed+Retry) for the open entry; **playback shelf** in a bottom `safeAreaInset` (only when `entry.hasAudio` — M5's delete-audio-keep-note hides it); toolbar: Retranscribe (audio only), Show Info popover, Reveal in Finder; context menu mirrors Show Info/Reveal.
- **PlaybackSection** (the shelf) — waveform area (`WaveformView`, scrub-to-seek) with 0:00/duration caption row; large monospaced playhead label; transport capsule: **speed menu** (persistent label "1×", full ladder 0.5×–4×), back 15 s, play/pause, forward 15 s, **Skip Silence toggle** (waveform icon, accent tint when on). `controlScale`/`heightScale` shrink everything proportionally in short/narrow windows. `TransportButton` takes an optional `tint: AnyShapeStyle`.
- **TranscriptWorkbenchView** — note toolbar: layer badge/toggle (only when forked) + Edit/Save + Copy as Markdown (copies the *viewed* layer, frontmatter stripped, brief confirmation); ⌘F find bar with match cycling (Return/⇧Return, wraps, works per-layer); content: `SyncedOriginalTextView` (original; karaoke word glow, subdued surrounding text, click-to-seek, "Resume Following" pill appears when the user scrolls during playback) or `MarkdownBodyEditor` (edited; dedicated undo manager).
- **VaultSearchView** — ⌘⇧F overlay with fuzzy toggle and grouped results.
- **Keyboard**: all plain-key shortcuts live in AppModel's key monitor (never per-view `.keyboardShortcut` for bare keys — unreliable across focus states). Speed: `[` slower, `]` faster, `\` reset. Document new shortcuts in `KeyboardShortcutsView`.

## Known issues / quirks

- **Auto-title rename unloads the player**: when a transcription lands and auto-titling renames the entry, the selection remap triggers `selectedEntryID.didSet` → `player.unload()`. If audio was playing it stops. Pre-existing, deliberately left; fix in M5 if it bothers the user.
- Entry switch resets playback speed to 1× (`player.unload()`), by design so far.
- Edited-layer karaoke highlight disables on any real edit (by design; see mapping limits).
- If a "late second blink" of the editor ever reappears ~0.7 s after a recording stops, the suspect is FSEvents `IgnoreSelf` leaking our own writes into `externalVaultRevision` — no in-code evidence it does, but it was the one refresh cause not statically verifiable.
- `xcodebuild` prints a harmless "CoreSimulator is out of date" warning on this machine.
- Selection changes that depend on a rescan **must** go through `AppModel.refresh(apply:)` — setting `selectedEntryID` before/after a separate `await refresh()` reintroduces the "No Entry Selected" flash (fixed during M4 verification, commit `eb75257`).

## M4 additions beyond the PRD (user-requested during verification)

Persistent transport speed control + `[`/`]`/`\` shortcuts; Skip Silence toggle moved from a toolbar popover into the transport capsule; explicit Save flow layered on debounced autosave; the post-recording refresh smoothing; the dedicated editor undo manager; the occurrence-ordinal search cue. All covered above; listed here so a future reader knows they're verified behavior, not accidental scope.
