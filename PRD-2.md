# PRD-2 — Milestone 2: Recording, Import & Playback (Voice Memos Core)

> **Before starting:** read `PRD-2-start-here.md` (written at the end of Milestone 1) for project state, build instructions, and the entry-folder contract. Full product context: [master-prd-backup.md](master-prd-backup.md) §5.2, §5.3 (import only), §5.6, §7. Do not start until the human confirms Milestone 1's checklist is verified.

## Goal

Make transcride a fully working voice recorder — the Voice Memos core. Record with pause/resume and a live waveform, import existing audio files, and play everything back with a scrubbable waveform and proper transport controls. At the end of this milestone there is still **no transcription**: entries have audio but their `transcript.md` is a stub. The audio capture and playback layer built here is what transcription (M3) and text-sync (M4) plug into.

## Scope

**In:** AVFoundation recording, mic selection, quality settings, zen mode, audio import, waveform generation + rendering + scrubbing, transport controls, entry creation from recordings/imports.

**Out:** transcription of any kind, word highlighting, Skip Silence, trim/audio editing, delete-audio-keep-note, share sheet.

## Requirements

### Recording (REC-1..REC-6)
- **REC-1:** A record button is always visible in the main window. One click starts recording immediately into a new entry (folder created up front with the timestamp name; audio streamed to disk, not memory).
- **REC-2:** Pause and resume mid-recording. Live scrolling waveform and elapsed time render while recording.
- **REC-3:** Microphone input selection (system default + all available input devices), in settings and as a quick picker near the record button. Handle device disappearance mid-recording gracefully (pause + alert, no data loss).
- **REC-4 (partial):** On stop: audio is finalized as `audio.m4a` in the entry folder and a stub `transcript.md` is written with frontmatter (`title` = "New Recording", `created`, `duration`, `source: recorded`) and an empty body. (M3 replaces the stub flow with real transcription queueing — leave a clearly-marked seam.)
- **REC-5:** **Zen mode**: a chrome-free full-window recording view — waveform, elapsed time, pause/stop only. Entered by an explicit control; Esc exits after stopping.
- **REC-6:** Quality setting: compressed (default — AAC mono 64 kbps, 44.1 kHz) or lossless (ALAC). Stored in settings; applies to subsequent recordings.
- Microphone permission requested on first record with a clear usage description.

### Import (TRN-1, TRN-2 partial)
- Drag-and-drop onto the window and File → Import (multi-select). Accepted: m4a/aac, mp3, wav, flac, ogg/opus, aiff, and audio tracks of mp4/mov.
- Each import copies the file into a new entry folder (original file untouched), keeping its original format and extension; stub `transcript.md` written with `source: imported`, title from the source filename, duration probed via AVFoundation. Batch import creates one entry per file.
- Unsupported/corrupt files produce a per-file error, not a crash, and don't block the rest of the batch.

### Playback (PLY-3, PLY-4)
- Detail view for an entry with audio: waveform on top, transport below, (stub) transcript area beneath.
- **PLY-3:** Waveform rendered from `waveform.json` (peaks cache, generated on first open or after recording; rebuildable — delete the file and it regenerates). Drag anywhere on the waveform to scrub; playhead tracks during playback.
- **PLY-4:** Play/pause (space bar when the detail view has focus), skip back/forward 15 s, playback speed 0.5×/0.75×/1×/1.25×/1.5×/2× (pitch-preserved).
- Playback state survives entry switching sanely (switching entries stops playback; returning does not auto-resume).

## Decisions already made
- Audio is immutable once recorded (no destructive edits until M5's trim, which will re-transcribe).
- Recording streams to a temp file and is atomically finalized on stop — a crash mid-recording must leave a recoverable partial file, not a corrupt entry.
- `waveform.json`: array of peak floats at a fixed resolution (~10 px worth of audio per peak at 1× zoom); exact schema is the implementer's choice but must be documented in the handoff.

## Definition of done
- All requirements implemented; unit tests for: waveform peak generation from a known WAV, import format detection, entry creation from record/import paths. `xcodebuild test` passes.
- A 2-hour recording works: streams to disk, waveform generation doesn't blow memory, scrubbing stays responsive.

## Verification checklist (human-run — all boxes required before Milestone 3)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: present one item at a time, give the human the exact steps and materials needed, wait for their pass/fail answer, and keep a running tally. On a fail: fix it, then re-verify that item plus any already-passed items the fix could have affected. Write the handoff document only after the human confirms every item.

- [ ] First record click prompts for mic permission; recording starts immediately after grant.
- [ ] Record 30 s with a pause/resume in the middle; live waveform scrolls while speaking; stop produces an entry with playable `audio.m4a` whose duration ≈ wall time minus paused time.
- [ ] The new entry appears in the library instantly with title "New Recording" and correct date/duration; renaming it works (M1 behavior intact).
- [ ] Mic picker lists available inputs; recording uses the selected device (test with headset vs built-in).
- [ ] Zen mode: full-window minimal recorder; record/pause/stop work; Esc returns to the library after stop.
- [ ] Quality toggle: one AAC and one ALAC recording; verify codecs in Finder's Get Info or `afinfo`.
- [ ] Drag 5 mixed files (mp3, wav, m4a, flac, and one mp4 video) onto the window: 5 entries created, originals untouched, titles from filenames.
- [ ] Import a corrupt/renamed-extension file: clear per-file error, other imports in the batch succeed.
- [ ] Waveform renders for recorded and imported entries; delete `waveform.json` in Finder, reopen entry, it regenerates.
- [ ] Scrub by dragging the waveform: audio follows; playhead tracks during normal playback.
- [ ] Skip ±15 s and each playback speed work; 2× is pitch-preserved (not chipmunk).
- [ ] Space bar toggles play/pause in the detail view.
- [ ] Record while browsing other entries and folders — the app stays fully usable during recording.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-3-start-here.md`**: everything the M1 handoff covered (updated file map, build/run/test), plus: the audio pipeline architecture (capture, finalization, playback services and how to call them), the `waveform.json` schema, the exact seam where "recording/import finished" should hand off to a transcription queue (file + function), the stub `transcript.md` format M3 must replace, and any AVFoundation gotchas discovered. Assume the reader knows nothing but PRD-3 and your document.
