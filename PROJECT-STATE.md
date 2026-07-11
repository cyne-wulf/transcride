# Transcride project state

Last updated: 2026-07-11
Release line: 1.1.0 (build 2)
Verified gate: Milestone 6, 14/14 human checks
Platform: macOS 15+, Apple silicon, Swift 6, SwiftUI

## Product state

Milestones 1–6 are complete. Version 1.1 delivers the complete local workflow:
record or import audio, transcribe it on-device, review it against synchronized
playback, edit a Markdown layer, search the vault, export or copy the knowledge,
optionally delete the audio while retaining the note, and safely extend an existing
recording with full retranscription and version recovery.

The vault is the product's source of truth. It remains useful without Transcride:
notes are Markdown, audio uses ordinary media formats, timed transcripts are JSON,
and entry/folder names are human-readable. The SQLite search index and waveform
files are derived caches.

The next gated milestone is `PRD-7.md`. Read `PRD-7-start-here.md` first and do not
begin it merely because the handoff exists; follow the milestone gate in
`CLAUDE.md`/`AGENTS.md`.

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

### Vault and entry contract

Entry folders are named `transcride-YYYY-MM-DDTHH-mm-ss[-slug]`. The timestamp is
the stable identity; renaming changes only the readable slug.

An entry may contain:

- `transcript.md` while untitled, or `<Title>.md` after naming.
- One visible audio file, normally `audio.m4a`; imported formats remain unchanged.
- `transcript.original.json`, the immutable timed engine result.
- `waveform.json`, a regenerable playback cache.
- Frontmatter including `title`, `created`, `duration`, `favorite`,
  `audio_deleted`, `source`, `engine`, `hand_edited`, and optional speaker names.

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
  playhead publishing, and user-seek revisions.
- `WaveformGenerator`/`WaveformData`: streaming decode and cache schema.
- `AudioTrim` + `TrashStore`: packet-preserving trim where possible, safe swap,
  recovery, duration update, then full retranscription.
- `AudioExtensionComposer` + `AudioExtensionApplier`: validated append-only
  composition, safe swap, recoverable pre-extension versions, stale-timing state,
  relaunch convergence, then exactly one full retranscription.

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

- `TranscriptWorkbenchView`: Original/Edited layers, NSTextView bridges, autosave
  plus explicit Save, undo, find, copy, speaker labels, timed highlighting/follow.
- `TranscriptWordMap`: one UTF-16 coordinate map for rendered words, times, search
  matches, clicks, and karaoke state.
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

## Known issues and technical debt

### P1 — release/distribution blockers

1. **No Developer ID signing identity is installed on the current machine.**
   `project.yml` intentionally produces ad-hoc signed local builds. A downloadable
   app must be Developer-ID signed, notarized, and stapled before strangers can run
   it without Gatekeeper warnings.
2. **No repeatable distribution script exists.** Add the notarized DMG pipeline
   described by `PRD-9.md` once credentials and the intended distribution URL exist.

### P2 — product/runtime debt

1. Auto-title rename unloads the player because selection remapping triggers the
   normal entry-switch path; playback stops if transcription lands mid-play.
2. Switching entries resets playback speed to 1x. This is currently intentional but
   may not match every user's preferred session behavior.
3. Loaded transcription models remain in memory for the app lifetime; Whisper large
   can retain substantial RAM after long work.
4. Edited-layer karaoke disables after a real edit because character offsets no
   longer correspond to timed engine words. Search cueing remains best-effort.
5. A microphone connected while its picker is already open appears after reopening
   the menu; the underlying device list itself does refresh.
6. Apple Speech is available only where the required macOS framework exists and is
   hidden on earlier supported systems.
7. Pre-1.1 AAC/ALAC CAF partials interrupted before close can lack their packet
   table. The bytes remain preserved and are acknowledged once, but cannot always
   be decoded; 1.1+ PCM journals do not have this failure mode.

### P3 — maintenance notes

1. `xcodebuild` on the current development Mac prints an out-of-date CoreSimulator
   warning. macOS builds/tests still pass; the warning is an Xcode installation issue.
2. `PlaybackSection` reads the small waveform cache on entry open; acceptable at the
   verified scale.
3. A late editor blink has not reproduced. If it returns, inspect self-generated
   FSEvents leaking into `externalVaultRevision`.

Production builds no longer append the development debug log; `DebugLog` is compiled
to write only under `DEBUG`.

## Deferred work and hook points

The detailed post-v1 sequence is already written:

- `PRD-7.md`: duration-preserving replacement of a selected audio region with
  multiple takes and non-destructive source retention. Reuse the trim selector,
  explicit recorder target model, extension safe-swap invariants, and transcription
  seam without changing later timeline positions.
- `PRD-8.md`: global recording controls from the menu bar and system-wide shortcut,
  reusing the single-recorder and crash-recovery contracts.
- `PRD-9.md`: an editor workbench for note structure and presentation.

Silence-removal compression was requested during Milestone 6 but remains deferred:
it deletes time and shifts every later transcript timestamp, so it belongs in a
separately specified destructive-audio milestone rather than PRD-6 or PRD-7.

Master-PRD/post-program items still deferred: cloud engines (implement the existing
engine protocol), sync (coordinate external mutations through `VaultService` and
search invalidation), AI summaries/chapters (new derived artifacts; never replace the
Markdown source of truth), iOS capture, plugins, localization, and an auto-update
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
4. Test recording permission, model download, vault bookmarks, relaunch, and the v1.1
   acceptance flow from a clean macOS user account.
5. Tag the verified source as `milestone-6` and `v1.1.0`; publish release notes from
   `CHANGELOG.md` and attach only notarized artifacts.

The current machine has no valid code-signing identities. Source/tag publication is
ready; any attached ad-hoc-signed beta archive must be labeled unsigned, include its
SHA-256 checksum, and document the macOS Open Anyway flow.
