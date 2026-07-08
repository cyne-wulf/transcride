# PRD-2 Start Here — Milestone 1 handoff

> Assume you are a fresh model with zero context beyond PRD-2.md and this document.

## Project summary

Transcride is a native macOS (Swift 6 + SwiftUI, macOS 15+, Apple Silicon, App Sandbox) voice recorder + transcription workbench whose entire data layer is a plain-folder **vault**. Milestone 1 (verified 2026-07-08, tag `milestone-1`) delivered the vault foundation and app shell: vault selection with security-scoped bookmarks, the entry-folder data model, folder tree + entry list + read-only detail UI, rename/move/delete/restore with a `.trash` and 30-day purge, FSEvents live sync, and 42 passing unit tests. There is no audio yet — Milestone 2 adds recording, import, and playback.

## Build / run / test

- `project.yml` (XcodeGen) defines the project; `Transcride.xcodeproj` is generated and **gitignored** — after adding/removing source files run `xcodegen generate`.
- Build: `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build`
- Test: same command with `test` (42 tests, 7 suites; test target compiles `Transcride/Core` directly, no app host — app-layer code in `App`/`UI` is not unit-tested).
- Run: `open ~/Library/Developer/Xcode/DerivedData/Transcride-*/Build/Products/Debug/Transcride.app`
- Fixtures: `Scripts/make-fixture-vault.sh [count] [dir]` (default 500 entries → `TestVault-500/`, gitignored). `TestVault-A/` is the small manual-test vault.

## File map

**Transcride/Core** (pure, unit-tested, no AppKit/SwiftUI):
- `EntryFolderName.swift` — parse/build `transcride-<timestamp>[-slug]` folder names; timestamp ↔ Date.
- `Slug.swift` — `Slug.make(from:)`: lowercase-hyphen slugs, ≤40 chars.
- `TranscriptFile.swift` — transcript **file naming + discovery** (see contract below).
- `Frontmatter.swift` — line-preserving YAML frontmatter parser/serializer (`FrontmatterDocument`); unknown keys/lines round-trip byte-exact; typed accessors title/created/duration/favorite/audioDeleted/source/engine; lenient `FrontmatterDate`.
- `AtomicFile.swift` — `AtomicFile.write(_:to:)`: temp file in same dir + `rename(2)`. **All vault writes must go through this.**
- `VaultModels.swift` — `RelativePath` (String, `""` = root), `Entry`, `FolderNode`, `VaultSnapshot`, `VaultError`.
- `VaultScanner.swift` — recursive scan → `VaultSnapshot`; per-entry mtime cache (folder + transcript mtimes) so FSEvents rescans are cheap; snippet extraction; `audioExtensions` set already defined for M2.
- `VaultOperations.swift` — createFolder/renameFolder/renameEntry/moveItem (disk mutations).
- `TrashStore.swift` — `.trash/` + `<name>.trashinfo.json` sidecars; restore, permanent delete, 30-day purge.

**Transcride/App** (app layer):
- `TranscrideApp.swift` — @main, Settings scene.
- `AppModel.swift` — `@MainActor @Observable` view model; phases launching/needsVault/ready; all intents funnel through `perform(_:_:)` which logs to DebugLog and surfaces errors; owns selection state.
- `VaultService.swift` — `actor` owning all file I/O off the main thread (scanner + operations + trash). **The seam for M2:** add audio capture/import entry-creation methods here.
- `VaultBookmark.swift` — security-scoped bookmark save/resolve/clear (UserDefaults).
- `FSEventsWatcher.swift` — recursive FSEvents with `IgnoreSelf`, latency 0.7 s.
- `DebugLog.swift` — dev diagnostic log at `~/Library/Containers/com.ashandevine.transcride/Data/Library/Application Support/transcride-debug.log`. Keep for M2 debugging; strip or gate before release.

**Transcride/UI**: `RootView` (phase switch + error alert), `WelcomeView`, `MainView` (NavigationSplitView 3-pane), `SidebarView` (folder tree, Recently Deleted, bottom vault-switcher footer), `EntryListView` (rows, drag, context menus, alert-based rename), `EntryDetailView` (read-only body first-class; metadata behind Show Info popover), `RecentlyDeletedView`, `SettingsView`.

## Entry-folder contract (as implemented — M2 must follow this)

An entry is a folder named `transcride-YYYY-MM-DDTHH-mm-ss[-slug]`. The timestamp prefix is the immutable identity; rename only rewrites the slug suffix. Contents:

- **Transcript file — ⚠️ deviation from PRD-1**: the markdown file is **not** unconditionally `transcript.md`. Contract (per explicit user decision during verification, so the vault reads well in Obsidian):
  - Untitled entry → `transcript.md` (`TranscriptFile.defaultName`).
  - When the user titles an entry, `renameEntry` renames the file to `<Title>.md` (`TranscriptFile.fileName(forTitle:)` — strips `/`, `:`, leading dots; caps 100 chars).
  - Discovery (`TranscriptFile.find(in:)` / `.url(inEntry:)`): prefer `transcript.md`, else first visible `.md` alphabetically. External files are never renamed/"corrected".
  - **M2 impact**: PRD-2 says "stub `transcript.md`" — correct for new recordings (untitled), but any code reading a transcript must use `TranscriptFile` discovery, never a hard-coded name. Auto-titling (M3) must rename the file via the same helper.
- Frontmatter keys: `title` (double-quoted), `created` (ISO8601 with offset), `duration` (seconds, Double), `favorite`, `audio_deleted` (bools), `source` (`recorded`/`imported`), `engine`. Unknown keys must survive round-trips — always parse with `FrontmatterDocument`, edit fields, re-serialize; never regenerate frontmatter from scratch.
- `audio.m4a` or any extension in `VaultScanner.audioExtensions` — M2 creates these.
- `transcript.original.json`, `waveform.json` — reserved for M3/M2 respectively.

Example frontmatter:

```markdown
---
title: "Renamed again"
created: 2026-07-05T08:15:00+00:00
duration: 42.0
---
Body text…
```

Trash manifest (`.trash/<name>.trashinfo.json`):

```json
{ "deletedAt": "2026-07-08T20:19:55Z", "originalPath": "Journal/transcride-…" }
```

## The M2 seam

- **Entry creation**: M2's recorder/importer should add methods on `VaultService` (e.g. `createEntry(...)`) that build the folder name with `EntryFolderName(date:slug:)`, write the stub transcript with `FrontmatterDocument` + `AtomicFile`, and copy/finalize audio into the folder. After any mutation, `AppModel.refresh()` re-snapshots.
- The FSEvents watcher uses `IgnoreSelf`, so in-app writes must be followed by an explicit `refresh()` (the `perform` wrapper already does this).
- Entitlements: add microphone (`com.apple.security.device.audio-input`) + `NSMicrophoneUsageDescription` via `project.yml`, then `xcodegen generate`.

## Reusable helpers — do not reinvent

`AtomicFile.write`, `FrontmatterDocument`, `TranscriptFile`, `EntryFolderName`, `Slug`, `RelativePath` extensions, `VaultService` actor pattern (all I/O off main), `AppModel.perform` for intents.

## Known issues / tech debt

- `DebugLog` is always-on (tiny append-only file); gate behind a flag before shipping.
- SwiftUI gotcha (bit us twice): alert/confirmationDialog **button actions run after the isPresented binding is cleared** — keep dialog payloads in separate `@State`, never derive presentation from `payload != nil`. Inline TextField-in-List-row rename does not commit reliably on macOS; use alert-with-TextField.
- Entry detail is plain `Text` (no markdown rendering, no editing) — placeholder until M4.
- `Entry.transcriptFileName` is populated by the scanner; `readTranscript` re-discovers on each read (cheap, one directory listing).
- Retention days in Settings is display-only (fixed 30, `TrashStore.retentionDays`).
