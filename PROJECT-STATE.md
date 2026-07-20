# Transcride project state

Last updated: 2026-07-17
Release line: 1.2.0 (build 3)
Verified gate: Milestone 7, 17/17 human checks
Current implementation: Milestone 9, authorized by a one-time human waiver dated 2026-07-17
Milestone 8: implementation complete in the current worktree; human checklist skipped and unverified; no `milestone-8` verified tag
Platform: macOS 15+, Apple silicon, Swift 6, SwiftUI

## Product state

Milestones 1–7 are human-verified. Version 1.2 delivers the complete local workflow:
record or import audio, transcribe it on-device, review it against synchronized
playback, edit a Markdown layer, search the vault, export or copy the knowledge,
optionally delete the audio while retaining the note, and safely extend an existing
recording with full retranscription and version recovery. Milestone 7 adds
duration-preserving replacement of a selected audio region with multiple takes,
contextual audition, recoverable versions, and non-destructive retained sources.

Milestone 8 implementation is complete in the current combined worktree: global
recording hotkeys, a native menu-bar controller, the floating recording widget,
app-wide two-slot shortcut remapping, Quick Move, recursive folder aggregation, and
reversible cached-speaker presentation are present with automated coverage. The
human explicitly skipped its 23-item checklist on 2026-07-17 and authorized the
Milestone 8 → 9 transition as a one-time exception. This is not a verification pass;
all Milestone 8 boxes remain unchecked and no `milestone-8` tag may be claimed.

The vault is the product's source of truth. It remains useful without Transcride:
notes are Markdown, audio uses ordinary media formats, timed transcripts are JSON,
and entry/folder names are human-readable. The SQLite search index and waveform
files are derived caches.

The current implementation milestone is `PRD-9.md` under that dated waiver. Read
`PRD-9-start-here.md` first: it records the exact dirty/committed baseline,
interfaces, evidence, risks, and scope boundary. The normal Milestone 9 human
verification and Milestone 9 → 10 gate remain fully in force.

## Architecture

### Process and state

- `TranscrideApp` creates one `AppModel` for the main window, Settings, commands,
  About, and keyboard help.
- `AppModel` is `@MainActor @Observable`. It owns UI state plus the recorder,
  player, model manager, transcription queue, current vault bookmark, and watcher.
- `VaultService` is an actor. All durable vault reads and writes pass through it;
  its pure helpers live under `Transcride/Core` and are compiled directly into the
  unit-test bundle.
- `FSEventsWatcher` observes external edits with `IgnoreSelf`. Every in-app write
  must explicitly refresh the snapshot and synchronize the search index.
- `TranscriptionQueue` is serial and persistent per vault. Queue records survive
  relaunch; a completed run is applied atomically through `TranscriptionApplier`.

### Global controls and app command routing

- `GlobalShortcutService` owns only the two registered Carbon chords
  (`toggleRecording` and `pauseResumeRecording`). Registration applies atomically,
  is re-established after wake, and is removed on shutdown; there is no general
  keystroke event tap.
- `AppModel.performRecordingCommand(_:)` is the serialized path shared by global
  hotkeys, the native status menu, the floating indicator, and in-app recording
  controls. `RecordingCommandGate` suppresses overlapping start/pause/stop work.
- `ShortcutChord` is the shared physical-key representation. Global preferences
  retain their existing JSON wire format; the app catalog adds 60 stable action ids
  with ordered primary/alternate slots under `appShortcutPreferencesV1`.
- `AppModel.isAppCommandEnabled(_:)` and `performAppCommand(_:)` are authoritative
  for keyboard and menu dispatch. `AppShortcutMenu` displays live primary glyphs
  but installs no native key equivalents; the local monitor is the sole keyboard
  dispatcher and defers to editable text/capture ownership.
- `AppWindowPresenter` retains scene actions and distinguishes the main workbench
  from Settings/About/Help so any surface can reopen exactly one intended window.
- `GlobalRecordingIndicatorController` owns the nonactivating all-Spaces panel,
  session-only manual visibility, accessible state changes, and normalized
  per-display position in `globalIndicatorScreenAnchorV1`.

### Quick Move, path coherence, and browsing

- `QuickMoveDestinationCatalog` enumerates existing folders plus Vault Root,
  excludes the current parent, and deterministically ranks leaf/full-path exact,
  prefix, substring, and fuzzy matches. `QuickMoveResult` exposes typed success and
  retryable source/destination/collision/filesystem failures.
- Quick Move asks an active workbench to finish its exact pending save before the
  picker opens. The move is blocked by recording, transcription, or audio mutations
  and never overwrites an existing entry.
- One move intent updates the vault, old/new search paths, transcription queue,
  selected/Quick Move paths, audio-version trash sidecars, and clip-edit history.
  Snapshot, queue, and selection publication happen in one main-actor refresh.
- `FolderNode.allEntries` and `VaultSnapshot.allEntries` provide recursive browsing.
  `includeEntriesFromSubfolders` defaults on; disabling it clears a descendant
  selection that is no longer visible without changing the selected recording
  destination.
- Frontmatter stores only `speaker_detection: false` as an override. Toggling
  cached speaker presentation regenerates an unforked body and all derived views,
  never rewrites Original JSON or queues transcription, and leaves hand-edited
  Markdown byte-identical.

### Vault and entry contract

Entry folders are named `transcride-YYYY-MM-DDTHH-mm-ss[-slug]`. The timestamp is
the stable identity; renaming changes only the readable slug.

An entry may contain:

- `transcript.md` while untitled, or `<Title>.md` after naming.
- One visible audio file, normally `audio.m4a`; imported formats remain unchanged.
- `transcript.original.json`, the immutable timed engine result.
- `waveform.json`, a regenerable playback cache.
- Frontmatter including `title`, `created`, `duration`, `favorite`,
  `audio_deleted`, `source`, `engine`, `hand_edited`, `silence_detection`, and
  optional speaker names. Missing or unknown silence values mean `waveform`.

Always discover Markdown with `TranscriptFile`; never hard-code `transcript.md`.
Always mutate frontmatter with `FrontmatterDocument` so unknown user/Obsidian
fields round-trip unchanged.

`.trash/` holds entries or audio wrappers plus `.trashinfo.json` sidecars. Delete
Audio moves the media and waveform while retaining the note. Trim stages the
pre-trim audio the same way so it remains recoverable.

### Recording and playback

- `RecorderService`: microphone selection, AVAudioEngine tap, fixed-width PCM crash
  journal, final AAC/ALAC M4A encoding, live waveform, pause/resume, and explicit
  new-entry versus extension session targets.
- `RecordingInputConfiguration`: pure device-change classification.
- `PlayerService`: AVPlayer transport, 0.5x–4x speed, seek/skip, Skip Silence,
  playhead publishing, user-seek revisions, and identity-gated waveform/speech
  gap sets. It routes only the entry's selected mode and never cross-falls back.
- `WaveformGenerator`/`WaveformData`: streaming decode and cache schema.
- `AudioTrim` + `TrashStore`: packet-preserving trim where possible, safe swap,
  recovery, duration update, then full retranscription.
- `AudioExtensionComposer` + `AudioExtensionApplier`: validated append-only
  composition, safe swap, recoverable pre-extension versions, stale-timing state,
  relaunch convergence, then exactly one full retranscription.
- `SilenceDetectionMode` is an entry preference shared by non-destructive Skip
  Silence and destructive Compress Audio. Waveform mode uses -40 dBFS; speech mode
  validates raw timed-Original word gaps. Both require silence strictly longer than
  1.5 seconds and retain 0.1 seconds at each boundary.
- `.transcript-alignment-stale` is hidden derived state created by audio mutation
  and removed only by `TranscriptionApplier`. While present—or while transcription
  is queued/running—speech skipping is suspended and speech compression is blocked.

### Replacement editing

- Trim and Replace share `AudioRangeSelection` and the generalized
  `TrimSelectionOverlay`; there is one handle/drag/keyboard/accessibility contract.
- `ReplacementRegion` locks start and length as integer frames. A complete take is
  bakeable only when its sample rate matches and its captured length is within one
  frame of the locked region.
- `ReplacementTakeSession` persists capture, finalization, audition, render, swap,
  retranscription, completion, and failure phases. Temporary takes live in
  `.transcride-replacement-session`; relaunch recovers them but never bakes them.
- `.transcride-replacements/recipe-v1.json` maps fixed timeline slices to a retained
  master or take source. Overlap splits existing slices and inserts the newest take
  without shifting later frames. Missing history never breaks the visible audio;
  the next replacement adopts the canonical file as a new master.
- `AudioReplacementRenderer` renders a single ordinary M4A and validates the total
  frame count. `AudioReplacementApplier` never mutates visible audio in place: it
  stages the pre-replacement audio, waveform, and matching history in Recently
  Deleted, installs the validated candidate/history pair, and rolls back on error.
- Each successful bake marks timed transcript alignment stale and queues exactly one
  full retranscription through `TranscriptionSeam.Source.replaced`. Hand-edited
  Markdown remains byte-identical.
- Debug builds expose one-shot render and safe-swap failures in the Testing menu so
  the known-good-audio and retry guarantees can be verified in the installed app.

The recording tap must stay `@Sendable`; the sink writes before `liveTee` forwards
buffers so live transcription can never endanger capture.

### Transcription

- `ModelManager` and `EngineRegistry` expose Parakeet, WhisperKit, and Apple Speech.
- `ParakeetEngine`, `WhisperKitEngine`, and `AppleSpeechEngine` conform to the same
  async/cancellable engine protocol.
- `DiarizationEngine` assigns stable speaker ids; display names remain frontmatter.
- `LiveTranscriber` uses FluidAudio's streaming model for display-only partials.
- `Vocabulary` provides native bias where supported and a correction backstop;
  `VocabularyReapply` previews and applies safe corrections to existing originals.
- `TranscriptionApplier` archives the prior original, writes JSON atomically,
  regenerates unedited Markdown, and never overwrites a hand-edited layer.

### Workbench and search

- `TranscriptWorkbenchView`: Original/Edited layers, click-to-edit NSTextView bridge,
  autosave plus an Edited/Save segment, undo, find, copy, speaker labels, and timed
  highlighting/follow.
- `TranscriptWordMap`: one UTF-16 coordinate map for rendered words, times, search
  matches, clicks, and karaoke state. `EditedTranscriptPlaybackMap` retains karaoke
  through the exact unchanged prefix, then fades the red edit boundary and all
  karaoke styling back to the normal text appearance over 1.5 seconds.
- `VaultSearchIndex`: one external FTS5 database per vault under Application
  Support. Exact search is substring-based; fuzzy search uses trigram candidates
  plus bounded Damerau-Levenshtein ranking.
- `SearchFilters`: post-index metadata filters for folder, date, audio state, and
  favorite status.
- `MarkdownExport`: clean Original/Edited export with optional speakers/timestamps.

Edited-layer audio cueing is intentionally best-effort: matching text is relocated
by occurrence ordinal; user-authored text absent from the original has no time cue.

### UI map

- `RootView`, `WelcomeView`, `MainView`: startup/vault selection and three-pane shell.
- `SidebarView`: folders, favorites, trash, and the three-item recent-vault switcher.
- `EntryListView`, `SortPopover`: clip list, selection, row actions, and ordering.
- `EntryDetailView`, `TranscriptWorkbenchView`, `WaveformView`,
  `TrimSelectionView`, `ExtensionRecoveryView`: the main note/audio workbench and
  interrupted-extension recovery.
- `RecorderBar`, `ZenModeView`, `LiveTranscriptViews`: capture surfaces.
- `VaultSearchView`: indexed search overlay and filters.
- `TranscriptionQueueView`, `RetranscribeSheet`, `SpeakerRenameSheet`: engine flows.
- `SettingsView`, `TranscriptionSettings`, `StorageSettings`: model, vocabulary,
  recording, retention, and storage controls.
- `RecentlyDeletedView`, `ExportMarkdownSheet`, `VocabularyReapplySheet`: lifecycle
  and export workflows.
- `AppCommands`, `KeyboardShortcutsView`, `AboutView`: complete command/help polish.

## Milestone deviations and user-approved additions

### Milestone 1

- Named notes use `<Title>.md` instead of permanently remaining `transcript.md`.
  This explicit verification-time decision makes the vault readable in Obsidian;
  `TranscriptFile` discovery preserves compatibility with untitled/external notes.

### Milestone 2

- Global transport/delete keys moved into one AppKit key monitor because bare-key
  SwiftUI shortcuts were unreliable around focus. Text editing always wins.
- Recording uses a valid partial CAF and remuxes on Stop rather than writing a
  fragile final container throughout capture.

### Milestone 3

- Live transcription shipped early as a user-approved addendum. It is display-only;
  the batch queue remains authoritative after Stop.
- Vocabulary backstop behavior was deliberately conservative and keeps
  `corrected_from`; large Whisper vocabulary bias remains disabled where unsafe.

### Milestone 4

- Added persistent transport speed with `[`, `]`, and `\` shortcuts; moved Skip
  Silence into the transport capsule; added explicit Save over debounced autosave.
- Added a dedicated editor undo manager, smoother post-recording refresh, and
  occurrence-ordinal audio cues for hand-edited search hits.

### Milestone 5

- No required feature was descoped; real two-speaker diarization passed human review.
- Added a last-three-vault switcher with explicit forget controls and current-vault
  indication during verification.
- Added `Command-Delete` alongside `Shift-Delete` for moving the selected entry to
  Recently Deleted. Both defer to active text fields/editors.
- Search filtering was corrected so metadata filters operate over the complete text
  candidate set, and audio-bearing entries match transcript text from their timed
  original rather than only a Markdown body.
- Toolbar placement, sort direction, empty-state behavior, and vault-switcher visual
  hierarchy received verification-driven polish.

### Milestone 6

- The Extend control moved to the far-left of the transport and is grayscale until
  hover instead of being a persistent trailing red dot.
- Plain `E` starts the selected entry's extension and pressing it again finishes;
  editable text fields retain the key. Command-Shift-R remains the menu command.
- Crash-proof capture was hardened beyond extension scope: ordinary new recordings
  now use the same fixed-width PCM journal, relaunch recovery, and protective
  close/quit flow.
- Interrupted extension recovery exposes Finish Extending, Save Segment as New
  Entry, and Discard Segment. Debug builds add deterministic failure seams before
  composition, before safe swap, and immediately after safe swap.

### Milestone 7

- Plain `R` starts Replace Audio for the selected entry when text input is not
  focused, while the three-dot menu remains its only visible entry action.
- Playback skip buttons and Left/Right Arrow choose a contextual 1–60 second
  interval from the loaded clip's duration instead of always skipping 15 seconds.
- Vault search and in-note Find gained visible controls during the final polish
  pass; their existing keyboard shortcuts remain available.
- Replacement capture starts directly without the optional countdown. Debug builds
  include explicit one-shot render and safe-swap failure commands.

### Milestone 8 (implemented, human checklist skipped under waiver)

- The accepted global-controls milestone also includes four explicit, user-approved
  additions: the app-wide two-slot shortcut remapper, Obsidian-style Quick Move,
  recursive subfolder aggregation, and reversible cached-speaker presentation.
- Menu clicks, the app-local physical-key monitor, Help, global hotkeys, the native
  status item, and floating widget converge on `AppModel` command/availability
  seams rather than creating parallel workflows.
- Quick Move preserves editor-save, queue, search, selection, trash-sidecar, and
  clip-history invariants across path changes. The speaker toggle preserves a
  hand-edited body and cached speaker data. Both are starting contracts for
  Milestone 9.
- The 2026-07-17 transition waiver allowed `PRD-9-start-here.md` and Milestone 9 to
  proceed with all 23 boxes unchecked. It did not verify Milestone 8, authorize a
  `milestone-8` tag, or weaken any later milestone gate.

## Known issues and technical debt

### P1 — release/distribution blockers

1. **No Developer ID signing identity is installed on the current machine.**
   `project.yml` intentionally produces ad-hoc signed local builds. A downloadable
   app must be Developer-ID signed, notarized, and stapled before strangers can run
   it without Gatekeeper warnings.
2. **No repeatable distribution script exists.** A future release-engineering task
   must add a notarized DMG pipeline once credentials and the intended distribution
   URL exist; the scoped editor milestone does not own distribution work.

### P2 — product/runtime debt

1. Auto-title rename unloads the player because selection remapping triggers the
   normal entry-switch path; playback stops if transcription lands mid-play.
2. Switching entries resets playback speed to 1x. This is currently intentional but
   may not match every user's preferred session behavior.
3. Loaded transcription models remain in memory for the app lifetime; Whisper large
   can retain substantial RAM after long work.
4. A microphone connected while its picker is already open appears after reopening
   the menu; the underlying device list itself does refresh.
5. Apple Speech is available only where the required macOS framework exists and is
   hidden on earlier supported systems.
6. Pre-1.1 AAC/ALAC CAF partials interrupted before close can lack their packet
   table. The bytes remain preserved and are acknowledged once, but cannot always
   be decoded; 1.1+ PCM journals do not have this failure mode.

### P3 — maintenance notes

1. `xcodebuild` on the current development Mac prints an out-of-date CoreSimulator
   warning. macOS builds/tests still pass; the warning is an Xcode installation issue.
2. `PlaybackSection` reads the small waveform cache on entry open; acceptable at the
   verified scale.
3. A late editor blink has not reproduced. If it returns, inspect self-generated
   FSEvents leaking into `externalVaultRevision`.
4. App-hosted tests have a transient local LaunchServices/loader failure mode: one
   launch failed before assertions and a later second launch wedged before test
   code. A separate retry passed all 17 app-hosted tests; run Core and hosted targets
   sequentially and distinguish launcher failures from assertion failures.
5. `GlobalShortcutSettings.swift` is a now-unused legacy pane; current Settings uses
   the combined keybind pane and `ShortcutCaptureField`.

Production builds no longer append the development debug log; `DebugLog` is compiled
to write only under `DEBUG`.

## Deferred work and hook points

The detailed post-v1 sequence is already written:

- `PRD-7.md`: complete and human-verified on 2026-07-12. Duration-preserving
  replacement uses the shared trim selector, explicit replacement recording target,
  retained-source recipe, safe swap, and full retranscription without shifting later
  timeline positions.
- `PRD-8.md`: implementation complete in the current worktree but human-unverified.
  Its 23 checks were skipped under the explicit 2026-07-17 one-time transition
  waiver; no `milestone-8` verified tag exists or may be claimed.
- `PRD-9.md`: a focused, locally bundled CodeMirror 6 decorated-source workbench for
  Original, Edited view, and Edited editing. It adds Markdown/GFM/selected Obsidian
  styling, smart editing, find/replace, typography and focus controls, existing-link
  navigation, tag-aware vault search, and safe external-edit merging. Outline,
  backlinks/Linked Mentions, wikilink autocomplete or note creation, inbound rename
  rewriting, tag panes/counts/writing, and layer diff are removed rather than
  deferred. It is the current implementation milestone under the one-time waiver;
  `PRD-9-start-here.md` is its exact starting-state handoff. Normal Milestone 9
  verification remains mandatory.
- `PRD-10.md`: a third Original / Edited / Summary layer backed by a basic,
  local-only summarization model. The implementation must benchmark below 8 GB peak
  resident memory, store Summary as a separate derived Markdown artifact, preserve
  both transcript layers, and mark summaries stale rather than regenerating silently.
- `PRD-20.md`: a far-horizon, versioned `transcride` CLI and agent interface. The
  root command self-describes the supported media/vault contract and current vault;
  `transcride import <audio-file>` uses the canonical import/transcription path; and
  vault discovery, job status, stable JSON/errors, idempotency, app/CLI coordination,
  signing, and local-only security make the surface safe for automation. Milestones
  11–19 remain intentionally unspecified for nearer product work.

Silence-removal compression was implemented after 1.1 as a standalone destructive
audio action. Its per-entry source is either audio below -40 dBFS or validated timed
Original word gaps (including clip edges). It retains 0.1 seconds at each boundary,
renders and validates an M4A, refuses swaps that do not reduce file size, and stages
the pre-compression version in Recently Deleted. Because it deletes time, it queues
one full retranscription and preserves hand-edited Markdown under the existing
retranscription contract. `VaultService.compressAudio` re-reads the persisted mode
at mutation time; unavailable speech timing blocks before rendering or swapping.

Master-PRD/post-program items still deferred: cloud engines (implement the existing
engine protocol), sync (coordinate external mutations through `VaultService` and
search invalidation), AI chapters/action items/chat beyond the scoped PRD-10 Summary
layer (new derived artifacts must never replace the Markdown source of truth), the
PRD-20 CLI/agent interface, iOS capture, plugins, localization, and an auto-update
framework. Transcride remains local-only and telemetry-free unless the product
principles are explicitly changed.

## Build, test, install, and release

Regenerate after adding/removing source files or changing project settings:

```sh
xcodegen generate
```

Run the complete suite:

```sh
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' test
```

Build a local release configuration:

```sh
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

For interactive testing, build Debug, replace `/Applications/Transcride.app` with
the DerivedData product, verify `codesign --verify --deep --strict`, compare the
installed/build executable hashes, and launch the installed copy.

Before publishing a binary release:

1. Install a valid Developer ID Application identity and set signing without
   committing personal team credentials.
2. Archive Release from a clean checkout.
3. Sign every nested component, notarize with `notarytool`, staple, package as DMG,
   and validate with both `codesign --verify --deep --strict` and `spctl -a`.
4. Test recording permission, model download, vault bookmarks, relaunch, and the v1.2
   acceptance flow from a clean macOS user account.
5. Tag the verified source as `milestone-7` and `v1.2.0`; publish release notes from
   `CHANGELOG.md` and attach only notarized artifacts.

The current machine has no valid code-signing identities. Source/tag publication is
ready; any attached ad-hoc-signed beta archive must be labeled unsigned, include its
SHA-256 checksum, and document the macOS Open Anyway flow.
