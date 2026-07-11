# Changelog

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
