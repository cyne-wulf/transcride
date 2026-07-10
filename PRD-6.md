# PRD-6 — Milestone 6: Command Layer & Navigation (the IDE skeleton)

> **This document opens the post-v1 polish program (Milestones 6–9).** v1 (Milestones 1–5) made Transcride a complete, correct tool; Milestones 6–9 make it a *lively, high-quality workbench* — the difference between a utility and an IDE. The program is: **6** command layer & navigation, **7** editor depth (links, tags, live markdown, diff), **8** capture presence & audio finesse, **9** motion, insight & release polish. Product context lives in [master-prd-backup.md](master-prd-backup.md); IDs like `EXP-4`/`LIB-5` are that document's P2 requirements landing here; new ID families (`CMD-`, `NAV-`, `EDX-`, `LNK-`, `CAP-`, `MOT-`, `INS-`, `ONB-`, `ACC-`, `REL-`) are **defined in these milestone docs** — each requirement is written out in full where it appears, so no doc depends on another for its meaning.
>
> **Before starting:** read `PROJECT-STATE.md` (the living architecture doc written at the end of Milestone 5). **Do not start until the human confirms Milestone 5's checklist is verified and v1 is tagged.** Each milestone doc is sized to be implementable in a single ~200K-token session by a fresh coding agent holding only that doc plus the previous handoff; if context runs low mid-milestone, adopt PRD-5's "Operating procedure — orchestrate to preserve context" (full-context forked subagents, sequential when they build, state recorded in memory after each package).

## Goal

Give the app an IDE's *nervous system*: one canonical registry of every action, and instant keyboard-first movement between any two places in the vault. At the end of this milestone a user can operate Transcride for an entire session without touching the mouse — palette for actions, switcher for entries, history for backtracking, tabs and split for working sets — and every later milestone registers its features into this layer instead of scattering them.

## Scope

**In:** command registry, command palette, quick switcher, navigation history, entry tabs, split view, type-to-filter in the entry list, multi-select + batch operations, bulk export (EXP-4), status bar.
**Out:** wikilinks/backlinks and tags (Milestone 7 — the switcher must not wait for them); editor improvements (Milestone 7); menu-bar capture (Milestone 8); animations beyond system defaults (Milestone 9 does the motion pass over these surfaces).

## Requirements

### Command registry (CMD-1) — the load-bearing contract; get this right
- A single `CommandRegistry` (Core-adjacent, unit-testable) where every user-facing action is registered once: stable id, title, synonyms for fuzzy search, symbol/icon, keyboard shortcut, scope (global / entry-with-audio / editing / list-selection), and an availability predicate.
- The menu bar, context menus, command palette, and Keyboard Shortcuts window all *render from the registry* — no action exists in only one surface. Migrate the M5 menu bar and AppModel key-monitor shortcuts to resolve through it (bare-key handling stays in the key monitor; the registry is the source of what the keys mean).
- Milestones 7–9 must register their actions here — the handoff must document how in two sentences.

### Command palette (CMD-2)
- ⌘K opens a floating palette: fuzzy match over command titles + synonyms, shortcut hints on the right, recently-used commands first on empty query, ↑↓/Return to execute in the current context, Esc closes. Unavailable commands (predicate false) are hidden, not disabled.
- Executing a command that needs further input (e.g. Move to Folder) chains into a second palette page rather than dumping the user into a dialog when a picker suffices.

### Quick switcher (NAV-1)
- ⌘O opens a switcher: fuzzy match over entry titles (and folder names, prefixed "Folder:"), most-recently-opened first on empty query, shows date + duration + snippet per row, Return opens in current tab, ⌘Return opens in a new tab. It must stay <50 ms per keystroke on a 1,000-entry vault (reuse the vault snapshot; no disk hits per keystroke).

### Navigation history (NAV-2)
- Every entry visit (selection, search hit, switcher jump, wikilink later) pushes onto a per-window history. ⌘[ / ⌘] (and toolbar back/forward buttons) move through it, restoring selection and scroll position. History survives within a session; it does not persist across relaunch.

### Tabs (NAV-3) and split view (NAV-4)
- An in-window tab bar (Obsidian-style, not macOS window tabs): ⌘-click or ⌘Return opens an entry in a new tab, ⌘W closes (never closes the window with one tab), ⌘⇧] / ⌘⇧[ cycle, drag to reorder. Each tab holds its own detail view state (layer, scroll, playhead paused-position). Open tabs restore on relaunch.
- ⌘\ splits the detail area into two panes showing two tabs side by side (one split level only — no nested splits); drag a tab into either pane; focused pane gets keyboard/transport. Playback remains **one player app-wide**: the non-focused pane's transport controls the shared player only when its entry is loaded (simplest rule; document it).

### List filter, multi-select & batch ops (NAV-5, LIB-6, EXP-4)
- **NAV-5:** a filter field atop the entry list narrows it as you type (title + snippet substring, local, instant) — distinct from ⌘⇧F vault search; Esc clears.
- **LIB-6 (new):** ⌘-click/⇧-click multi-select in the entry list; context menu offers batch Move to Folder, Delete (one confirm, all staged to Recently Deleted), Favorite/Unfavorite, and Export.
- **EXP-4 (master P2):** bulk export — the selection, a folder, or the whole vault exports via the M5 EXP-2 exporter (same options: layer, speaker labels, timestamps) into a destination folder, one `.md` per entry, collision-suffixed; a summary sheet reports count + skipped items.

### Status bar (NAV-6)
- A slim bar under the detail view: word count of the viewed layer, entry duration, engine/model that produced the original, transcription-queue glance (item count, tap to open queue popover). Hidden in Zen mode.

## Decisions already made (do not relitigate)
- Palette is **⌘K**; switcher is **⌘O** (Obsidian muscle memory beats VS Code's ⌘P here — the vault is the mental model). ⌘[ / ⌘] for history does not collide with the bare-key `[`/`]` speed step (modifier distinguishes).
- Tabs are a custom in-window tab bar; macOS window tabbing is disabled to avoid two tab concepts.
- The registry lives in app-layer Swift (it references AppModel state) but its matching/ordering logic is a pure Core type with unit tests.
- Recents ranking (palette + switcher) = simple recency list persisted in UserDefaults, not frecency — revisit post-9 if it feels wrong.
- One shared player across panes (no simultaneous dual playback in v1.x).

## Definition of done
- All requirements implemented; unit tests for: registry availability/scoping + fuzzy matcher ordering, switcher ranking, history push/back/forward semantics, batch-export planning (naming/collisions), filter predicate. `xcodebuild test` passes with no regressions.
- Palette and switcher open in <100 ms; switcher keystroke <50 ms on the 1,000-entry fixture vault.

## Verification checklist (human-run)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: one item at a time, exact steps given, wait for pass/fail, tally; on a fail, fix and re-verify that item plus any already-passed items the fix could touch. Write the handoff only after every box is human-confirmed. *Preparation: generate `TestVault-1000` via `Scripts/make-fixture-vault.sh 1000` if absent.*

- [ ] ⌘K from every context (list focus, editor focus, Zen, empty vault) opens the palette; typing "retr" surfaces Retranscribe only when the selected entry has audio; Return executes it.
- [ ] Palette empty-query shows your genuinely most-recent commands; executing from the palette updates recents.
- [ ] Every menu-bar item, palette command, and Keyboard Shortcuts window row agree on names and shortcuts (spot-check 6 commands across all three surfaces — registry is single-source).
- [ ] ⌘O, type 3 letters of a known entry's title: it's top-3; Return opens it; reopen ⌘O — that entry now leads the empty-query recents; ⌘Return opens another hit in a new tab.
- [ ] Switcher stays instant (no visible lag per keystroke) on TestVault-1000.
- [ ] Visit 4 entries via mixed routes (list click, switcher, search hit); ⌘[ walks back through all four restoring scroll position; ⌘] returns forward.
- [ ] Tabs: open 3 tabs, reorder by drag, ⌘W closes only the active tab, per-tab layer/scroll state survives switching; quit and relaunch — tabs restore.
- [ ] ⌘\ splits; two different entries visible side by side; editing in one pane while the other shows a different entry works; focused pane owns Space play/pause.
- [ ] Type in the list filter: list narrows live; Esc clears; filter + Favorites sidebar filter compose.
- [ ] Multi-select 5 entries; batch Move to a folder (all move, on disk too); batch Delete stages all 5 in Recently Deleted; restore all 5.
- [ ] Bulk-export a folder of 10+ entries to a scratch destination: 10 clean `.md` files, options respected, summary sheet correct; two same-titled entries export without overwriting each other.
- [ ] Status bar shows correct word count (compare a short entry by hand), duration, and engine; queue glance opens the queue popover.
- [ ] Regression: recording → auto-transcription → karaoke playback → edit/save → vault search all behave exactly as in v1 (M2–M5 spot pass).
- [ ] Regression: bare-key shortcuts (Space, Z, `[`/`]`, `\`) still work and still defer to editable text views.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-7-start-here.md`**: one-paragraph state summary; build/run/test; updated file map (one line per new/changed source file); **the command-registry contract in full** (how Milestone 7 registers commands — signature, scoping, shortcut declaration — with a real registration example); the tab/split state model and how a new view participates; navigation-history API; where the switcher gets its data; deviations from this doc; known issues. Also append this milestone's deviations to `PROJECT-STATE.md`. Close with: "Assume the reader is a fresh model with zero context beyond PRD-7.md and this document."
