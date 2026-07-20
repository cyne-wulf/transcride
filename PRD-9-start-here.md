# Start here — Milestone 9

> Assume you are a fresh model with zero context beyond `PRD-9.md` and this
> document.

> **Governance status — one-time human waiver, 2026-07-17:** Milestone 7 is the
> last verified gate. The human explicitly authorized Milestone 9 implementation
> to begin even though Milestone 8's implementation is unverified, its 23-item
> human checklist was skipped, and its final combined work is not fully committed.
> Every Milestone 8 checklist box remains unchecked. Do not create or claim a
> `milestone-8` verified tag. This waiver applies only to the Milestone 8 → 9
> transition; Milestone 9's normal checklist, handoff, commit, and tag gate remain
> mandatory.

## Read order and implementation boundary

Before changing source, read this file completely, then read `AGENTS.md`,
`PRD-9.md`, `PROJECT-STATE.md`, and `master-prd-backup.md`. Inspect the live
combined diff again because this is a shared checkout. Preserve the Milestone 8
implementation described below and re-ground interface names against the current
source; do not use the waiver to expand Milestone 9 beyond its accepted PRD.

Milestone 9 is the focused, locally bundled CodeMirror 6 decorated-source
workbench. Markdown syntax remains visible. Outline, backlinks/Linked Mentions,
wikilink autocomplete, unresolved-note creation, inbound rename rewriting, tag
panes/counts/writing, layer diff, WYSIWYG, and a separate Reading mode are not in
scope.

## Exact repository and worktree state

- Repository: `/Users/adevine/Developer/transcride`.
- Branch: `main`.
- `HEAD` and `origin/main`: `f5d8dab8dcecd4981c519670545ee8d84a3d6e21`
  (`Render waveform immediately on selection`, 2026-07-15).
- Last verified tag: `milestone-7` at
  `edb666431f3e5ea734a3ad7d28dda92a6989a36f`.
- `HEAD` is ten commits after `milestone-7`, including the `v1.2.0` release commit,
  committed Milestone 8 global-control work, and post-release layout/performance
  work. The final combined Milestone 8 implementation also has substantial dirty
  changes; do not describe the milestone as wholly committed.
- There is no `milestone-8` tag and there must not be one under this waiver.
- No paths are staged. Do not reset, discard, stash, or overwrite the combined
  worktree to manufacture a clean base.
- At handoff creation, 45 tracked paths were modified relative to `HEAD`. Nine
  implementation/test source files were untracked. This handoff is one additional
  untracked documentation file until a future authorized commit.
- `.derivedData/` is untracked generated build/test output. It includes the prior
  run products and a canceled app-host runner result; never add it to source
  control or treat that canceled result as a failing assertion suite.
- `project.yml` and the generated Xcode project have no dirty diff at this handoff.
  `project.yml` did change earlier after `milestone-7` to add the app-hosted test
  target. Continue to edit `project.yml`, never `Transcride.xcodeproj`, for project
  changes.

The dirty tracked paths at handoff creation are:

```text
AGENTS.md
CLAUDE.md
PRD-8-start-here.md
PRD-8.md
PRD-9.md
PROJECT-STATE.md
Transcride/App/AppModel.swift
Transcride/App/AppWindowPresenter.swift
Transcride/App/GlobalRecordingIndicatorController.swift
Transcride/App/TranscrideApp.swift
Transcride/App/VaultService.swift
Transcride/Core/ClipEditHistory.swift
Transcride/Core/Frontmatter.swift
Transcride/Core/GlobalRecordingControls.swift
Transcride/Core/MarkdownExport.swift
Transcride/Core/TranscriptEditDocument.swift
Transcride/Core/TranscriptMarkdown.swift
Transcride/Core/TranscriptWordMap.swift
Transcride/Core/TranscriptionApplier.swift
Transcride/Core/TrashStore.swift
Transcride/Core/VaultModels.swift
Transcride/Core/VaultOperations.swift
Transcride/Core/VaultSearchIndex.swift
Transcride/Core/VocabularyReapply.swift
Transcride/UI/AboutView.swift
Transcride/UI/AppCommands.swift
Transcride/UI/EntryDetailView.swift
Transcride/UI/ExportMarkdownSheet.swift
Transcride/UI/KeyboardShortcutsView.swift
Transcride/UI/MainView.swift
Transcride/UI/SettingsView.swift
Transcride/UI/TranscrideMenuBar.swift
Transcride/UI/TranscriptWorkbenchView.swift
TranscrideIntegrationTests/GlobalRecordingIntegrationTests.swift
TranscrideTests/ClipEditHistoryTests.swift
TranscrideTests/FrontmatterTests.swift
TranscrideTests/GlobalRecordingControlsTests.swift
TranscrideTests/MarkdownExportTests.swift
TranscrideTests/SpeakerAssignmentTests.swift
TranscrideTests/TranscriptionApplierTests.swift
TranscrideTests/TrashStoreTests.swift
TranscrideTests/VaultScannerTests.swift
TranscrideTests/VaultSearchIndexTests.swift
master-prd-backup.md
obsidian-compatibility.md
```

The nine untracked implementation/test source files are:

```text
Transcride/Core/QuickMove.swift
Transcride/Core/ShortcutTypes.swift
Transcride/UI/AppShortcutMenu.swift
Transcride/UI/QuickMoveView.swift
Transcride/UI/ShortcutCaptureField.swift
TranscrideIntegrationTests/QuickMoveIntegrationTests.swift
TranscrideIntegrationTests/SpeakerDetectionIntegrationTests.swift
TranscrideTests/AppShortcutTests.swift
TranscrideTests/QuickMoveTests.swift
```

## Build, test, install, and run

The project is generated from `project.yml`. XcodeGen and Xcode build/test commands
must run sequentially in this shared checkout.

```sh
xcodegen generate
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' build
```

For diagnosis, the no-app-host Core target and the app-hosted integration target can
be run separately:

```sh
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' \
  test -only-testing:TranscrideTests
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' \
  test -only-testing:TranscrideIntegrationTests
```

After a verified local app build, follow the repository rule: stop the running app,
move the old `/Applications/Transcride.app` to a unique recoverable Trash path,
copy the exact Debug build product into `/Applications`, then verify and launch it.
With the existing repository-local DerivedData path, the non-destructive copy and
verification commands are:

```sh
ditto /Users/adevine/Developer/transcride/.derivedData/Build/Products/Debug/Transcride.app \
  /Applications/Transcride.app
codesign --verify --deep --strict /Applications/Transcride.app
shasum -a 256 \
  /Users/adevine/Developer/transcride/.derivedData/Build/Products/Debug/Transcride.app/Contents/MacOS/Transcride.debug.dylib \
  /Applications/Transcride.app/Contents/MacOS/Transcride.debug.dylib
open /Applications/Transcride.app
```

Resolve the actual DerivedData product path before copying if a later build uses
Xcode's default location. Never merge into a stale installed bundle: move the old
bundle aside first.

### Final Milestone 8 automated evidence — not human verification

- A fresh source run passed all **371 Core tests**.
- The app-hosted integration target contains **17 tests**: six global-recording,
  seven responsive-split, two Quick Move/shortcut-dispatch, and two speaker-toggle
  tests. All 17 passed on the successful retry.
- A separate fresh arm64 Debug build completed cleanly.
- The implementation task moved the previous installed app to Trash, copied the
  fresh Debug bundle to `/Applications/Transcride.app`, verified its ad-hoc code
  signature, matched the built and installed executable hashes, and launched it.
- These results establish an implementation baseline only. They do not check any
  Milestone 8 human box and do not justify a `milestone-8` tag.

The first app-hosted run never reached an assertion because LaunchServices failed
to start the host process (`childPID > 0`). Its immediate retry passed all 17 tests.
During a later full command, the second host launch wedged inside the macOS loader
before test code; the orphaned runner was stopped. Treat this as a transient local
LaunchServices/app-host loader issue, not as an assertion failure, but keep the Core
and app-host runs sequential and inspect any recurrence before trusting results.

## Combined changed-file map since `milestone-7`

This is the implementation baseline, not only the dirty diff. It covers every path
changed from `milestone-7` through `HEAD`, every dirty tracked path, and every
untracked source/test addition. `PRD-9-start-here.md` itself is the additional
transition document.

The exact 85-path inventory, excluding untracked `.derivedData/`, is:

```text
AGENTS.md
CHANGELOG.md
CLAUDE.md
PRD-7.md
PRD-8-start-here.md
PRD-8.md
PRD-9-start-here.md
PRD-9.md
PROJECT-STATE.md
README.md
Scripts/make-long-entry-fixture.sh
Transcride/App/AppModel.swift
Transcride/App/AppTerminationDelegate.swift
Transcride/App/AppWindowPresenter.swift
Transcride/App/GlobalRecordingIndicatorController.swift
Transcride/App/GlobalShortcutService.swift
Transcride/App/PlayerService.swift
Transcride/App/TranscrideApp.swift
Transcride/App/Transcription/WhisperKitEngine.swift
Transcride/App/VaultService.swift
Transcride/Core/ClipEditHistory.swift
Transcride/Core/Frontmatter.swift
Transcride/Core/GlobalRecordingControls.swift
Transcride/Core/ListSelectionNavigator.swift
Transcride/Core/MarkdownExport.swift
Transcride/Core/PlaybackSkipInterval.swift
Transcride/Core/QuickMove.swift
Transcride/Core/ShortcutTypes.swift
Transcride/Core/TranscriptEditDocument.swift
Transcride/Core/TranscriptMarkdown.swift
Transcride/Core/TranscriptWordMap.swift
Transcride/Core/TranscriptionApplier.swift
Transcride/Core/TrashStore.swift
Transcride/Core/VaultModels.swift
Transcride/Core/VaultOperations.swift
Transcride/Core/VaultSearchIndex.swift
Transcride/Core/Vocabulary.swift
Transcride/Core/VocabularyReapply.swift
Transcride/Core/WaveformData.swift
Transcride/UI/AboutView.swift
Transcride/UI/AdaptiveSkipButton.swift
Transcride/UI/AppCommands.swift
Transcride/UI/AppShortcutMenu.swift
Transcride/UI/EntryDetailView.swift
Transcride/UI/EntryListView.swift
Transcride/UI/ExportMarkdownSheet.swift
Transcride/UI/GlobalShortcutSettings.swift
Transcride/UI/KeyboardShortcutsView.swift
Transcride/UI/MainView.swift
Transcride/UI/QuickMoveView.swift
Transcride/UI/RecorderBar.swift
Transcride/UI/ResponsiveSplitLayout.swift
Transcride/UI/RetranscribeSheet.swift
Transcride/UI/RootView.swift
Transcride/UI/SettingsView.swift
Transcride/UI/ShortcutCaptureField.swift
Transcride/UI/TranscrideMenuBar.swift
Transcride/UI/TranscriptWorkbenchView.swift
Transcride/UI/TranscriptionSettings.swift
Transcride/UI/TrashPreviewView.swift
Transcride/UI/VaultSearchView.swift
Transcride/UI/WaveformView.swift
Transcride/UI/ZenModeView.swift
TranscrideIntegrationTests/GlobalRecordingIntegrationTests.swift
TranscrideIntegrationTests/QuickMoveIntegrationTests.swift
TranscrideIntegrationTests/ResponsiveSplitLayoutTests.swift
TranscrideIntegrationTests/SpeakerDetectionIntegrationTests.swift
TranscrideTests/AppShortcutTests.swift
TranscrideTests/ClipEditHistoryTests.swift
TranscrideTests/FrontmatterTests.swift
TranscrideTests/GlobalRecordingControlsTests.swift
TranscrideTests/ListSelectionNavigatorTests.swift
TranscrideTests/MarkdownExportTests.swift
TranscrideTests/PlaybackSkipIntervalTests.swift
TranscrideTests/QuickMoveTests.swift
TranscrideTests/SpeakerAssignmentTests.swift
TranscrideTests/TranscriptionApplierTests.swift
TranscrideTests/TrashStoreTests.swift
TranscrideTests/VaultScannerTests.swift
TranscrideTests/VaultSearchIndexTests.swift
TranscrideTests/VocabularyTests.swift
TranscrideTests/WaveformTests.swift
master-prd-backup.md
obsidian-compatibility.md
project.yml
```

### Governance, release, and fixtures

- `AGENTS.md`, `CLAUDE.md`, `PRD-7.md`, `CHANGELOG.md`, `README.md`, and
  `project.yml` — release/workflow metadata, build instructions, and the app-hosted
  integration target.
- `PRD-8-start-here.md` and `PRD-8.md` — historical starting context, accepted
  Milestone 8 plus the approved shortcut, Quick Move, subfolder, and speaker-toggle
  additions, and the dated waiver; its checklist remains unchecked.
- `PRD-9.md`, `PROJECT-STATE.md`, `master-prd-backup.md`, and
  `obsidian-compatibility.md` — accepted Milestone 9 scope and this dated transition.
- `Scripts/make-long-entry-fixture.sh` — long-transcript fixture generator.

### Global controls, menu bar, widget, and lifecycle

- `Transcride/Core/GlobalRecordingControls.swift`.
- `Transcride/App/GlobalShortcutService.swift`, `AppTerminationDelegate.swift`,
  `GlobalRecordingIndicatorController.swift`, `AppWindowPresenter.swift`, and
  `TranscrideApp.swift`.
- `Transcride/UI/TranscrideMenuBar.swift`, `GlobalShortcutSettings.swift`, and the
  global-control portions of `SettingsView.swift`, `KeyboardShortcutsView.swift`,
  `AppCommands.swift`, `RecorderBar.swift`, and `ZenModeView.swift`.
- `TranscrideTests/GlobalRecordingControlsTests.swift` and
  `TranscrideIntegrationTests/GlobalRecordingIntegrationTests.swift`.

### App remapping, menu/help, and window routing

- `Transcride/Core/ShortcutTypes.swift` (new).
- `Transcride/UI/ShortcutCaptureField.swift` and `AppShortcutMenu.swift` (new), plus
  `SettingsView.swift`, `KeyboardShortcutsView.swift`, `AboutView.swift`, and
  `AppCommands.swift`.
- `Transcride/App/AppModel.swift`, `AppWindowPresenter.swift`, and
  `TranscrideApp.swift`.
- `TranscrideTests/AppShortcutTests.swift` (new) and dispatcher coverage in
  `TranscrideIntegrationTests/QuickMoveIntegrationTests.swift` (new).

### Quick Move and path coherence

- `Transcride/Core/QuickMove.swift` (new), `VaultOperations.swift`,
  `ClipEditHistory.swift`, and `TrashStore.swift`.
- `Transcride/UI/QuickMoveView.swift` (new) and `MainView.swift`.
- `Transcride/App/AppModel.swift` and `VaultService.swift`.
- `TranscrideTests/QuickMoveTests.swift` (new), `ClipEditHistoryTests.swift`, and
  `TrashStoreTests.swift`; app-host coverage is in the new
  `TranscrideIntegrationTests/QuickMoveIntegrationTests.swift`.

### Speaker presentation toggle

- `Transcride/Core/Frontmatter.swift`, `TranscriptMarkdown.swift`,
  `TranscriptWordMap.swift`, `TranscriptEditDocument.swift`, `MarkdownExport.swift`,
  `TranscriptionApplier.swift`, `VaultSearchIndex.swift`, and
  `VocabularyReapply.swift`.
- `Transcride/App/VaultService.swift` and `AppModel.swift`.
- `Transcride/UI/TranscriptWorkbenchView.swift`, `ExportMarkdownSheet.swift`,
  `EntryDetailView.swift`, and `AppCommands.swift`.
- `TranscrideTests/FrontmatterTests.swift`, `SpeakerAssignmentTests.swift`,
  `MarkdownExportTests.swift`, `TranscriptionApplierTests.swift`, and
  `VaultSearchIndexTests.swift`; the app-hosted
  `TranscrideIntegrationTests/SpeakerDetectionIntegrationTests.swift` is new.

### Subfolder aggregation

- `Transcride/Core/VaultModels.swift`, `Transcride/App/AppModel.swift`,
  `Transcride/UI/SettingsView.swift`, and `TranscrideTests/VaultScannerTests.swift`.

### Other post-Milestone 7 baseline work to preserve

- Responsive layout: `Transcride/UI/ResponsiveSplitLayout.swift`, `MainView.swift`,
  `EntryDetailView.swift`, and `TrashPreviewView.swift`, with
  `TranscrideIntegrationTests/ResponsiveSplitLayoutTests.swift`.
- Contextual playback skip: `Transcride/Core/PlaybackSkipInterval.swift`,
  `Transcride/App/PlayerService.swift`, `Transcride/UI/AdaptiveSkipButton.swift`,
  `EntryDetailView.swift`, and `TrashPreviewView.swift`, with
  `TranscrideTests/PlaybackSkipIntervalTests.swift`.
- Selection fallback: `Transcride/Core/ListSelectionNavigator.swift`,
  `Transcride/App/AppModel.swift`, and
  `TranscrideTests/ListSelectionNavigatorTests.swift`.
- Long-transcript/karaoke performance: `Transcride/Core/TranscriptWordMap.swift` and
  `Transcride/UI/TranscriptWorkbenchView.swift`.
- Waveform prefix-sum cache and immediate rendering:
  `Transcride/Core/WaveformData.swift`, `Transcride/UI/WaveformView.swift`,
  `EntryDetailView.swift`, and `TrashPreviewView.swift`, with
  `TranscrideTests/WaveformTests.swift` and read plumbing in
  `Transcride/App/VaultService.swift`.
- Vocabulary import/copy and Whisper prompt framing: `Transcride/Core/Vocabulary.swift`,
  `Transcride/App/Transcription/WhisperKitEngine.swift`,
  `Transcride/UI/TranscriptionSettings.swift`, and
  `TranscrideTests/VocabularyTests.swift`.
- Retranscribe default model and shell/search polish:
  `Transcride/UI/RetranscribeSheet.swift`, `EntryListView.swift`,
  `VaultSearchView.swift`, `RootView.swift`, and `MainView.swift`.

## Shortcut and command contracts

### Shared physical chord representation

`ShortcutChord` stores a physical macOS virtual `keyCode: UInt32` and
`ShortcutModifiers`. Modifier raw bits are a durable wire contract:

| Modifier | Raw bit |
| --- | ---: |
| Command | 1 |
| Option | 2 |
| Control | 4 |
| Shift | 8 |

Glyphs render in `⌃⌥⇧⌘` order. The aliases `GlobalShortcutChord` and
`GlobalShortcutModifiers` preserve the pre-Milestone 8 global-preference wire
shape. Do not change these raw values or switch persisted chords to characters.

### Global action ids and preferences

| Stable `GlobalShortcutAction` id | Default |
| --- | --- |
| `toggleRecording` | `⌥R` (key code 15) |
| `pauseResumeRecording` | `⌥P` (key code 35) |

`GlobalShortcutPreferences` is JSON-encoded Data in UserDefaults key
`globalShortcutPreferencesV2`. Current schema version is 4; versions 2–4 load and
migrate. Fields are `version`, `isEnabled`, `showsMenuBarItem`,
`showsBackgroundIndicator`, `backgroundIndicatorRetention`, and
`bindings: [GlobalShortcutAction: ShortcutChord?]`. Defaults enable all three
booleans, select ten-minute retention, and bind both actions above. Retention ids
are `quick`, `oneMinute`, `fiveMinutes`, `tenMinutes`, `thirtyMinutes`, `oneHour`,
and `never`; Quick is internally 2.6 seconds and presented as 3 seconds.

Carbon registration uses signature `TRCD` and action ids 1/2. Applying preferences
unregisters and re-registers atomically; a partial failure rolls back the newly
registered set. Wake/session activation reapplies preferences. Shutdown removes
registrations and the handler. Only registered chords are observed; there is no
general event tap.

### App action categories, ids, and exact defaults

The category raw ids are `recordingFile`, `notesEntry`, `playback`, `libraryView`,
and `appHelp`. The catalog has 60 stable action ids. `—` means deliberately
unbound. Primary precedes alternate.

| Category | Stable action id | Primary | Alternate |
| --- | --- | --- | --- |
| Recording/File | `recording.new` | `⌘N` | — |
| Recording/File | `recording.start-stop` | `⇧Space` | — |
| Recording/File | `recording.pause-playback` | `Space` | — |
| Recording/File | `file.import-audio` | `⌘⇧I` | — |
| Recording/File | `file.new-folder` | `⌘⇧N` | — |
| Notes/Entry | `entry.favorite` | `⌘D` | — |
| Notes/Entry | `entry.rename` | — | — |
| Notes/Entry | `entry.duplicate` | — | — |
| Notes/Entry | `entry.move-note` | `⌥M` | — |
| Notes/Entry | `entry.move-to-recently-deleted` | `⌘⌫` | `⇧⌫` |
| Notes/Entry | `entry.extend` | `E` | `⌘⇧R` |
| Notes/Entry | `entry.edit-save` | `⌘E` | — |
| Notes/Entry | `entry.copy-markdown` | `⌘⇧C` | — |
| Notes/Entry | `entry.toggle-layer` | — | — |
| Notes/Entry | `entry.retranscribe` | — | — |
| Notes/Entry | `entry.trim` | `T` | — |
| Notes/Entry | `entry.replace` | `R` | — |
| Notes/Entry | `entry.compress` | — | — |
| Notes/Entry | `entry.restore-original` | — | — |
| Notes/Entry | `toggleSpeakerDetection` | — | — |
| Notes/Entry | `entry.rename-speakers` | — | — |
| Notes/Entry | `entry.delete-audio` | — | — |
| Notes/Entry | `entry.info` | `⌘I` | — |
| Notes/Entry | `entry.reveal` | — | — |
| Notes/Entry | `entry.export-markdown` | `⌘⇧E` | — |
| Notes/Entry | `entry.share-audio` | — | — |
| Notes/Entry | `entry.open-in-obsidian` | — | — |
| Playback | `playback.clip-undo` | `⌘Z` | — |
| Playback | `playback.clip-redo` | `⌘⇧Z` | — |
| Playback | `playback.skip-back` | `←` | — |
| Playback | `playback.skip-forward` | `→` | — |
| Playback | `playback.jump-0` | top-row `0` | keypad `0` |
| Playback | `playback.jump-1` | top-row `1` | keypad `1` |
| Playback | `playback.jump-2` | top-row `2` | keypad `2` |
| Playback | `playback.jump-3` | top-row `3` | keypad `3` |
| Playback | `playback.jump-4` | top-row `4` | keypad `4` |
| Playback | `playback.jump-5` | top-row `5` | keypad `5` |
| Playback | `playback.jump-6` | top-row `6` | keypad `6` |
| Playback | `playback.jump-7` | top-row `7` | keypad `7` |
| Playback | `playback.jump-8` | top-row `8` | keypad `8` |
| Playback | `playback.jump-9` | top-row `9` | keypad `9` |
| Playback | `playback.speed-down` | `[` | — |
| Playback | `playback.speed-up` | `]` | — |
| Playback | `playback.speed-reset` | `\` | — |
| Playback | `playback.skip-silence` | `S` | — |
| Playback | `playback.zen` | `Z` | — |
| Library/View | `library.find-in-note` | `⌘F` | — |
| Library/View | `library.search-vault` | `⌘⇧F` | — |
| Library/View | `library.previous-folder` | `⌥↑` | — |
| Library/View | `library.next-folder` | `⌥↓` | — |
| Library/View | `library.sort-date` | — | — |
| Library/View | `library.sort-duration` | — | — |
| Library/View | `library.sort-title` | — | — |
| Library/View | `library.sort-recently-edited` | — | — |
| Library/View | `library.vault-root` | — | — |
| Library/View | `library.favorites` | — | — |
| Library/View | `library.recently-deleted` | — | — |
| Library/View | `library.transcription-queue` | — | — |
| App/Help | `app.about` | — | — |
| App/Help | `help.keyboard-shortcuts` | `⌘⇧/` (`⌘?`) | — |

`AppShortcutPreferences` is JSON-encoded Data under UserDefaults key
`appShortcutPreferencesV1`. Version 1 stores
`bindings: [AppShortcutAction: AppShortcutBindingSet]`, where every binding set has
optional `primary` and `alternate` `ShortcutChord`s. Decoding overlays persisted
actions on the complete default catalog so newly introduced ids acquire defaults;
an invalid/future version falls back to defaults. Invalid, reserved, or colliding
persisted values remain visible for repair but are omitted from `activeBindings`.

Escape, Return, keypad Return, and Tab are structural with any modifiers. Plain
Up/Down/Delete/Forward Delete and macOS/native reservations are not remappable.
Global bindings win over local bindings, including corrupt persisted collisions.
Bare and Shift-only app bindings yield to editable text. Clip Undo/Redo and Move to
Recently Deleted always yield to editable text even when modified. `⌥M` deliberately
does not yield: it may start the save-before-Quick-Move handshake. A capture field
suppresses all local dispatch and temporarily unregisters Carbon hotkeys without
mutating either saved preference profile. App and global reset operations are
independent.

`AppShortcutMenu` appends the current primary glyph to menu titles but deliberately
sets no native menu key equivalent. The physical-key local monitor is the sole
app-command keyboard dispatcher. Menu clicks, keyboard events, and Help derive from
the same live preferences and availability.

## `AppModel`, editor, and Quick Move seams

The authoritative app-command entry points are:

```swift
func isAppCommandEnabled(_ action: AppShortcutAction) -> Bool
func performAppCommand(_ action: AppShortcutAction)
func appShortcutAction(
    forKeyCode keyCode: UInt16,
    modifiers: ShortcutModifiers,
    editableTextHasFocus: Bool
) -> AppShortcutAction?
func setShortcutCaptureOwnsInput(_ ownsInput: Bool)
func updateAppShortcutPreferences(_ preferences: AppShortcutPreferences)
func resetAppShortcutPreferences()
func updateGlobalShortcutPreferences(_ preferences: GlobalShortcutPreferences)
func resetGlobalShortcutPreferences()
```

View-owned flows use revisioned typed requests. `WorkbenchActionRequest` cases are
`editOrSave`, `copyAsMarkdown`, `toggleLayer`, `toggleSpeakerDetection`,
`renameSpeakers`, and `finishEditingForQuickMove`. `WorkbenchUIState` mirrors
content/edit/fork/layer availability plus detected-speaker, speaker-enabled, and
speaker-toggle state. `AppWindowRequest` is `about` or `keyboardShortcuts` and uses
the retained `AppWindowPresenter.openAuxiliaryWindow(id:)`, so About and Help still
open after the last main window closes.

The current editor save boundary is:

```swift
func saveTranscriptBody(
    _ body: String,
    markHandEdited: Bool,
    clearHandEdited: Bool = false,
    for entry: Entry
) async -> FrontmatterDocument?
```

`TranscriptWorkbenchView.saveAndFinishEditing() async -> Bool` cancels and awaits
the pending 600 ms autosave, saves the exact edit session, and returns false without
leaving edit mode on failure. The current `VaultService.saveTranscriptBody` re-reads
frontmatter and atomically replaces the body while preserving unknown fields, but
it does **not** compare an expected body revision. Milestone 9 must extend this seam
with the PRD's exact-body revision/compare-and-save and snapshot barriers rather
than bypassing it.

The Quick Move entry points and result are:

```swift
func requestQuickMove()
func completeQuickMovePreparation(for entryPath: RelativePath, saved: Bool)
func moveEntry(
    atRelativePath relPath: RelativePath,
    toFolder destFolder: RelativePath
) async -> QuickMoveResult

typealias QuickMoveResult = Result<QuickMoveSuccess, QuickMoveFailure>
```

If editing is active, `requestQuickMove()` records the selected path/revision and
emits `.finishEditingForQuickMove`. Only a successful
`saveAndFinishEditing() -> true` opens the picker. A failed save keeps editing active
and never moves. Availability blocks no selection/destination, another move,
recording/session work, Trim, Replace, Compress, clip mutation, and any nonfailed
transcription-queue item for that entry.

`QuickMoveDestinationCatalog` enumerates Vault Root plus all folders, excludes the
current parent, de-duplicates, places root first, and naturally sorts full paths.
Search ranking is fixed: leaf exact, path exact, leaf prefix, path prefix, leaf
substring, path substring, leaf fuzzy, path fuzzy; then score, natural path, and
lexical tie-break. Fuzzy matching combines bounded Damerau-Levenshtein with ordered
subsequence matching. `QuickMoveSelection` reconciles stale destinations to the
first result and clamps arrow movement.

`QuickMoveFailure` distinguishes `unavailable`, `sourceMissing`,
`destinationMissing`, `destinationCollision`, and `fileSystem`. The picker stays
open with inline recovery on failure and closes only after typed success.

### Move, search, queue, and history invariants

- `VaultOperations.moveItem` revalidates source and destination directories before
  accepting even a same-folder no-op, refuses overwrite, and prevents moving a
  folder into itself/its descendant.
- `VaultService.moveItem` synchronizes old/new search paths and best-effort repoints
  audio-version trash sidecars plus clip-edit history. Repoint failures are logged
  and nonfatal, so stale recovery/history metadata remains a known risk.
- `AppModel` refreshes the snapshot, persists transcription-queue repointing
  (including descendants), remaps selected and Quick Move paths, and publishes
  those changes in one main-actor refresh. Sidebar selection remains unchanged; a
  row may disappear while detail stays on the moved note.
- The visible vault search is rerun after the move. There is never an overwrite or
  a second mutation path for drag/context moves; they share the same private move
  intent while bypassing only Quick-Move-specific UI availability.

## Speaker toggle, subfolders, menu, and widget

### Cached speaker presentation

`speaker_detection: false` is the only stored disable override. Missing, unknown,
or true means enabled. `VaultService.setSpeakerDetectionEnabled` requires cached
speaker ids, never rewrites Original JSON or speaker names, and queues no
transcription. An unforked body is regenerated with/without labels and
speaker-driven paragraph grouping; a hand-edited body remains byte-for-byte
unchanged. Search, Markdown export, word mapping, vocabulary reapply, and generated
body plumbing all receive the same flag. A new transcription clears the off
override. The stable app action id is `toggleSpeakerDetection`, default unbound;
the workbench disables it while editing/saving/updating.

### Subfolder aggregation

`FolderNode.allEntries` recursively aggregates descendants and
`VaultSnapshot.allEntries` delegates to it. UserDefaults key
`includeEntriesFromSubfolders` is a Boolean that defaults to true when absent.
Selected-folder display uses recursive entries when enabled and direct entries when
disabled. Turning it off clears a now-hidden descendant selection. New recordings
and imports still target the selected folder itself.

### Global state, menu bar, panel, and windows

`AppModel.performRecordingCommand(_:) async` remains the one serialized start,
pause/resume, and stop/save path used by global hotkeys, menu-bar actions, the
floating indicator, and in-app controls. `RecordingCommandGate` suppresses
overlapping commands. Stop means finalize, save, and enqueue transcription; it is
never discard.

`GlobalRecordingPresentationState` cases are `hidden`, `ready`, `recording`,
`paused`, `saving`, `saved`, `needsAttention`, `saveFailed`, and `unavailable`.
The status-item controller owns one stable native menu graph and mutates it in
place; a 1 Hz timer changes only the open menu's status title. Its controls remain
usable when Carbon shortcuts are disabled. **Show Floating Widget** is a
session-only override with a checkmark and remains active across app activation
until the widget's own dismiss control or Quit.

The 72×72 indicator is a borderless, nonactivating, non-key/non-main floating
`NSPanel`. It joins all Spaces, is full-screen auxiliary and stationary, remains
draggable, and stores `{displayID, normalizedX, normalizedY}` as JSON in
`globalIndicatorScreenAnchorV1`, clamping to an available screen. Manual visibility
overrides global-control/automatic visibility and foreground status. Automatic
visibility is limited to recording-session/retention states while the app is in
the background.

`AppWindowPresenter` gives the workbench a stable main-window identity, restores or
deminiaturizes the existing main window, and retains SwiftUI scene actions so the
main, Settings, About, and Keyboard Shortcuts windows can be reopened after the last
workbench window closes.

## Milestone 9 prerequisites and known risks

1. **Re-check shared state first.** Re-read the current diff and active-agent status
   immediately before editing. Preserve all user and Milestone 8 work; do not clean
   the checkout or stage/commit/tag as a preparatory shortcut.
2. **Input ownership is the first integration hazard.** The local monitor currently
   recognizes editable ownership only when the first responder is an editable
   `NSTextView`. CodeMirror, `WKWebView`, composition, and HTML search/replace fields
   need the explicit editor-input ownership required by `PRD-9.md`. Preserve text
   precedence for bare keys, `⌘Z`/`⌘⇧Z`, `⌘⌫`/`⇧⌫`, contextual `⌘I`, `⌘F`, and the
   intentional `⌥M` save-before-move behavior.
3. **Preserve the workbench lifecycle.** Keep separate Original/Edited temporary
   view state; immutable Original seek/speaker behavior; Edited click-to-edit;
   first-change fork; 600 ms autosave; explicit Save; exact-body undo-to-unfork;
   Quick Move's save handshake; and typed request/revision routing.
4. **Replace blind body writes safely.** Current saves preserve frontmatter but lack
   expected-body compare-and-save. Add exact UTF-8 body revisions, snapshot
   barriers, three-way merge/conflict recovery, and web-process recovery exactly as
   specified; never make the web surface authoritative for vault I/O.
5. **Keep the web surface offline and bundled.** Add `EditorWeb/`, exact dependency
   lock, checked-in minified bundle/notices/freshness check, explicit XcodeGen
   resources, WebKit linkage, strict CSP/navigation/permission denial, versioned
   typed bridge, session/sequence checks, and real-`WKWebView` integration coverage.
   Normal Xcode builds must not run npm or access the network.
6. **Do not regress path and speaker plumbing.** Quick Move queue/search/selection/
   history invariants, recursive folder search state, and reversible cached-speaker
   presentation are part of the starting baseline.
7. **Treat human-only behavior as unverified.** Global hotkeys across apps/Spaces,
   microphone failure/recovery, VoiceOver, contrast/reduced motion, panel placement,
   menu hover stability, and all other 23 Milestone 8 checklist items were not run.
   Automated and installed-bundle evidence is not a substitute.
8. **Known implementation edges:** `GlobalShortcutSettings.swift` is now an unused
   legacy pane; the current Settings surface uses the combined keybind pane and
   `ShortcutCaptureField`. Assigning a global chord already used locally is rejected
   rather than accepted-and-disabling-local. The widget uses tap for start/stop and
   long-hold to bring the app forward, while older PRD prose mentions click. Passive
   Ready does not automatically show the background panel before a recording.
9. **App-host launcher instability is environmental but real.** If an app-host test
   fails before assertions or wedges in the loader, stop only the orphaned runner,
   preserve its result for diagnosis, and retry the app-host target separately. Do
   not conflate that with Core or assertion failures.
10. **Scope remains fixed.** Reconcile source-level interface names before coding,
    but do not reintroduce retired navigation/knowledge features or defer required
    editor security, accessibility, performance, merge, and lifecycle work.

The next implementation agent should assume it is a fresh model with no context
beyond `PRD-9.md` and this document.
