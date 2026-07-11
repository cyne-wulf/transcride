# Start here — Milestone 7

> Assume you are a fresh model with zero context beyond PRD-7.md and this document.

## State summary

Milestone 6 was human-verified 14/14 on 2026-07-11 and released as Transcride
1.1.0 (build 2). It adds append-only **Extend Recording** to an existing entry,
full retranscription of the combined audio, recoverable pre-extension versions,
interrupted-extension recovery, and a fixed-width PCM recording journal that
survives abrupt process termination.

Do not begin Milestone 8 until every item in PRD-7's verification checklist has
been human-confirmed. PRD-7 is the duration-preserving Replace Selected Audio
Region milestone; read that PRD before changing the implementation below.

## Build, test, and run

The project is generated from `project.yml`; never edit the Xcode project by hand.

```sh
xcodegen generate
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

After a local app task, replace the installed app and verify its signature:

```sh
ditto ~/Library/Developer/Xcode/DerivedData/Transcride-*/Build/Products/Debug/Transcride.app \
  /Applications/Transcride.app
codesign --verify --deep --strict /Applications/Transcride.app
```

The test target compiles Core directly without an app host. App/UI behavior still
requires the human checklist.

## Changed file map

### Core

- `RecordingExtension.swift` — stable target identity, session state machine,
  block reasons, artifact names, recovery classification/discovery, and duration
  tolerance planning.
- `AudioExtension.swift` — old-plus-segment AV composition, validation, safe
  install, and the one-shot Debug failure injector.
- `CrashTolerantAudioJournal.swift` — fixed-width 16-bit mono PCM journal plus
  normal-stop AAC/ALAC M4A encoding.
- `InterruptedRecordingRecovery.swift` — relaunch recovery for ordinary recordings
  and one-time acknowledgement of undecodable legacy packetized CAF partials.
- `ExtensionTranscriptState.swift` — hidden derived marker recording how much of
  the combined audio still has authoritative word timing.
- `TrashStore.swift` — symmetric pre-extension audio version staging/restoration.
- `TranscriptionApplier.swift` — clears the stale-extension marker only after the
  authoritative replacement transcript lands.

### App

- `RecorderService.swift` — explicit new-entry versus extension targets, separate
  extension partial/segment finalization, and PCM journaling.
- `VaultService.swift` — extension compose/swap, recovery actions, supported-input
  probing, restore convergence, and exactly-once retranscription handoff.
- `AppModel.swift` — extension intent/state, plain `E` toggle, ordinary and extension
  recovery discovery, recovery actions, UI notices, and mutation locks.
- `TranscriptionSeam.swift` — the `extended` source; this remains the only queue path.
- `AppTerminationDelegate.swift` / `TranscrideApp.swift` — protective active-capture
  close/quit handling.

### UI

- `EntryDetailView.swift` — leading grayscale Extend control (red on hover), active
  Extending transport, menus, and availability explanations.
- `ExtensionRecoveryView.swift` — Finish Extending, Save Segment as New Entry, and
  Discard Segment relaunch choices.
- `TranscriptWorkbenchView.swift` — pre-extension transcript notice and timing
  cutoff beyond the prior known duration.
- `AppCommands.swift` / `KeyboardShortcutsView.swift` — command/menu discovery,
  `E` documentation, and Debug-only failure commands.
- `RootView.swift`, `MainView.swift`, `RecorderBar.swift`, and
  `RecentlyDeletedView.swift` — recovery presentation and active-state coordination.

### Tests

- `RecordingExtensionTests.swift`, `AudioExtensionTests.swift`,
  `CrashTolerantAudioJournalTests.swift`, and
  `InterruptedRecordingRecoveryTests.swift` cover the pure state, composition,
  recovery classification, readable crash journal, and relaunch convergence.
- `TranscriptionApplierTests.swift` verifies stale-marker removal without touching
  a hand-edited Markdown layer.

## Extension session state machine

`RecordingExtensionSession` captures an immutable `RecordingExtensionTarget`
(entry relative path, source filename, and source duration). Its phases are:

`capturing ↔ paused → finalizingSegment → segmentReady → composing →
combinedReady → swapping → retranscribing → completed`

Any active phase can converge through `failed`; retry is allowed only from the
failed composition/swap boundary. `RecorderService` owns microphone capture and
segment finalization. `VaultService` owns every durable entry mutation.

## Temporary files and recovery classification

All extension artifacts are hidden inside the target entry so normal scanning
ignores them:

- `.extension-state.json` — persisted session/target and lifecycle phase.
- `.extension-recording.caf` — live fixed-width PCM capture.
- `.extension-segment.m4a` or `.extension-segment.caf` — finalized added material.
- `.extension-combined.m4a` — validated old-plus-new output awaiting installation.
- `.extension-transcript-state.json` — post-swap derived timing/normalization marker.

Discovery classifies these as partial capture, finalized segment, combined awaiting
swap, swap needing cleanup, or abandoned metadata. A post-swap relaunch converges
idempotently; it must never append the segment twice.

Ordinary new recordings use hidden `.recording.caf`. The live file is now
fixed-width PCM, so duration and packet boundaries can be derived without a close
operation. Relaunch installs a readable M4A where possible, falls back to readable
CAF, rebuilds metadata/waveform, removes the partial only after success, and queues
normal transcription.

## Safe-swap and restore invariants

- Existing visible audio is never opened for mutation or truncated.
- The new segment is independently finalized before composition begins.
- The hidden combined output must be readable and within duration tolerance before
  installation.
- The expected source filename is rechecked immediately before the swap.
- The prior visible audio and waveform move into Recently Deleted as a
  `preExtensionAudio` version before the combined file becomes visible.
- A failed install attempts rollback and always leaves a recoverable known-good
  version or segment.
- Restoring the pre-extension version symmetrically stages the combined version,
  restores duration/waveform state, marks transcript timing stale, and queues a full
  retranscription. Restoring again swaps forward without creating duplicate audio.

These invariants are the closest starting point for PRD-7's baked replacement,
but replacement must also keep total duration and all later timeline positions
stable.

## Recorder target and finalization distinction

`RecorderService.start` receives an explicit `RecordingSessionTarget`: new entry or
`extensionOf(RecordingExtensionTarget)`. Both share device selection, the
`@Sendable` audio tap, sink-before-live-tee ordering, pause/resume, device-change
handling, and PCM journaling. `stop()` returns a typed outcome. New-entry stop
creates the ordinary recording; extension stop retains the target and yields a
separate finalized segment for `VaultService` to append.

Never infer the mode from filenames in UI or app code. PRD-7 should add a similarly
explicit replacement target/outcome instead of overloading extension semantics.

## Transcription and Edited-layer behavior

After a validated swap, `AppModel` queues exactly one full transcription using
`TranscriptionSeam.Source.extended`. It does not splice words. Until that run lands,
the old transcript remains readable/editable, carries a visible pre-extension
notice, and timed highlighting is disabled past `knownTranscriptDuration`.

`TranscriptionApplier` archives the old original and replaces it atomically. It
regenerates Markdown only when the note was not hand-edited. A hand-edited
`transcript.md` remains byte-identical and receives the existing user-visible
"Original refreshed, Edited untouched" notice. The hidden stale marker is removed
only after the new authoritative Original is installed.

## Deviations and user-approved additions

- The final Extend dot is at the far-left of the transport, grayscale at rest, and
  red only on hover. This supersedes PRD-6's original trailing solid-red placement.
- Plain `E` starts the selected entry's extension and pressing `E` again finishes
  it. The global key monitor always yields to editable text, so normal typing is
  unaffected. Command-Shift-R remains a menu-accessible alternative.
- PRD-6 prompted a broader crash-proof recording correction: live new recordings
  also use PCM journaling, and quit/window close now offers finish, cancel, or
  recover-later behavior.

## Known issues

- A partial written by a pre-1.1 build may contain AAC/ALAC CAF packets without the
  packet table that only a clean close could write. Those bytes cannot be decoded
  reliably. They are preserved unchanged and acknowledged once; all 1.1+ captures
  use the recoverable PCM journal.
- Distribution remains ad-hoc signed because no Developer ID Application identity
  or notarization profile is installed. Public unsigned beta archives therefore
  require the documented macOS Open Anyway flow.
- The Debug Testing menu intentionally exposes one-shot failures before composition,
  before safe swap, and immediately after safe swap. It is absent from Release.

## Fresh-model assumption

Assume you are a fresh model with zero context beyond PRD-7.md and this document.
