# PRD-6 — Milestone 6: Extend a Recording

> **Before starting:** read [PROJECT-STATE.md](PROJECT-STATE.md), especially the recording/playback, transcription, trim/recovery, and vault-format contracts. **Do not start until the human confirms Milestone 5 is verified.** This milestone adds one focused post-v1 capability. It must preserve every v1 guarantee: local-only operation, plain readable vault files, crash-tolerant capture, atomic mutation, and protection of hand-edited notes.

## Goal

Let a user return to an existing recording and keep talking. A small red record control lives inside that entry's playback pill, visually distinct from the app's large New Recording button. Clicking it begins an extension at the end of the selected audio; stopping produces one continuous recording and refreshes its transcript.

The interaction should feel as simple as pressing Record. The implementation must account for the fact that it is safely combining a new live capture with an existing, potentially transcribed and hand-edited artifact.

## Scope

**In:** the in-transport Extend Recording control; append-only capture; pause/resume/stop while extending; safe audio concatenation and replacement; duration/waveform refresh; full retranscription; Original/Edited layer handling; crash and failure recovery; accessibility and keyboard/menu discoverability.

**Out:** recording over a selected range; inserting audio in the middle; deleting a section; non-destructive multi-clip timelines; crossfades; automatic transcript splicing; AI cleanup or summarization. Extending always adds audio at the end.

## User experience

### Entry point and visual treatment (EXT-1)

- Add a small solid red circle to the existing playback capsule that contains speed, skip-back, play/pause, skip-forward, Skip Silence, and trim controls.
- The control is deliberately smaller and quieter than the main New Recording button. It has no pulse/breathing animation while idle and must not be mistaken for the global create-new-recording action.
- Place it at the trailing end of the transport controls, separated enough from Trim to avoid accidental activation. Its tooltip and accessibility label are **"Extend Recording"**. Hover/focus treatment must make the hit target clear even though the visible red circle is small.
- Show the control only for an entry with available audio. It is not shown for note-only entries or entries whose audio is in Recently Deleted.
- The command is also reachable from the entry's More menu and the macOS menu bar. Any shortcut must be documented in the Keyboard Shortcuts window; do not assign a bare key that can fire while editing text.

### Starting an extension (EXT-2)

- Clicking Extend Recording starts capturing immediately after microphone permission and input validation succeed. There is no setup sheet or countdown.
- Playback stops before capture starts. The operation always targets the physical end of the audio file, regardless of the current playhead position.
- The selected entry and target audio identity are captured when the action begins. Renaming, moving, deleting, trimming, retranscribing, or replacing that entry is unavailable until the extension finishes or is discarded.
- Only one recorder may be active app-wide. Extend Recording is unavailable while a new recording or another extension is recording, paused, or finalizing.
- Extend Recording is unavailable while that entry is being transcribed, trimmed, restored, deleted, or otherwise mutated. The tooltip explains the specific reason instead of silently ignoring the click.

### Active extension state (EXT-3)

- Once capture begins, the playback pill changes into an unmistakable extension state for that entry: **"Extending"**, the newly recorded elapsed time, a live waveform tail, Pause/Resume, and Stop.
- The time display shows the new segment duration, with the future combined duration available as secondary text. It must not imply that the existing recording is being replayed or overwritten.
- The main window's existing recording status remains the app-wide source of truth. If the user changes windows or the detail view is temporarily obscured, Pause/Resume and Stop must remain reachable; there must never be an active extension with no visible way to stop it.
- Space pauses/resumes while extending, following the existing active-recorder precedence. Escape does not discard or stop a recording. Closing the window or quitting while an extension is active uses the same protective confirmation/recovery behavior as a new recording.
- Live transcription, when enabled, may show ghost text for the newly captured segment, but it remains display-only. It is discarded when the full combined audio is queued for authoritative batch transcription.

### Stopping and transcript behavior (EXT-4)

- Stop first finalizes the new segment independently. Only after the segment is valid does Transcride construct a combined audio file containing the old audio followed immediately by the new segment.
- The finished entry remains one ordinary audio file in the vault, not a playlist or proprietary project. Prefer packet-preserving concatenation when the source formats permit it. If the formats require normalization, export a new M4A using the selected recording-quality setting and never replace the original until the export has completed and validated.
- Validate that the combined file is readable and that its duration is plausibly the old duration plus the captured duration. Then perform an atomic/safe swap, update frontmatter duration, invalidate/regenerate `waveform.json`, bump the app's audio revision, reload the player, and synchronize the search/vault snapshot.
- Queue one **full retranscription of the combined audio** through the existing persistent transcription seam. Do not splice new words into `transcript.original.json`: full retranscription keeps word timestamps, diarization, vocabulary correction, Skip Silence, karaoke highlighting, and search-to-audio mapping internally consistent across the join.
- Retranscription follows the existing layer contract: archive the prior `transcript.original.json`; replace the Original layer when the new result lands; regenerate Markdown only if the note was never hand-edited; never overwrite a hand-edited Edited layer. For a hand-edited entry, show the existing clear notice that Original was refreshed and Edited was left untouched.
- Until retranscription finishes, the existing transcript stays readable and editable but is visibly labeled as belonging to the pre-extension audio. Playback remains available for the combined audio; timed transcript highlighting is disabled beyond the old transcript's known duration rather than presenting incorrect word alignment.

## Safety and recovery

### Non-destructive file operation (EXT-5)

- Record the new material into an extension-specific hidden partial inside the entry, separate from the normal new-recording partial. Never write directly into or truncate the existing audio file.
- The existing audio remains untouched while recording, while finalizing the segment, and while constructing the combined output. The original is displaced only after the combined file passes validation.
- Reuse the proven trim/trash safe-swap pattern. Once the combined file is installed, stage the pre-extension audio and its old waveform in Recently Deleted as a recoverable **pre-extension version**. Restoring it removes the appended material, stages the combined version in its place, restores duration/waveform state, and triggers a full retranscription under the same Edited-layer rules.
- Temporary files use explicit names and lifecycle states so the vault scanner ignores them and recovery can distinguish: actively recording segment, finalized segment awaiting join, validated combined output awaiting swap, and abandoned temporary output.
- A failed join, export, validation, metadata write, or swap leaves the last known-good audio playable. Surface a useful error and retain the finalized extension segment so the user can retry the join or export that segment before discarding it.

### Crash and relaunch recovery (EXT-6)

- If the app or Mac stops during capture, the extension partial remains recoverable without changing the existing audio.
- On next vault open, detect recoverable extension artifacts and offer: **Finish Extending**, **Save Segment as a New Entry**, or **Discard Segment**. Never auto-append uncertain data and never delete a recoverable segment silently.
- If the crash occurred after the safe swap, recovery converges on exactly one visible current audio file and one matching duration. Idempotent recovery must not append the same segment twice.
- Recovery and retry are local-only and must work without a transcription engine being available. Audio recovery succeeds first; transcription can remain queued or failed independently.

## Architecture requirements

### Recorder and audio composition (EXT-7)

- Extend `RecorderService` with an explicit session target/mode rather than branching on filenames throughout the service. New-entry recording and entry-extension recording share microphone selection, `@Sendable` tap safety, live tee, pause/resume, device-change recovery, and crash-tolerant CAF writing, but have separate finalization outcomes.
- The recording sink must continue to write before forwarding buffers to live transcription. No extension or live-transcription failure may endanger captured audio.
- Add a Core-level, unit-testable extension plan/state model and a dedicated audio-composition/safe-swap component. Keep filesystem and AVFoundation work out of SwiftUI views.
- `AppModel` owns the user intent and app-wide state transition; `VaultService` owns entry mutation; `TranscriptionSeam` remains the only route that queues the combined audio.
- Do not hard-code `audio.m4a` or `transcript.md`. Discover the current media and Markdown through the existing entry/`TranscriptFile` contracts, and preserve unknown frontmatter fields with `FrontmatterDocument`.

## Decisions already made (do not relitigate)

- Extend means **append at the physical end**, never insert at the playhead and never overwrite existing audio.
- The small red circle lives inside the playback pill and is visually distinct from the main New Recording button.
- Starting is immediate; stopping is explicit. There is no countdown.
- The result is one normal audio file, not multiple clips hidden behind an app-only manifest.
- Full retranscription is required after a successful append. Transcript splicing is out because it would weaken timing, diarization, and text/audio correctness.
- A hand-edited layer is never overwritten.
- The existing audio is never mutated in place. A validated combined file is safely swapped in, and the prior version is recoverable from Recently Deleted.
- Extending imported audio is allowed when AVFoundation can read and export it. The resulting combined file may become M4A; the untouched pre-extension import remains recoverable. Unsupported/protected inputs show an explanatory disabled state.

## Definition of done

- All requirements are implemented with no regression to new recording, import, playback, trim, audio deletion/restoration, transcription, or Edited-layer preservation.
- Unit tests cover: extension state transitions; availability/block reasons; duration planning/tolerance; temporary-artifact recovery classification; idempotent safe-swap recovery; frontmatter preservation; restore-pre-extension behavior; queueing exactly one full retranscription.
- Integration tests cover: compatible-format append; normalization append; zero/very-short segment cancellation; join/export failure preserving original audio; crash artifacts at each lifecycle phase; a hand-edited entry remaining byte-identical after append and retranscription.
- `xcodebuild test` passes. A release-style build records, appends, relaunches, plays, and re-transcribes without relying on development paths or network access.

## Verification checklist (human-run)

**Verification is interactive.** Present one item at a time with exact steps, wait for pass/fail, and keep a running tally. Fix failures and re-verify affected passed items. Write the handoff only after every box is human-confirmed.

- [ ] Open an entry with audio: a small red circle appears inside the playback pill, reads as part of that transport, and is clearly not the main New Recording button. Tooltip and VoiceOver say "Extend Recording."
- [ ] A note-only entry and an audio-deleted entry do not show the control. While another recording is active, the action is unavailable with a specific explanation.
- [ ] Start while the playhead is in the middle: playback stops and recording begins immediately at the end, not at the playhead. Speak a recognizable final sentence, pause, resume, speak again, then stop.
- [ ] During capture the UI says Extending, shows only the added elapsed time and live waveform, and keeps Pause/Resume and Stop reachable. Space pauses/resumes; Escape does not lose the capture.
- [ ] After stopping, the audio plays continuously through the old/new boundary and includes both new phrases in order. Duration and waveform cover the full combined file after relaunch.
- [ ] The full retranscription runs automatically. The new Original has valid word timing across the whole recording; click-to-seek, karaoke, Skip Silence, search jump-to-moment, and speaker labels still align after the join.
- [ ] Repeat on a hand-edited entry: the prior Original is archived, the refreshed Original includes the extension, the Edited Markdown is byte-identical, and the app clearly says it was left untouched.
- [ ] Extend a supported imported audio file: the combined result is playable and plain-file readable; if normalized to M4A, the UI explains the change and the original import is recoverable.
- [ ] Restore the pre-extension version from Recently Deleted: appended audio disappears, duration/waveform revert, full retranscription runs, and a hand-edited layer remains untouched. Restore the combined version back again.
- [ ] Force a join/export failure using the test seam: the original remains playable and the extension segment can be retried or saved as a new entry.
- [ ] Use a recovery fixture for each interrupted phase: partial capture, finalized segment, combined output before swap, and swap before cleanup. Relaunch offers the correct recovery and never appends twice.
- [ ] Regression: create a normal new recording, pause/resume, stop, auto-transcribe, trim it, delete/restore its audio, and play at a non-1× speed; all existing behavior still works.
- [ ] VoiceOver and keyboard-only operation can start, pause/resume, and stop an extension and understand when finalization/retranscription is in progress.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-7-start-here.md`** with: state summary; build/run/test commands; changed file map; the extension session state machine; temporary filenames and recovery classification; safe-swap/restore invariants; how `RecorderService` distinguishes new-entry vs extension finalization; how the combined file reaches `TranscriptionSeam`; Edited-layer behavior; deviations; known issues. Append milestone deviations and new hook points to `PROJECT-STATE.md`. Close with the fresh-model assumption line used by prior milestone handoffs.
