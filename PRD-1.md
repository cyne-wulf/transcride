# PRD-1 — Milestone 1: Vault Foundation & App Shell

> **How this project is organized:** the full product spec lives in [master-prd-backup.md](master-prd-backup.md) (read §1–§4 and §6 before starting; requirement IDs like VLT-1 refer to it). The work is split into five milestones, PRD-1 through PRD-5. Each milestone is implemented in isolation, verified by the human via its Verification Checklist, and ends with the implementer writing a `PRD-<next>-start-here.md` handoff document. **Do not start work from a later milestone until the previous milestone's checklist is fully verified by the human.**

## Goal

A running native macOS app (Swift + SwiftUI, macOS 15+, Apple Silicon) whose entire data layer is the **transcride vault**: a user-chosen folder rendered faithfully in the UI. At the end of this milestone there is no recording and no transcription — but the app can browse, rename, move, delete, and restore entries that exist as folders on disk, and stays in sync with external file-system changes. Everything later builds on this foundation, so file handling must be rock solid.

## Scope

**In:** Xcode project setup, vault selection/creation, entry-folder data model, folder tree + library sidebar UI, entry detail placeholder view, rename/move/delete/restore, `.trash` with 30-day purge, file-system watching, reveal in Finder, settings skeleton.

**Out:** recording, playback, importing audio, transcription, editing, search. The detail view may render `transcript.md` read-only if one exists, but no editing.

## Requirements

### Vault (VLT-1, VLT-2, VLT-3, VLT-4, VLT-5, VLT-6)
- First-run flow: create a new vault or select an existing folder as the vault. Vault path persists across launches; a vault switcher lives in settings (SET-1 partial).
- Any subfolder inside the vault renders as a folder in the UI (nested folders supported). Folders can be created, renamed, and deleted from the UI, and those operations happen on disk.
- An **entry** is any folder whose name matches `transcride-<timestamp>` (canonical format `transcride-2026-07-08T14-32-05`, optionally suffixed `-<slug>` after rename — see Decisions). Entries render in the library list with title, date, duration, and snippet read from their files.
- Entry folder contents (the contract every later milestone depends on):
  - `audio.m4a` (or other audio extension) — optional at this milestone
  - `transcript.original.json` — optional; schema owned by Milestone 3
  - `transcript.md` — markdown with YAML frontmatter: `title`, `created`, `duration`, `favorite`, `audio_deleted`, `source`, `engine`
  - `waveform.json` — optional rebuildable cache
- Moving an entry between folders in the UI moves the folder on disk. Reveal in Finder on every entry.
- FSEvents watching: entries/folders added, removed, renamed, or edited outside the app appear in the UI within ~2 seconds without a restart, and external changes are never overwritten or "corrected" by the app.
- All file writes anywhere in the app use write-temp-then-rename (atomic) so a crash never corrupts an entry.

### Library shell (LIB-1 partial, LIB-2)
- Voice Memos-style layout: sidebar with folder tree and entry list (title, date, snippet), detail pane showing the selected entry (placeholder: frontmatter fields + raw `transcript.md` body rendered read-only).
- Inline rename of entries. Title is stored in frontmatter **and** appended to the folder name as a slug (`transcride-<timestamp>-<slug>`); the timestamp prefix is the stable identity and must never change.

### Recently Deleted (AUD-2 partial)
- Deleting an entry or folder moves it to `<vault>/.trash/` (not the system trash). A "Recently Deleted" view lists trashed items with deletion date; one-click restore returns them to their original location (store the original path in a small sidecar or trash manifest).
- Items older than 30 days are purged on app launch. "Delete permanently now" is available with a confirmation dialog.

## Decisions already made (do not relitigate)
- Files on disk are the single source of truth; any index/cache must be rebuildable from the vault alone.
- Folder-name slug on rename: **yes** (browsability in Finder is the point). Slugify: lowercase, hyphens, strip punctuation, cap ~40 chars.
- macOS 15 minimum, Apple Silicon only, SwiftUI.
- **App Sandbox is enabled from day one.** A user-selected vault folder is not accessible after relaunch under sandboxing unless a **security-scoped bookmark** is stored and resolved — build this into the vault-selection flow now (retrofitting sandboxing later is far more painful). Microphone and network entitlements land in later milestones.

## Definition of done
- All requirements above implemented; unit tests exist for: entry-folder name parsing, slugification, frontmatter read/write round-trip, trash/restore path mapping, atomic write helper. `xcodebuild test` passes.
- The app never blocks the main thread on file I/O (test with a 500-entry fixture vault).

## Verification checklist (human-run — all boxes required before Milestone 2)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: present one item at a time, give the human the exact steps and materials needed, wait for their pass/fail answer, and keep a running tally. On a fail: fix it, then re-verify that item plus any already-passed items the fix could have affected. Write the handoff document only after the human confirms every item.

Create fixture entries by hand in Finder (a folder `transcride-2026-07-01T10-00-00` containing a `transcript.md` with frontmatter and a few paragraphs) to test with.

- [ ] Fresh launch prompts for vault creation/selection; chosen vault persists across relaunch.
- [ ] Hand-made fixture entry appears in the library with correct title, date, and snippet.
- [ ] Creating a folder in the UI creates it on disk; dragging an entry into it moves the folder on disk (verify in Finder).
- [ ] Creating a folder and a new fixture entry **in Finder** while the app is running: both appear in the UI within a few seconds.
- [ ] Renaming an entry in the UI updates the frontmatter title and appends the slug to the folder name; timestamp prefix unchanged.
- [ ] Editing `transcript.md` externally (change the title in frontmatter) updates the UI without a restart.
- [ ] Reveal in Finder opens the correct entry folder.
- [ ] Deleting an entry moves it to `<vault>/.trash/`; it appears in Recently Deleted; restore puts it back in its original subfolder.
- [ ] Manually backdate a trash item's manifest date >30 days; relaunch; item is purged.
- [ ] Point the app at a fixture vault with 500 entries: launch < 2 s, scrolling stays smooth.
- [ ] Switch vaults in settings; the UI fully swaps to the second vault.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-2-start-here.md`** containing: a one-paragraph project summary; how to build/run/test; a file map of the codebase (each source file's responsibility in one line); the exact entry-folder contract as implemented (names, frontmatter keys, trash manifest format); any deviations from this document and why; known issues/tech debt; and pointers to reusable helpers the next milestone must use (atomic writes, FS watcher, entry model). Assume the reader is a fresh model with zero context beyond PRD-2 and your document.
