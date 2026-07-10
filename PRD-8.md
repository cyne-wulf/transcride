# PRD-8 — Milestone 8: Capture Presence & Audio Finesse

> **Before starting:** read `PRD-8-start-here.md` (written at the end of Milestone 7) and [master-prd-backup.md](master-prd-backup.md) §5.2, §5.8. **Do not start until the human confirms Milestone 7's checklist is verified.** Sized for a single ~200K-token session; orchestrate with full-context forks (PRD-5 procedure) if context runs low. All new actions register in the CommandRegistry. This milestone completes the last Voice Memos-parity P2s (REC-7, AUD-4, AUD-5) and gives the app a presence beyond its own window.

## Goal

Remove the last friction between "I have a thought" and a safely captured, transcribed note — even when Transcride isn't frontmost — and finish the audio story so recordings can be repaired, not just trimmed. At the end of this milestone the app is *ambient*: a menu-bar presence records from anywhere, the system tells you when transcripts land, and a bad take or noisy room is fixable in place.

## Scope

**In:** menu-bar quick capture + global hotkey (REC-7), replace re-record (AUD-4), Enhance Recording (AUD-5), live input metering (CAP-1), transcription notifications + Dock progress (CAP-2), crash-safe recording guarantee (CAP-3), waveform hover timestamp (PLY-6).
**Out:** motion/appearance polish of these surfaces (Milestone 9); onboarding for the new permissions (Milestone 9 folds it into the tour); iOS/companion capture (post-program).

## Requirements

### Menu-bar quick capture & global hotkey (REC-7, master P2)
- A menu-bar extra (toggleable in Settings, on by default once granted): click → a compact capture popover with record/pause/stop, elapsed time, a live level meter, and a one-line live-transcription ticker (reusing the M3 live pipeline when the model is present). Recording lands in the vault and queues exactly like an in-app recording (same seam), into a configurable default folder.
- A global hotkey (default ⌃⌥⌘R, rebindable in Settings) starts/stops capture from any app, without stealing focus; while recording, the menu-bar icon animates (level-reactive) so there is always a visible "you are recording" indicator. If the main window is open, its recorder UI reflects the same session (one recorder, two faces — never two parallel recordings).
- Registered as commands; works when the main window is closed (app stays resident with the menu-bar extra enabled; quitting from the Dock quits fully — no zombie background process surprises).

### Replace re-record (AUD-4, master P2)
- On the waveform, select a range (reuses the M5 trim selection UI) and choose **Replace**: the app records over that range — new audio is spliced in (crop head + insert + tail, AVFoundation composition; export rules follow M5 trim's codec strategy), the pre-replace audio goes to `.trash/` as a restorable item (same pattern as pre-trim), and the file is re-transcribed automatically (M3 archive rules; hand-edited md untouched with the standard divergence notice). Punch-in UX: 2-second pre-roll playback before recording starts at the selection head; stop ends the insert (insert may be longer or shorter than the range it replaces).

### Enhance Recording (AUD-5, master P2)
- An "Enhance Recording" toggle on entries with audio: applies voice isolation / noise reduction as a **non-destructive processed copy** (`audio.enhanced.m4a` beside the original; toggle plays one or the other; frontmatter records the state). Implementation: Apple's voice-processing/audio-unit stack — no third-party DSP dependencies. Waveform shows the active version's peaks (second cache file). Enhancement never triggers re-transcription (timings are from the original; document the assumption that enhancement is time-preserving). Delete Audio (M5) removes both copies; storage overview counts both.

### Live input metering (CAP-1)
- The main recorder bar, Zen mode, and the menu-bar popover show a live input level meter *before* recording starts (arming preview from the selected input device) and during recording. Device picker is available in all three places. The meter must cost no measurable CPU when idle (tap only while the recorder UI is visible/armed).

### Notifications & Dock progress (CAP-2)
- When a transcription finishes or fails while the app is not frontmost, post a user notification (title = entry title, body = snippet or error; click opens the entry). Per-setting opt-out. The Dock icon shows determinate progress while the queue is non-empty and a badge count of failed items.

### Crash-safe recording (CAP-3)
- Harden the guarantee: kill -9 the app mid-recording → on relaunch, the recording exists in the vault up to within 2 seconds of the kill, playable, and auto-queued (finalize-on-write or recovery-on-launch of the in-progress file; document which). A visible "Recovered recording" annotation on the entry.

### Waveform hover (PLY-6)
- Hovering the waveform shows a timestamp tooltip and a thin preview playhead at the cursor; click still seeks (existing behavior unchanged).

## Decisions already made (do not relitigate)
- The menu-bar extra is a popover UI, not a full window; opening the main app from it is one click ("Open Transcride").
- Global hotkey default ⌃⌥⌘R; conflicts are the user's to rebind (detect-and-warn on registration failure, don't silently steal).
- Replace inserts a *variable-length* take (Voice Memos crops to the selection; we deliberately allow longer/shorter — the transcript re-syncs via retranscription anyway).
- Enhanced copy is a separate file, never overwrites the original; A/B toggle is instant (both loaded lazily).
- No new audio-format support in this milestone; replace/enhance output follows the M5 trim codec table.
- App stays LSUIElement-free: it remains a regular Dock app; the menu-bar extra is additive.

## Definition of done
- All requirements implemented; unit tests for: splice-plan math (replace ranges, variable-length insert offsets), recovery-file finalization logic, enhanced-copy file lifecycle (delete-audio covers both, trash/restore round-trip), notification decision logic (frontmost suppression). `xcodebuild test` passes, no regressions.
- Recording start from global hotkey < 500 ms from keypress to first captured sample.

## Verification checklist (human-run)

**Interactive, one item at a time, human confirms each** (same protocol). *Preparation: a quiet room and a deliberately noisy recording (fan/music in background); grant notification permission when prompted.*

- [ ] Enable the menu-bar extra; record a 10-second memo from the popover with the main window closed: it lands in the configured folder, transcribes, and the menu-bar icon visibly animated while recording.
- [ ] Press the global hotkey while in another app (e.g. Safari fullscreen): recording starts without focus change, hotkey again stops it, the entry appears in the vault; rebind the hotkey in Settings and confirm the new one works.
- [ ] Start recording in the main window, then open the menu-bar popover: it shows the *same* session (elapsed time matches); stopping from the popover stops the one recording.
- [ ] Replace: select a middle phrase on a waveform, Replace, speak a different phrase after the pre-roll — playback is seamless across both splice points, the transcript re-lands matching the new audio, and the pre-replace audio restores correctly from Recently Deleted.
- [ ] Replace with a *longer* take than the selection: total duration grows accordingly; transcript matches.
- [ ] Enhance the noisy recording: A/B toggle audibly reduces noise, waveform switches to the enhanced peaks, frontmatter records the state, and the original file is untouched on disk (byte-identical).
- [ ] Delete Audio on an enhanced entry: both audio files leave the folder; restore brings both back with the toggle state intact.
- [ ] The level meter moves before recording starts (arming) in main bar, Zen, and menu-bar popover; switching input devices switches the meter's source; CPU is ~0% when no recorder UI is visible (check Activity Monitor).
- [ ] Background a transcription of a 10+ minute file and switch to another app: a notification arrives on completion; clicking it opens that entry. Dock icon showed progress while queued.
- [ ] Force-quit (kill -9) mid-recording; relaunch: the recording exists, plays to within ~2 s of the kill, is queued/transcribed, and shows the recovered annotation.
- [ ] Waveform hover shows timestamp + preview playhead on entries of various durations; click-to-seek unchanged.
- [ ] Regression: trim (M5) still works after the splice refactor; Skip Silence and karaoke sync still correct on a replaced-then-retranscribed entry.
- [ ] Regression: live transcription in Zen still streams; recording quality setting (compressed/lossless) still respected including via menu-bar capture.
- [ ] All new commands are in the palette/menu bar; Keyboard Shortcuts window lists the global hotkey.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-9-start-here.md`**: state summary; build/run/test; updated file map; **the contracts Milestone 9 consumes** — the full inventory of animatable surfaces (record button, waveform views, tab bar, palette, panels) and where their view code lives; the notification/permission touchpoints (mic, notifications, hotkey) that the onboarding tour must cover; Settings pane inventory; where version/build numbers and the About window live; deviations; known issues. Append deviations to `PROJECT-STATE.md`. Close with the fresh-model assumption line.
