# Transcride project state

Last updated: 2026-08-20
Release line: 1.2.0 (build 3)
Verified gate: Milestone 8, human-verified 2026-08-20
Platform: macOS 15+, Apple silicon, Swift 6, SwiftUI

## Product state

Milestones 1–8 are complete. Version 1.2 delivers the complete local workflow:
record or import audio, transcribe it on-device, review it against synchronized
playback, edit a Markdown layer, search the vault, export or copy the knowledge,
optionally delete the audio while retaining the note, and safely extend an existing
recording with full retranscription and version recovery. Milestone 7 adds
duration-preserving replacement of a selected audio region with multiple takes,
contextual audition, recoverable versions, and non-destructive retained sources.
Milestone 8 adds recording from anywhere — global hotkeys, a menu bar item, and a
floating background indicator over one serialized command surface — plus a complete
in-app shortcut remapper, Quick Move, optional Mac-system-audio capture mixed onto
the microphone, a durable microphone-failure ledger, and power-loss durability
barriers for live recording journals.

The vault is the product's source of truth. It remains useful without Transcride:
notes are Markdown, audio uses ordinary media formats, timed transcripts are JSON,
and entry/folder names are human-readable. The SQLite search index and waveform
files are derived caches.

The next milestone is milestone 9 (`PRD-9.md`, Local AI Summary Layer — renamed
from PRD-10 after the original PRD-9 editor workbench was removed at milestone-8
closeout). Read `milestone-8-handoff.md` first and follow the milestone gate in
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
- `TranscrideMenuBar`, `GlobalShortcutSettings`, `AppShortcutSettings`,
  `ShortcutCaptureField`, `QuickMoveView`: milestone-8 control surfaces.

### Global recording controls and shortcuts (milestone 8)

- `GlobalShortcutService` registers the two global hotkeys (⌥R start/stop-and-save,
  ⌥P pause/resume) with Carbon `RegisterEventHotKey` — no event tap, no
  Accessibility or Input Monitoring permission. Registration is atomic with
  rollback; per-action status (`registered`/`failed(reason)`) is surfaced in
  Settings. Preferences persist as JSON under `globalShortcutPreferencesV2`.
- Every recording entry point (in-app, hotkey, menu bar, indicator, termination)
  funnels through `AppModel.performRecordingCommand` guarded by
  `RecordingCommandGate`: one command in flight, repeats suppressed, a
  (command × availability-state) matrix produces canned unavailable reasons, and a
  second gate serializes extension/replacement starts across awaits.
- `GlobalRecordingPresentationState` is the one state model for the background
  indicator and the menu bar item. The indicator is a 72×72 borderless
  non-activating floating panel that joins all Spaces, is shown only while the app
  is inactive during a session or retention window, toggles recording on click,
  opens the app on long-press, and persists its position as a normalized per-display
  anchor under `globalIndicatorScreenAnchorV1`. The app's activation policy is never
  changed; it simply keeps running windowless.
- `AppShortcuts` defines the 59-action, two-slot in-app catalog with reserved keys,
  duplicate/global-conflict validation, visible shadowing (never silent drops), and
  `appShortcutPreferencesV1` persistence. One local keyDown monitor dispatches
  through `AppShortcutEventMatcher`; global chords always outrank local bindings,
  and text editing always wins for deferring actions.
- Live-capture durability: `DurableAudioJournalWriter` (hand-rolled CAF, verified
  close-time size patch, recovery-side `repairDataChunkSize`) and `FileDurability`
  bound power-loss audio loss to ~5 s via coalesced `F_FULLFSYNC` barriers off the
  capture thread; the sparse Mac-audio sidecar shares the cadence, and recovery
  salvages torn tails. Do not reintroduce `AVAudioFile` for live journal writes.

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

### Milestone 8

- The in-app shortcut remapper (59 actions, two slots), Quick Move (⌥M), optional
  universal recording (Mac system audio via ScreenCaptureKit mixed onto the
  microphone journal), and the durable microphone-failure ledger were added by
  user-approved addenda inside PRD-8.md.
- A 34-finding pre-flight audit-fix program ran after implementation. The ⌥M
  "types µ in text fields" finding is expected behavior: Quick Move defers to text
  editing by design.
- Power-loss durability hardening was a user-approved standalone addition; an
  adversarial durability audit followed, and every refuted claim (torn close-time
  size patch, capture-callback sync, `AtomicFile` fsync fallback, stale degraded
  flag, discarded torn-tail sidecar records) was remediated before the gate.
- Zen mode gained spacebar control (start when idle, pause/resume while active;
  Space never stops a take), and Settings → Recording gained an explicit
  two-permission status section, both at user request.
- Quit-and-recover now preserves an active Mac-audio sidecar so recovery can mix
  it, matching crash recovery.
- The original PRD-9 (editor workbench) was removed from the roadmap at closeout;
  the milestone-8 handoff is `milestone-8-handoff.md` rather than a
  `PRD-9-start-here.md`. PRD-10 was later renamed to `PRD-9.md` (Local AI Summary
  Layer) and pulled forward as milestone 9.

## Known issues and technical debt

### P1 — release/distribution blockers

1. **No Developer ID signing identity is installed on the current machine.**
   `project.yml` intentionally produces ad-hoc signed local builds. A downloadable
   app must be Developer-ID signed, notarized, and stapled before strangers can run
   it without Gatekeeper warnings.
2. **No repeatable distribution script exists.** Add a notarized DMG pipeline once
   credentials and the intended distribution URL exist.

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

Production builds no longer append the development debug log; `DebugLog` is compiled
to write only under `DEBUG`.

## Deferred work and hook points

The detailed post-v1 sequence is already written:

- `PRD-7.md`: complete and human-verified on 2026-07-12. Duration-preserving
  replacement uses the shared trim selector, explicit replacement recording target,
  retained-source recipe, safe swap, and full retranscription without shifting later
  timeline positions.
- `PRD-8.md`: complete and human-verified on 2026-08-20. Global recording controls
  from the menu bar, system-wide shortcuts, and a background indicator over the
  single-recorder contract, plus the shortcut remapper, Quick Move, universal
  recording, failure ledger, and durability additions logged above.
- The original PRD-9 (editor workbench for note structure and presentation) was
  removed from the roadmap at milestone-8 closeout; its content is not planned.
- `PRD-9.md` (milestone 9, renamed from PRD-10): a third Original / Edited / Summary
  layer backed by a basic, local-only summarization model (MLX Swift + Gemma 3 QAT
  4-bit, RAM-adaptive 1B/4B default). Summaries are user-editable derived artifacts.
  The implementation must benchmark below 8 GB peak resident memory, store Summary
  as a separate derived Markdown artifact, preserve both transcript layers, and mark
  summaries stale rather than regenerating silently.
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
search invalidation), AI chapters/action items/chat beyond the scoped PRD-9 Summary
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
