# Start here — Milestone 8

> Assume you are a fresh model with zero context beyond PRD-8.md and this document.

> **Historical handoff superseded for one transition — 2026-07-17:** The human
> explicitly waived the Milestone 8 verification gate for Milestone 9 only.
> Milestone 8 remains unverified with all 23 boxes unchecked and no verified tag.
> Use `PRD-9-start-here.md` for the authorized Milestone 9 implementation baseline.

## State summary

Milestone 7 was human-verified 17/17 on 2026-07-12. It adds focused replacement
of an exact audio region: lock one duration, record and audition multiple takes,
bake one take without moving later timeline positions, retain stable sources for
future overlapping replacements, recover interrupted sessions, and run one full
retranscription while preserving a hand-edited Markdown layer.

The normal rule was not to begin Milestone 9 until every item in PRD-8's
verification checklist had been human-confirmed. The dated waiver above is the sole
exception. Read the current `PRD-8.md` transition note before relying on this
historical implementation handoff.

## Build, test, install, and run

The project is generated from `project.yml`; never edit the Xcode project by hand.

```sh
xcodegen generate
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' build
```

After local app work, replace the installed bundle and verify it:

```sh
pkill -x Transcride 2>/dev/null || true
rm -rf /Applications/Transcride.app
ditto <DerivedData>/Build/Products/Debug/Transcride.app /Applications/Transcride.app
codesign --verify --deep --strict /Applications/Transcride.app
shasum -a 256 <DerivedData>/Build/Products/Debug/Transcride.app/Contents/MacOS/Transcride.debug.dylib \
  /Applications/Transcride.app/Contents/MacOS/Transcride.debug.dylib
open /Applications/Transcride.app
```

The final Milestone 7 run passed 313 tests in 46 suites. The current development
Mac may print an out-of-date CoreSimulator warning; macOS builds/tests still run.

## Changed file map

### Core

- `AudioReplacement.swift` — locked frame region, take/session state, exact-duration
  eligibility, versioned retained-source recipe, slice replacement, render plan,
  recovery classification, and Debug failure points.
- `AudioReplacementEngine.swift` — history preparation, disk-space preflight,
  contextual preview, composite rendering, duration validation, anti-click boundary
  ramps, and safe installation.
- `AudioTrim.swift` — shared `AudioRangeSelection` rules used by Trim and Replace.
- `TrashStore.swift` — symmetric pre-replacement audio, waveform, and recipe-history
  version staging/restoration.
- `ClipEditHistory.swift` — persistent replacement undo/redo bookkeeping.
- `WaveformData.swift` — replacement preview splicing without timeline changes.

### App

- `RecorderService.swift` — explicit `.replacementTake` target, frame-boundary stop,
  partial capture, and complete/incomplete take finalization.
- `VaultService.swift` — session discovery/persistence, take files, preview rendering,
  bake orchestration, safe swap, waveform refresh, and replacement failure seams.
- `AppModel.swift` — serialized Replace intent/state, capture/audition/bake/cancel,
  relaunch recovery, mutation locks, retranscription, and Debug failure arming.
- `TranscriptionSeam.swift` — the `.replaced` source remains the only queue path.

### UI

- `TrimSelectionView.swift` — shared range overlay, handles, movement, precision,
  keyboard behavior, and accessibility.
- `EntryDetailView.swift` — menu entry point and focused replacement workspace with
  take list, previews, retry/change-region, export/delete, and bake confirmation.
- `RecentlyDeletedView.swift` / `TrashPreviewView.swift` — pre-replacement version
  discovery, preview, and reciprocal restore.
- `AppCommands.swift` — Debug-only one-shot render and safe-swap failure commands.

### Tests

- `AudioReplacementTests.swift` — frame eligibility, range rules, recipe overlap,
  render determinism/duration, recovery, restore/history matching, failure safety,
  and the 100-bake stress fixture.
- `AudioTrimTests.swift`, `TrashPreviewTests.swift`, and `WaveformTests.swift` cover
  the generalized selector and replacement-version/preview regressions.

## Shared Trim/Replace selector API

`AudioRangeSelection` is the pure normalized/clamped seconds representation.
`TrimSelectionOverlay` is the single waveform interaction used by both modes. It
owns handle hit priority, dragging, whole-range movement, click-to-seek behavior,
edge clamping, and accessibility adjustments. Replace converts the committed
selection into `ReplacementRegion`; do not fork another selector implementation.

## Replacement take state machine

`ReplacementTakeSession` identifies the entry/source, locks one `ReplacementRegion`,
keeps numbered takes, and selects only a complete eligible take for baking. Phases:

`selecting → ready → capturing → finalizingTake → auditioning → rendering → swapping → retranscribing → completed`

Failures converge through `failed`; retry keeps complete takes. Changing region or
canceling writes a cancellation intent before cleanup so interrupted cleanup never
resurrects a deliberately discarded session.

## Exact-duration and frame rules

The region stores `startFrame`, `frameCount`, and `sampleRate`; frame coordinates
are authoritative. Capture stops at the locked frame boundary. Eligibility requires
the same sample rate and at most one frame of length difference. Early/failed input
is retained as Incomplete and cannot bake. Rendering validates final total duration
against the recipe's `totalFrames` within one frame; it never pads, loops, stretches,
or shifts later timeline positions.

## Recipe schema and retained sources

Hidden history lives in `.transcride-replacements/`. `recipe-v1.json` contains:

- `version`, `sampleRate`, and immutable `totalFrames`;
- sources identified as retained `master` or `take`, with file and frame count;
- ordered slices containing source id/start frame, timeline start frame, and length.

The canonical audio remains one normal visible file. If hidden history is deleted,
that file remains playable/exportable and the next Replace copies it as a new master.

## Slice overlap and supersession

For a new region, non-overlapping slices survive unchanged. An overlapping slice is
split into any prefix before the region and suffix after it, with source coordinates
adjusted for the suffix. One new take slice fills the selected timeline interval.
Unused sources are removed from the next recipe. Sorted slices must remain contiguous
from frame zero through `totalFrames`; therefore repeated/overlapping replacements
never shift later time or grow an arbitrary clip count.

## Render and safe-swap invariants

- Validate entry/source identity and disk space before rendering.
- Build the next complete history directory separately from current history.
- Render a hidden candidate M4A from stable sources; add only tiny boundary ramps.
- Validate readability and total frame length before touching canonical audio.
- Stage canonical audio, waveform, and matching history as a recoverable
  `preReplacementAudio` version.
- Install candidate plus its matching next history; rollback from Recently Deleted
  on any installation error.
- Regenerate waveform after success. A waveform failure is deferred and cannot
  invalidate the canonical audio.

Debug builds expose **Force Next Replacement Render Failure** and **Force Next
Replacement Safe-Swap Failure**. The command first confirms it is armed; the token
is one-shot and travels explicitly from `AppModel` to `VaultService`.

## Recovery phases

Hidden session/candidate artifacts classify as: partial take, takes ready, candidate
awaiting swap, swap needing cleanup, or abandoned metadata. Relaunch restores a safe
session for review, never auto-bakes a take, and treats a cancellation marker as
authoritative. Post-swap recovery is idempotent and never commits the same take twice.
Restoring a pre-replacement version keeps the reciprocal current version and matching
recipe baseline so undo/redo stays consistent.

## Transcription behavior

Previews and temporary takes do not touch transcripts. A successful bake marks timed
alignment stale and queues exactly one full transcription with source `.replaced`.
The prior Original is archived. Generated Markdown updates only when it has never
been hand-edited; an Edited layer remains byte-identical and receives the existing
Original-refreshed/Edited-untouched notice.

## Deviations and user-approved additions

- Replacement capture starts directly; the optional countdown described by PRD-7
  was not needed.
- Debug failure commands and their explicit armed confirmation were added during
  verification after the human check exposed that replacement failure injection
  did not previously exist.
- The verified milestone gate is commit `9bb64b5` plus its documentation closure.
  Post-gate local feature edits present during closure were deliberately excluded
  from the milestone tag because they were not part of the installed verified build.

## Known issues

- The app remains ad-hoc signed because no Developer ID Application identity or
  notarization profile is installed.
- The current Xcode installation prints a CoreSimulator version warning even though
  macOS builds and tests succeed.
- Hidden replacement history is supplementary by design. External deletion resets
  future editing to the current canonical composite as a new master; it cannot
  reconstruct earlier retained-source lineage.

## Fresh-model assumption

Assume you are a fresh model with zero context beyond PRD-8.md and this document.
