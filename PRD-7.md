# PRD-7 — Milestone 7: Replace a Selected Audio Region

> **Before starting:** read [PROJECT-STATE.md](PROJECT-STATE.md), `PRD-6-start-here.md`, and [PRD-6.md](PRD-6.md). **Do not start until the human confirms Milestone 6 is verified.** Reuse the existing trim range selector, recorder, waveform, safe-swap/Recently Deleted, transcription, and crash-safety contracts. This is intentionally a niche editing tool, not a new primary recording surface.

## Goal

Let a user select an exact region of a recording, make as many replacement takes as needed for that same region, audition them in context, and bake the chosen take into the audio.

The replacement has exactly the selected duration, so the total recording length and every later timeline position remain stable. After baking, the user can invoke Replace again on any region—including a region already replaced—and repeat without a hard clip limit.

## Scope

**In:** three-dot-menu entry point; reuse of the trim selector; exact-duration range locking; multiple temporary takes for one selection; take preview in context; choosing and baking a take; repeatable replacements; non-destructive edit recipe/source retention; safe composite rendering; duration/waveform/transcript refresh; crash-safe take capture; version recovery.

**Out:** a permanently visible Replace button; keyboard shortcut; global command; inserting audio that changes total duration; deleting time; stretching a take; automatic time-stretching; multitrack mixing; overlapping audible layers; fades/crossfades beyond tiny anti-click boundaries; a full DAW timeline.

## Entry point and selection

### Niche menu-only feature (RPL-1)

- **Replace Audio…** is accessible only from the selected entry's three-dot More menu.
- Do not add Replace to the playback pill, waveform toolbar, menu bar, context menu, Keyboard Shortcuts window, command palette, or global controls. The feature should remain discoverable for someone looking for advanced entry actions without making the normal recording interface more complex.
- Show the action only for an entry with available, writable audio. Disable it with a specific explanation while that entry is recording/extending, transcribing, trimming, restoring, deleting, or otherwise mutating.
- Choosing Replace Audio enters a focused replacement mode in the existing playback area. It does not begin microphone capture immediately.

### Reuse the trim selector (RPL-2)

- Reuse and, where necessary, generalize the existing `TrimSelectionOverlay`/trim range-selection component. Do not implement a second waveform selector with subtly different drag, keyboard, accessibility, or timing behavior.
- The user drags the same start/end handles over the waveform to choose the region to replace. The selected duration is always shown prominently.
- Replace selection uses time coordinates against the current baked composite. Because every replacement is duration-preserving, coordinates remain stable across unlimited later bakes.
- Require a meaningful non-zero range. Use the shared selector's precision and clamping rules; add fine adjustment controls if the current handles cannot reliably select short spoken phrases.
- Provide **Cancel** and **Record a Take** below the selector. Cancel leaves the audio and all transcript artifacts byte-unchanged.

## Recording replacement takes

### Lock an exact region (RPL-3)

- Pressing Record a Take locks the start, end, and exact target duration for the take session. The handles cannot move while any attempts are retained.
- A short visual countdown may prepare the user, but countdown audio is never included in the take.
- Each attempt records from zero to the locked selected duration and stops automatically at the exact boundary. The progress display counts through the replacement duration rather than the entry's full duration.
- Pause/resume is unavailable while recording a replacement take because it would break wall-clock alignment and create an ambiguous result.
- If the user stops early, the microphone/input fails, or the app cannot capture the complete duration, retain the audio as an **Incomplete Take** for listening or export, but do not allow it to be baked. Never silently pad, loop, stretch, or truncate an incomplete take to make it eligible.
- Use sample/frame counts—not UI timer ticks—to decide whether a take matches the target. The baked take must match the selected region to within one output sample/frame after format conversion.

### Multiple attempts for one region (RPL-4)

- The user can record unlimited attempts against the same locked region, subject only to available disk space.
- List attempts as Take 1, Take 2, and so on with duration, creation time, status, Play, and Delete. The newest complete attempt becomes selected by default, but no take is baked automatically.
- Recording another take does not overwrite prior attempts. Deleting an attempt requires no confirmation unless it is the only complete selected take; deleting captured files uses a safe local removal path.
- **Try Again** records another attempt with the exact same start, end, and duration. **Change Region** first confirms that current temporary attempts will be discarded or saved separately, then unlocks the selector.
- Take capture inherits PRD-6's crash-safe recording behavior. After relaunch, a recoverable replacement attempt returns to this take session when its entry and locked region can be identified safely; it is never baked automatically.

### Audition in context (RPL-5)

- A take can be played by itself or previewed **In Context** as: current composite before the selection, selected take in place of the region, then current composite after it.
- Context preview is temporary. It must not write the entry, regenerate the waveform, enqueue transcription, or change the canonical player state irreversibly.
- Clearly label whether the user is hearing Current Audio, Take N, or Preview in Context. Switching takes during preview must not mix them together.
- Provide enough lead-in/lead-out context to judge timing while allowing the user to seek and replay the complete preview.

## Baking and repeated composition

### Bake the chosen take (RPL-6)

- **Bake Selected Take** is enabled only for a complete take matching the locked duration.
- The baked result is: current composite from its beginning to selection start + the selected take + current composite from selection end to its end.
- The output duration must remain unchanged within one output sample/frame. Validate decodability, expected duration, and boundary integrity before replacing the current audio.
- Apply very short sample-level anti-click ramps only when required to prevent discontinuity clicks at the two cut boundaries. They must not create an audible crossfade or alter timing.
- Stop/unload playback before the safe swap. After validation, install the new composite atomically, regenerate `waveform.json`, preserve/update frontmatter, bump the audio revision, reload the player, refresh the vault snapshot, and clean up unchosen temporary attempts only after the bake succeeds.
- Show a final confirmation before Bake explaining that the chosen take replaces the selected time range, the entry will be fully retranscribed, and any hand-edited note will remain untouched.

### Unlimited subsequent replacements (RPL-7)

- After a bake completes, Replace Audio… can be invoked again immediately on the new composite. There is no product-level maximum number of baked replacement clips.
- Maintain a non-destructive replacement recipe and retained source material so repeated bakes render from stable sources rather than repeatedly transcoding the previous lossy output. This prevents cumulative quality degradation in untouched regions.
- The recipe describes a duration-preserving timeline made of slices from the original master and baked replacement sources. Baking a new take updates/splits timeline slices deterministically; a new replacement supersedes any prior slices covered by its selected region.
- Store recipe metadata and retained take sources in a hidden, versioned entry subdirectory ignored by the normal vault scanner. The currently baked canonical audio remains one ordinary playable file, so Finder, Quick Look, Obsidian, export/share, and other apps never require the recipe.
- If the hidden edit sources or recipe are removed externally, the current canonical composite remains fully usable. Future Replace begins from that composite as a new stable master; deleting edit history must never make the current audio unreadable.
- Unlimited means no arbitrary software cap. Surface a clear disk-space error before recording/rendering when the vault cannot safely hold a take, temporary composite, and rollback version.

### Recovery and prior versions (RPL-8)

- Reuse the trim/extension safe-swap pattern. The pre-bake canonical audio and matching waveform are staged in Recently Deleted as a recoverable **pre-replacement version** only after the new composite validates.
- Restoring a pre-replacement version stages the current composite in its place, repairs duration/waveform state, and triggers the same full retranscription rules. Retained edit history must either roll back consistently with the audio version or restart from the restored file as a new master—never apply a recipe to the wrong canonical audio.
- A failed recording, render, validation, metadata write, or swap leaves the last known-good canonical audio playable and all complete attempts available for retry.
- Crash recovery is idempotent. Relaunch must never bake a take twice or confuse an audition preview with a committed replacement.

## Transcript behavior

### Full retranscription after bake (RPL-9)

- Temporary attempts and previews do not affect transcripts.
- A successful bake queues exactly one full retranscription of the new canonical composite through `TranscriptionSeam`. Do not splice replacement words into `transcript.original.json`.
- Full retranscription re-establishes correct word timestamps, diarization, vocabulary corrections, karaoke highlighting, click-to-seek, Skip Silence, and search-to-audio mapping around the replacement boundaries.
- Archive the prior Original before applying the new result. Regenerate Markdown only for a never-hand-edited entry. Never overwrite a hand-edited Edited layer; show the standard notice that Original was refreshed and Edited was left untouched.
- While retranscription is pending, keep the prior transcript readable but clearly mark timed highlighting/search cues as stale for the replaced interval. Do not display knowingly incorrect word alignment inside that region.

## Architecture requirements

### Replacement edit model (RPL-10)

- Refactor the trim selector into a shared range-selection component consumed by both Trim and Replace, with pure selection validation and coordinate conversion covered by Core tests.
- Add pure, unit-testable types for locked take sessions, take eligibility, replacement recipes, timeline-slice splitting, overlap/supersession, render planning, and artifact/recovery classification.
- Put microphone capture in `RecorderService` using an explicit replacement-take session mode. Keep its `@Sendable` sink-before-live-tee safety and crash-tolerant partial writing.
- Put media reading/rendering, exact frame accounting, anti-click boundary processing, validation, and safe swap in dedicated audio components outside SwiftUI.
- `AppModel` owns intents and serialized mutation state; `VaultService` owns vault writes; `TranscriptionSeam` remains the one transcription entry point.
- Discover audio and Markdown through current entry/`TranscriptFile` contracts. Preserve unknown frontmatter fields with `FrontmatterDocument`; never hard-code `audio.m4a` or `transcript.md`.

## Decisions already made (do not relitigate)

- Replace Audio is a niche feature accessible only through the entry's three-dot menu.
- Replace reuses the trim selector. There is one range-selection interaction, not two.
- A take must have exactly the selected duration. Recording stops automatically at the boundary; incomplete takes cannot be baked.
- Multiple attempts may be recorded for one locked region and auditioned before choosing one.
- Baking replaces the selected region; it does not overlay simultaneous audio and never changes total duration.
- After baking, Replace can be used again indefinitely, including over an already replaced region.
- Stable source material plus a duration-preserving edit recipe prevents cumulative generational loss across repeated bakes.
- The canonical result is always one ordinary playable audio file. Hidden edit history is supplementary and its loss cannot break the current result.
- Every bake triggers full retranscription, and hand-edited Markdown is never overwritten.

## Definition of done

- All requirements are implemented with no regression to playback, trim, extend, recording, audio deletion/restoration, transcription, search, or Edited-layer preservation.
- Unit tests cover: shared selector bounds/precision; take exact-duration eligibility; incomplete takes; locked-region invariants; recipe slice splitting; overlapping and repeated replacements; duration preservation; render-plan determinism; source/recipe versioning; recovery classification; queueing one retranscription.
- Integration tests cover: recording multiple real takes; contextual preview; exact-frame bake; short and long regions; compressed and lossless sources; repeated overlapping bakes; safe-swap failure; crash during take/render/swap; external deletion of hidden edit history; byte-identical hand-edited Markdown.
- A stress fixture bakes at least 100 replacements across one recording without timing drift, arbitrary clip limits, cumulative corruption, or increasing loss in untouched source regions.
- `xcodebuild test` passes and the installed app is used for microphone, listening, and repeated-bake verification.

## Verification checklist (human-run)

**Verification is interactive.** Present one item at a time with exact steps, wait for pass/fail, and keep a running tally. Fix failures and re-run affected passed items. Write the handoff only after every box is human-confirmed.

- [x] Open an entry's three-dot menu: Replace Audio… appears there. Confirm it appears nowhere else—no playback-pill button, menu-bar command, shortcut listing, or global control.
- [x] Enter Replace: the waveform uses the same handles and behavior as Trim. Select a distinctive spoken phrase and verify the exact start, end, and duration are clear.
- [x] Record Take 1: after the countdown it records for exactly the selected duration and stops automatically. Record two more attempts; all three remain independently playable.
- [x] Stop one attempt early: it is labeled Incomplete, remains playable/exportable, and Bake is disabled for it rather than padding or stretching it silently.
- [x] Preview each complete take In Context: the lead-in and lead-out come from current audio, only the selected range changes, and no vault files/transcripts are committed during preview.
- [x] Choose Take 2 and bake it: the resulting audio contains Take 2 in exactly the range, the total duration is unchanged, both boundaries are free of clicks, and unchosen takes were not accidentally mixed.
- [x] Full retranscription runs once. The new Original matches the baked audio and word timing/click-to-seek/karaoke remain aligned before, inside, and after the replaced range.
- [x] Repeat on a hand-edited entry: the Edited Markdown is byte-identical and the app clearly says it was left untouched.
- [x] Invoke Replace again and bake a second region, then replace part of the first baked region. The newest take supersedes only its selected interval and all other baked edits remain audible.
- [x] Run the repeated-bake stress fixture: timeline duration and later cue positions do not drift, untouched regions do not accumulate audible transcoding damage, and no clip-count limit appears.
- [x] Remove the hidden replacement-history directory in a copy of the vault: the current composite still plays/exports normally and a future Replace can begin from it as a new master.
- [x] Restore a pre-replacement version from Recently Deleted: audio, waveform, edit-history baseline, and retranscription state return consistently.
- [x] Force a render/swap failure: the prior canonical audio remains playable and all complete takes remain available to retry.
- [x] Force-kill during take capture and during bake: relaunch retains recoverable audio, never auto-bakes an uncertain take, and never commits the same take twice.
- [x] VoiceOver and keyboard navigation can select a range precisely, record/switch/play takes, understand complete vs incomplete, and confirm Bake.
- [x] Regression: Trim still uses the shared selector correctly; normal Record, Extend, playback, delete/restore audio, and transcription still work.
- [x] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-8-start-here.md`** with: state summary; build/run/test commands; changed file map; shared Trim/Replace selector API; replacement take state machine; exact-duration/frame rules; recipe schema and source directory; slice overlap/supersession algorithm; render and safe-swap invariants; recovery phases; transcription behavior; deviations; known issues. Append milestone deviations and replacement-edit architecture to `PROJECT-STATE.md`. Close with the fresh-model assumption line used by prior milestone handoffs.
