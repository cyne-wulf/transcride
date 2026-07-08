# Transcride — Product Requirements Document

Version 0.1 (draft) · 2026-07-08 · Derived from [vision.md](vision.md)

## 1. Overview

Transcride (transcribe + IDE) is a native macOS app that is both a **zen capture space** for audio journaling and a **workbench for transcriptions** — a place to record or import audio, transcribe it locally, replay it in sync with the text, refine the transcript into a note, and export cultivated knowledge to a proper knowledge system (e.g. Obsidian).

**Thesis: the audio is the draft, the transcript is the artifact.** The app treats a recording as raw material that becomes a permanent, searchable, editable text note — and lets the user discard the heavy audio once the text has captured everything.

Transcride is a **superset of macOS Voice Memos**: every Voice Memos feature has an equivalent here, plus the transcription workbench on top.

## 2. Goals and non-goals

### Goals
1. Zero-friction capture: app-open to recording in one action.
2. Fully local, private transcription pipeline with the user's choice of model.
3. Tight audio↔text sync in both directions (word highlight during playback; click a word to seek).
4. Safe, layered editing: the original transcription is immutable; edits live in a separate layer.
5. Everything is a file the user can see: a vault of plain files and folders, no lock-in.
6. Full-text search across the whole vault, with jump-to-moment.
7. Complete Voice Memos feature parity.

### Non-goals (v1)
- Cloud transcription APIs (Deepgram, AssemblyAI, OpenAI). Deferred; the engine layer must not preclude them.
- AI summarization, chapters, action items, auto-tagging.
- iOS app / companion capture device.
- Real-time live transcription while recording (capture first, transcribe after; live is a later enhancement).
- Multi-user / collaboration features.
- A plugin system (Obsidian-style extensibility is a long-term idea, not v1).

## 3. Target user and jobs-to-be-done

Primary persona: a technologically literate knowledge worker who journals or thinks out loud, already uses (or aspires to use) a text-based knowledge system, and cares about owning their data as plain files.

| Job | What it demands |
|---|---|
| "I have a thought now" | One-click record, no naming/filing upfront, zen UI |
| "Make everything I said searchable" | Automatic local transcription, reliable queue |
| "Let me re-experience it" | Synced playback, waveform scrubbing, speed/skip-silence |
| "Let me refine it into my words" | Layered editing, markdown, original always recoverable |
| "Find that thing I said weeks ago" | Vault-wide full-text search, jump to text position and audio moment |
| "Graduate the knowledge" | Copy/export as markdown; vault readable by Obsidian directly |
| "Don't trap my data" | Files on disk are the truth; app is a lens, not a silo |

## 4. Product principles

1. **Files are the source of truth.** The app renders the file system; it never hides data in an opaque database. Anything a database does (search index) is a rebuildable cache.
2. **The original transcription is immutable.** Edits, corrections, and enhancements are layers on top.
3. **Local-first and private.** No audio or text leaves the machine in v1.
4. **Voice Memos is the UX floor, Obsidian fills the gaps.** When in doubt, do what Voice Memos does; where it has no analog, do what Obsidian does.
5. **Destructive actions are staged, not immediate.** Warnings before, Recently Deleted after.

## 5. Functional requirements

Priorities: **P0** = v1 cannot ship without it · **P1** = v1 target, can slip to v1.1 · **P2** = post-v1.
IDs are stable and should be referenced in issues/commits.

### 5.1 Vault and file system (VLT)

- **VLT-1 (P0)** First-run flow prompts the user to create or select a **transcride vault** (a root folder), exactly like Obsidian. The app supports switching vaults.
- **VLT-2 (P0)** Any subfolder inside the vault is rendered as a folder in the UI. Folders created in the UI appear on disk; folders/entries created or moved on disk appear in the UI (file-system watching with graceful refresh).
- **VLT-3 (P0)** Each entry (note/transcription pair) is a folder named `transcride-<timestamp>` (format: `transcride-2026-07-08T14-32-05`). Moving an entry between folders in the UI moves the folder on disk.
- **VLT-4 (P0)** "Reveal in Finder" is available on every entry.
- **VLT-5 (P0)** Entry folder contents follow the naming scheme in §6. All names must be self-describing to a technologically literate person browsing in Finder.
- **VLT-6 (P1)** The vault remains valid if edited externally (files renamed/added/removed while the app runs); the app must never corrupt or overwrite external changes silently.

### 5.2 Recording / capture (REC)

- **REC-1 (P0)** One-click record from anywhere in the app; recording starts immediately.
- **REC-2 (P0)** Pause and resume mid-recording; live scrolling waveform and elapsed time while recording.
- **REC-3 (P0)** Microphone input selection (system default plus any available input device).
- **REC-4 (P0)** On stop: entry folder is created, audio is saved, and transcription is queued automatically.
- **REC-5 (P1)** **Zen mode**: a deliberately minimal full-window recording view — waveform, elapsed time, pause/stop, nothing else. This is the audio-journal face of the app.
- **REC-6 (P1)** Recording quality setting: compressed (default: AAC, mono, speech-appropriate bitrate) vs lossless (ALAC).
- **REC-7 (P2)** Global hotkey / menu bar quick capture.

### 5.3 Import and transcription pipeline (TRN)

- **TRN-1 (P0)** Import audio via drag-and-drop onto the app and via file picker; batch import supported. Common formats: m4a/aac, mp3, wav, flac, ogg/opus, aiff, and audio tracks of common video containers (mp4, mov).
- **TRN-2 (P0)** Importing copies the file into a new entry folder (originals are never modified in place) and queues transcription.
- **TRN-3 (P0)** A visible **transcription queue** with per-item progress; the app remains fully usable while transcribing. Failures are surfaced with a retry action.
- **TRN-4 (P0)** Transcription produces the original transcript layer with **word-level timestamps** (§6). Word timings power highlight-sync, click-to-seek, search jump-to-moment, and Skip Silence.
- **TRN-5 (P0)** **Retranscribe**: re-run transcription on any entry with a chosen model and options; produces a new original layer (prior original is preserved — see EDT-4).
- **TRN-6 (P1)** **Speaker detection (diarization)** as a retranscribe/transcribe option: speaker-labeled segments, with the ability to rename speakers ("Speaker 1" → "Alice") in the edited layer.
- **TRN-7 (P1)** Auto-title each entry from the first meaningful line of its transcript (user-editable, see LIB-2).

### 5.4 Transcription engines (ENG)

- **ENG-1 (P0)** Engine/model dropdown selector. v1 ships **local engines only**, spanning three runtimes:

  | # | Model | Runtime | Why it's in the list |
  |---|---|---|---|
  | 1 | **Parakeet TDT v3 (0.6b)** — *default* | FluidAudio (CoreML/ANE) | ~200× realtime on Apple Silicon, best speed/accuracy balance, 25 languages, no hallucination on silence |
  | 2 | **Apple SpeechTranscriber** | Speech framework (macOS 26+) | Zero download, built-in, fast long-form model |
  | 3 | **Whisper large-v3-turbo** | WhisperKit (CoreML/ANE) | 99 languages, strongest multilingual accuracy |
  | 4 | **Whisper small** | WhisperKit | Low-memory/fast option for older machines |
  | 5 | **Qwen3-ASR** | FluidAudio | Strong recent open model, broader language coverage in the FluidAudio stack |

- **ENG-2 (P0)** Models are downloaded on demand with size shown before download, progress during, and delete-model to reclaim space. The default model download is offered during first-run.
- **ENG-3 (P0)** Engine abstraction layer: a single internal `TranscriptionEngine` protocol (transcribe file → words + timestamps + optional speakers; capability flags for vocabulary biasing, diarization, language list). Cloud engines (P2) plug in behind the same protocol.
- **ENG-4 (P1)** Per-entry record of which engine/model/options produced each transcript layer (stored in entry metadata).
- **ENG-5 (P2)** Cloud engines (Deepgram, AssemblyAI, OpenAI) with API-key management.

### 5.5 Custom vocabulary (VOC)

- **VOC-1 (P0)** A vault-level **custom vocabulary list** (names, jargon, product terms) the user can edit in settings. Stored as a plain file in the vault (§6) so it syncs/versions with the vault.
- **VOC-2 (P0)** At transcription time the vocabulary is passed to the engine via its native biasing mechanism where one exists (e.g. Whisper prompt-based biasing). Engine support is a capability flag (ENG-3).
- **VOC-3 (P0)** **Correction backstop:** for engines without native biasing (research indicates Parakeet via FluidAudio and Apple's new SpeechTranscriber currently lack it), a post-transcription pass fuzzy-matches transcript words against the vocabulary and applies corrections. Corrections are applied to the original layer but **marked as corrections** (the raw engine output remains recoverable), preserving the immutability principle.
- **VOC-4 (P1)** Adding a vocabulary word offers to re-apply the correction pass across existing transcripts (with preview of affected entries).

### 5.6 Playback and sync (PLY)

- **PLY-1 (P0)** During playback the current word is highlighted in the transcript and the viewport auto-scrolls to keep it visible. Auto-scroll pauses when the user scrolls manually and offers a "resume following" affordance.
- **PLY-2 (P0)** Clicking any word seeks the audio to that word's timestamp.
- **PLY-3 (P0)** Waveform is a first-class playback surface: rendered for every entry with audio, draggable to scrub/seek; scrubbing scrolls the text in sync.
- **PLY-4 (P0)** Transport controls: play/pause, skip back/forward 15 s, playback speed 0.5×–2×.
- **PLY-5 (P1)** **Skip Silence** toggle: playback jumps over silent gaps (derived from word timings/VAD).

### 5.7 Transcript editing and layers (EDT)

- **EDT-1 (P0)** The transcript is editable in place as a markdown note (headings, lists, emphasis — Obsidian-flavored basics).
- **EDT-2 (P0)** Two layers per entry: the **immutable original** and the **edited copy**. A toggle badge next to the "Copy as Markdown" button (top right) switches the view between them. Original view is read-only.
- **EDT-3 (P0)** First edit forks the edited layer from the original; subsequent edits autosave to the edited markdown file.
- **EDT-4 (P1)** Retranscription with an existing edited layer: the new original replaces the active original (prior originals archived in the entry folder); the edited layer is kept untouched and the user is notified it may now diverge.
- **EDT-5 (P2)** Diff view between original and edited layers.

### 5.8 Audio lifecycle (AUD)

- **AUD-1 (P0)** **Delete audio, keep transcript**: a button on the entry deletes the audio file to reclaim space. Warning dialog first (with file size shown); afterwards, audio-dependent actions (play, retranscribe, waveform, trim) are greyed out and the entry becomes a plain note.
- **AUD-2 (P0)** **Recently Deleted**: deleted entries and deleted audio go to a `.trash/` area in the vault, held 30 days, then purged. Restore is one click. Permanent-delete-now is available with confirmation.
- **AUD-3 (P1)** Audio editing: **trim/crop** to a selected range of the waveform. Because edits invalidate word timestamps, a trim triggers retranscription of the file (v1: whole file; region-splice is an optimization).
- **AUD-4 (P2)** **Replace**: re-record over a section (Voice Memos parity; same retranscription rule).
- **AUD-5 (P2)** **Enhance Recording**: noise/reverb reduction applied as a non-destructive processed copy.
- **AUD-6 (P1)** Vault storage overview in settings: total audio size, largest entries, one-click "review entries to strip audio from."

### 5.9 Search (SRCH)

- **SRCH-1 (P0)** Full-text search across all transcripts in the vault (both layers; edited layer results ranked first).
- **SRCH-2 (P0)** A prominent **fuzzy toggle** on the search bar. **Exact text match is the default**; fuzzy matching is opt-in per the switch (state persists).
- **SRCH-3 (P0)** Selecting a result opens the entry, scrolls to and highlights the matched position, and — when audio exists — cues the audio to that moment (via word timestamps).
- **SRCH-4 (P0)** The search index is a rebuildable cache (SQLite FTS or equivalent) stored in app support or a dot-folder; deleting it must never lose data, and it rebuilds automatically from vault files.
- **SRCH-5 (P1)** Filters: by folder, date range, has-audio vs note-only, favorites.

### 5.10 Library and organization (LIB)

- **LIB-1 (P0)** Sidebar library, Voice Memos style: entries listed with title, date, duration, and a text snippet; grouped or sorted by date. Folder tree above/beside it, Obsidian style (VLT-2).
- **LIB-2 (P0)** Inline rename of entries. Title lives in entry metadata; §6 covers whether the folder name also carries a slug.
- **LIB-3 (P1)** Favorites (flag + smart filter) and duplicate entry.
- **LIB-4 (P1)** Sort options: date, duration, title, recently edited.
- **LIB-5 (P2)** Tags (Obsidian-style `#tag` parsed from the edited layer).

### 5.11 Export and interop (EXP)

- **EXP-1 (P0)** **Copy as Markdown** button (top right of the note view) copies the currently viewed layer.
- **EXP-2 (P1)** Export entry to a chosen folder (e.g. an Obsidian vault) as a clean `.md`; optionally include timestamps or speaker labels.
- **EXP-3 (P1)** Share/export the audio file itself (share sheet — Voice Memos parity).
- **EXP-4 (P2)** Bulk export of a folder or the whole vault.

### 5.12 Settings (SET)

- **SET-1 (P0)** Vault location (change/switch), default transcription model, microphone, recording quality, custom vocabulary editor.
- **SET-2 (P1)** Model management screen (ENG-2), storage overview (AUD-6), Recently Deleted retention.

## 6. Architecture

### 6.1 Vault layout

```
MyVault/                              ← user-chosen root ("transcride vault")
├── Journal/                          ← any subfolder = a folder in the UI
│   └── transcride-2026-07-08T14-32-05/
│       ├── audio.m4a                 ← the recording/import (original format kept)
│       ├── transcript.original.json  ← immutable engine output: words, timestamps,
│       │                                speakers, engine/model info, corrections log
│       ├── transcript.md             ← the editable layer (Obsidian-readable), with
│       │                                YAML frontmatter for metadata
│       └── waveform.json             ← cached waveform peaks (rebuildable)
├── transcride-2026-07-01T09-15-40/   ← entries can live at the root too
├── vocabulary.txt                    ← custom vocabulary, one term per line
└── .trash/                           ← Recently Deleted (30-day purge)
```

- Files on disk are the truth. The search index and waveform cache are rebuildable and disposable.
- `transcript.md` frontmatter carries: title, created date, duration, favorite, audio-deleted flag, source (recorded/imported), engine+model used. Obsidian renders frontmatter natively, so the vault double-opens in Obsidian cleanly.
- `transcript.original.json` schema (to finalize in design): array of segments → words with `{ text, start, end, speaker?, corrected_from? }` plus engine metadata. Prior originals from retranscription are archived alongside (`transcript.original.2026-07-08.json`).
- When audio is deleted (AUD-1), `audio.m4a` moves to `.trash/`; the entry folder and both transcript layers remain.

**Open sub-decision (VLT/LIB):** whether renaming an entry appends a slug to the folder name (`transcride-<timestamp>-<slug>`, more browsable in Finder) or the title lives only in frontmatter (renames stay trivial). Recommendation: slug in folder name, since Finder-browsability is the point of the scheme; the timestamp prefix keeps identity stable.

### 6.2 App architecture notes

- Swift + SwiftUI, native macOS app.
- `TranscriptionEngine` protocol isolates FluidAudio, WhisperKit, and the Speech framework behind one interface with capability flags (diarization, vocabulary biasing, languages).
- File-system watcher (FSEvents) keeps the UI consistent with external vault edits.
- AVFoundation for capture/playback; word-highlight sync driven by playback time against the word-timing array.

## 7. UX requirements

- **Starting point is macOS Voice Memos**: two/three-pane layout — folder/library sidebar, entry list, detail view with waveform on top and transcript below. Record button always visible.
- **Obsidian patterns fill the gaps**: folder tree, markdown editing, frontmatter metadata, vault switcher, `.trash`.
- Detail view (entry with audio): waveform + transport at top; transcript below with karaoke highlight; top-right actions: layer toggle badge (original/edited), Copy as Markdown, overflow menu (retranscribe, delete audio, reveal in Finder, export).
- Detail view (audio deleted): identical note view minus waveform/transport; audio actions greyed out with an explanatory tooltip.
- Zen recording mode (REC-5): full-window, chrome-free.
- Keyboard-first where sensible: space = play/pause, ⌘N = new recording, ⌘F = search in note, ⌘⇧F = vault search.

## 8. Technical requirements

- **Platform:** macOS 15 (Sequoia) minimum; the Apple SpeechTranscriber engine is gated to macOS 26+ and hidden below that. Apple Silicon required for the neural engines (Intel unsupported in v1).
- **Performance targets:** app cold-launch < 2 s with a 1,000-entry vault; transcription ≥ 10× realtime with the default model on M-series; word-highlight sync drift < 100 ms; search results < 200 ms on a 1,000-entry vault.
- **Privacy:** no network calls in v1 except model downloads (Hugging Face/Apple CDN); microphone permission requested on first record with clear rationale.
- **Reliability:** transcription queue survives app restart; a crash mid-transcription never corrupts an entry folder (write-temp-then-rename for all file writes).

## 9. Phasing

| Phase | Contents |
|---|---|
| **v1.0** | All P0s: vault + entry file scheme, record + import, queue, Parakeet/WhisperKit/Apple engines, custom vocabulary (native + backstop), synced playback + waveform + click-to-seek, layered editing + toggle + copy-as-markdown, delete-audio-keep-note, Recently Deleted, exact/fuzzy search, library + rename, settings |
| **v1.1** | P1s: zen mode, diarization + speaker rename, Skip Silence, trim, favorites/duplicate, export to folder, storage overview, vocabulary re-apply, search filters, auto-title (if not in 1.0) |
| **v2+** | P2s: cloud engines, replace re-record, Enhance Recording, tags, diff view, bulk export, global hotkey capture, live transcription, sync (vault-in-iCloud-Drive first), AI features |

## 10. Open questions

1. **Folder-name slugs on rename** — recommendation made in §6.1, needs sign-off.
2. **Apple Silicon-only** — confirm dropping Intel is acceptable (the model runtimes effectively require it).
3. **Final model list #4/#5** — Whisper small and Qwen3-ASR are placeholders pending a benchmarking pass during development; the dropdown ships whatever the engine-layer research validates.
4. **Diarization engine** — FluidAudio's diarization stack (Pyannote/Sortformer) is the candidate; validate quality before committing TRN-6 to v1.1.
5. **Corrections and the immutability principle** — VOC-3 marks corrections inside the original layer; confirm this satisfies "original is immutable" or whether corrections should be a third layer.

## 11. Success criteria for v1

- A user can: open the app → record a thought → watch it become a searchable transcript → clean it up in markdown → delete the audio → find it again by search a month later → copy it into Obsidian — all without the app ever touching the network (past model download) and with every artifact visible as a sensible file in Finder.
- The vault opens in Obsidian and every note renders correctly.
- Deleting the app leaves a complete, human-readable vault behind.
