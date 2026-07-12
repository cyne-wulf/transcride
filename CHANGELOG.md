# Changelog

## Unreleased

## 1.2.0 — 2026-07-12

### Highlights

- Replace an exact selected audio region from the entry's three-dot menu or by
  pressing `R`, using the same precise range selector as Trim.
- Record and retain multiple complete or incomplete replacement takes, audition
  each take alone or in context, and bake only an exact-duration complete take.
- Keep the recording's total duration and later timeline positions stable across
  repeated and overlapping replacements with retained source material and a
  non-destructive edit recipe.
- Validate replacement renders before a safe swap, retain pre-replacement audio
  in Recently Deleted, recover interrupted sessions, and never auto-bake an
  uncertain take after relaunch.
- Fully retranscribe each baked replacement while keeping hand-edited Markdown
  byte-identical and preserving one ordinary canonical audio file for other apps.
- Add contextual 1–60 second playback skips based on clip duration, visible vault
  search and in-note Find controls, and improved search-window sizing.
- Add a Loop Audio toggle to an entry's three-dot menu; looping preserves the
  selected playback speed and works with Skip Silence.
- Add a per-entry **Silence Detection** picker shared by Skip Silence and Compress
  Audio. **Waveform (Audio Level)** uses the real -40 dBFS signal threshold;
  **Speech Transcript** uses leading, internal, and trailing gaps in the timed
  Original, which remains useful when steady room noise never becomes quiet.
- Apply the same strict longer-than-1.5-second rule and 0.1-second boundary padding
  in both modes. Speech mode never falls back silently: missing, stale, malformed,
  or regenerating timing suspends Skip Silence and blocks compression.
- Add **Compress Audio…** to remove silence runs longer than 1.5 seconds while
  retaining short boundary padding, preserving the complete prior file in Recently
  Deleted, and fully retranscribing without overwriting hand-edited Markdown.
- Validate the rendered M4A before swapping it in and leave the audio unchanged when
  no qualifying silence exists or the result would not reduce storage use.
- Persist `silence_detection: waveform|speech` per entry while preserving unknown
  frontmatter and keep that preference through rename, move, duplicate, compression,
  and audio-version restore.

All 17 Milestone 7 verification checks passed, including repeated overlapping
replacement bakes, crash/failure recovery, accessibility, regressions, and the
complete automated suite. The release tree passes 315 tests across 47 suites.

## 1.1.0 — 2026-07-11

### Highlights

- Extend an existing recording from the far-left control in its playback pill, or
  press `E`; press `E` again to finish the extension.
- Pause and resume an extension, see its live waveform and added duration, then
  receive one continuous, ordinary audio file with a refreshed waveform.
- Fully retranscribe combined audio while preserving hand-edited Markdown and
  clearly marking the old timed transcript until its replacement arrives.
- Recover interrupted extension segments by finishing the append, saving the
  segment as a new entry, or discarding it.
- Restore pre-extension audio from Recently Deleted through the same safe version
  swap used by trim recovery.
- Make ordinary recording capture genuinely crash-tolerant with a fixed-width PCM
  journal that remains readable after abrupt process termination.
- Add protective quit/window-close handling and deterministic Debug failure seams
  for composition, safe-swap, and post-swap recovery testing.

All 14 Milestone 6 verification checks passed, including the complete regression
checklist and automated suite of 254 tests across 41 suites.

## 1.0.0 — 2026-07-11

First complete release of Transcride.

### Highlights

- Plain-file vaults with folders, rename/move, Recently Deleted, and recovery.
- Native recording, import, waveform playback, speed control, Skip Silence, and trim.
- Local Parakeet, WhisperKit, and Apple Speech transcription with a persistent queue.
- Live transcription in Zen mode and an optional main-window ticker.
- Timed original transcripts, editable Markdown layers, speaker detection/rename,
  click-to-seek, karaoke follow, in-note find, and Copy as Markdown.
- Indexed exact/fuzzy vault search with folder, date, audio, and favorite filters.
- Favorites, duplication, sorting, vocabulary correction/re-apply, Markdown export,
  audio sharing, Obsidian interoperability, and storage management.
- Complete menu bar, keyboard reference, designed empty states, app icon, About
  window, recent-vault switcher, and both Command-Delete and Shift-Delete entry removal.

All 17 Milestone 5 verification checks passed, followed by the complete automated
test suite (234 tests in 37 suites).
