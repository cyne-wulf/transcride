# PRD-3 — Milestone 3: Transcription Engines & Pipeline

> **Before starting:** read `PRD-3-start-here.md` (written at the end of Milestone 2). Full product context: [master-prd-backup.md](master-prd-backup.md) §5.3, §5.4, §5.5, §6.1. Do not start until the human confirms Milestone 2's checklist is verified.

## Goal

Every recording and import now becomes text automatically, locally. This milestone builds the engine abstraction, ships three local runtimes (FluidAudio/Parakeet as default, WhisperKit, Apple SpeechTranscriber), the model download manager, the transcription queue, the custom vocabulary system, and the on-disk transcript formats that Milestones 4–5 consume. **The transcript data contract created here is the most important interface in the app — get `transcript.original.json` right.**

## Scope

**In:** engine protocol, three engines, model management UI, transcription queue, `transcript.original.json` + generated `transcript.md`, retranscribe, custom vocabulary (native biasing + correction backstop), auto-titling.

**Out:** word-highlight playback sync and click-to-seek (M4), editing (M4), search (M4), diarization (M5 — but the data schema and engine capability flag are defined now).

### Addendum (added during M3 verification): live transcription mode

User-approved scope addition, shipped with M3. **Live display + batch final:** while recording, words appear on screen as they are spoken (FluidAudio Parakeet EOU 120M streaming model, 160 ms chunks, lazily downloaded ~450 MB into the FluidAudio cache); when the recording stops, the normal seam → queue → batch pipeline still produces the authoritative `transcript.original.json` — the live text is display-only and never written to the vault. Live transcription is the **default in Zen mode** (no selector there) and an **opt-in toggle in the main window's recorder bar** (`liveTranscriptionEnabled`). It requires the Parakeet default model to be downloaded (otherwise a hint shows and recording proceeds without it), and any live-path failure degrades to a status note — it can never affect the recording itself.

## Requirements

### Engine abstraction (ENG-3, ENG-4)
- A `TranscriptionEngine` protocol: input = audio file URL + options (language hint, vocabulary list); output = segments → words with start/end times; plus static capability flags: `supportsVocabularyBiasing`, `supportsDiarization`, `languages`, `modelDownloadSize`.
- Every produced transcript records engine id, model id, options, and app version in its metadata (ENG-4).

### Engines (ENG-1, ENG-2)
1. **Parakeet TDT v3 (0.6b) via FluidAudio — the default.** ~200× realtime on Apple Silicon; 25 languages.
2. **Apple SpeechTranscriber (Speech framework)** — macOS 26+ only; hide the option below that. Zero download.
3. **WhisperKit** — ship `large-v3-turbo` and `small` as two dropdown entries sharing one runtime.
- Model dropdown in settings and in the retranscribe dialog, showing per-model: languages, download size, downloaded/not.
- Model manager (ENG-2): download on demand with progress, cancel, delete-to-reclaim-space. First-run offers the default model download. Verify checksums/completeness before marking a model usable; a failed download never leaves a "downloaded" model that crashes at load.
- Research note baked in: evaluate Qwen3-ASR via FluidAudio as a 5th dropdown entry; include it if quality is acceptable, otherwise document why not in the handoff.

### Transcript data contract (TRN-4 — the critical deliverable)
- `transcript.original.json`, written atomically, schema versioned (`"schema": 1`):
  - engine metadata block (engine, model, options, created, app version)
  - `segments[]`: `{ start, end, speaker? }` each containing `words[]`: `{ text, start, end, corrected_from? }`
  - `speaker` is nullable and unused until M5 diarization — but present in the schema now.
- After transcription, `transcript.md` is (re)generated: frontmatter preserved/updated (`duration`, `engine`, title — see auto-title) and body = plain transcript text, paragraph-broken on long pauses. **If the user has hand-edited `transcript.md` (M4+), never overwrite it — see Retranscribe.**
- Prior originals are archived on retranscribe: `transcript.original.<date>.json`.

### Pipeline (TRN-2, TRN-3, TRN-5, TRN-7)
- Recording-finished and import-finished hooks (the M2 seam) enqueue transcription automatically with the default model.
- **Queue (TRN-3):** visible queue UI (toolbar popover or sidebar section) with per-item progress and state (waiting/running/done/failed+retry). Serial or bounded-concurrent execution; app fully usable throughout; queue persists across relaunch (unfinished items resume).
- **Retranscribe (TRN-5):** button on any entry with audio; dialog offers model picker and (greyed-out until M5) speaker-detection toggle. Archives the prior original, writes the new one. If `transcript.md` was never hand-edited, regenerate it; otherwise leave it and inform the user the original changed underneath their edit.
- **Auto-title (TRN-7):** entries titled "New Recording" get their title replaced by the first meaningful transcript line (≤ ~8 words, cleaned); folder slug updates per M1 rules. User-set titles are never overwritten.

### Custom vocabulary (VOC-1, VOC-2, VOC-3)
- `<vault>/vocabulary.txt`, one term per line; editable in settings (add/remove/edit with immediate persistence).
- Engines with native biasing get the list at transcription time (Whisper: prompt-based biasing; flag per ENG-3 capabilities).
- **Correction backstop for all engines:** post-transcription pass fuzzy-matches transcript words/phrases against vocabulary terms (phonetic/edit-distance; conservative threshold — false corrections are worse than misses). Corrections rewrite the word `text` and set `corrected_from` in the JSON, preserving the raw engine output in place.

## Decisions already made
- Local-only in v1. Cloud engines are P2; the protocol must accommodate them (async, cancellable, error taxonomy) but build none.
- Apple Silicon only; SpeechTranscriber gated to macOS 26+ at runtime.
- Correction markers live inside the original JSON via `corrected_from` (not a third file).

## Definition of done
- All requirements implemented; unit tests for: JSON schema round-trip, correction backstop (fixture vocabulary vs fixture transcript with known misses — asserts corrections applied AND near-miss words left alone), auto-title extraction, queue persistence across restart. `xcodebuild test` passes.
- Transcription throughput ≥ 10× realtime with Parakeet on the dev machine.

## Verification checklist (human-run — all boxes required before Milestone 4)

**Verification is interactive.** When implementation is complete, run this checklist as a step-by-step quiz: present one item at a time, give the human the exact steps and materials needed, wait for their pass/fail answer, and keep a running tally. On a fail: fix it, then re-verify that item plus any already-passed items the fix could have affected. Write the handoff document only after the human confirms every item.

Prepare: a clear 1–2 min recording of yourself; a long file (≥ 30 min, e.g. a podcast episode); a short file in a non-English language WhisperKit covers; 2–3 unusual words for the vocabulary (product names, your name).

- [ ] First run after update offers the Parakeet download; progress shows; cancel works; re-download completes.
- [ ] Record a 1-min memo: transcription starts automatically, queue shows progress, transcript text appears in the detail view when done.
- [ ] Transcript accuracy is sane on the clear recording, and the entry auto-titles from your first sentence (folder slug updated).
- [ ] `transcript.original.json` exists, is human-readable, contains word-level start/end times and the engine metadata block.
- [ ] Import the 30-min file: transcribes ≥ 10× realtime; app fully usable meanwhile; queue survives quitting and relaunching mid-job (resumes or restarts the item).
- [ ] Batch-import 3 files: queue processes all; one failure (feed it a silent/corrupt file) shows failed + retry without blocking the others.
- [ ] Retranscribe with WhisperKit `small`: prior original archived (`transcript.original.<date>.json` in Finder), new transcript rendered, entry metadata shows the new model.
- [ ] Non-English file via WhisperKit large-v3-turbo produces correct-language output; Parakeet is marked/behaves per its language list.
- [ ] On macOS 26: Apple SpeechTranscriber appears and transcribes with no download. On macOS 15: the option is hidden.
- [ ] Add your unusual words to the vocabulary; record a memo using them; they come out correctly (via biasing or backstop), and `corrected_from` fields appear in the JSON where the backstop fired.
- [ ] Confirm the backstop is conservative: normal words near your vocabulary terms are not falsely "corrected."
- [ ] Delete a downloaded model in the manager; disk space returns; selecting it re-prompts download.
- [ ] `xcodebuild test` passes.

## Handoff (required, after the checklist is verified)

Write **`PRD-4-start-here.md`**: updated file map and build/run/test; the final `transcript.original.json` schema with a real example; the engine protocol and how to query capabilities; how the queue works and its persistence format; the auto-title and slug-update flow; the vocabulary/correction pass design and thresholds; which model files live where on disk; the fifth-model (Qwen3-ASR) decision; known issues. M4 builds word-synced playback and editing directly on your JSON — spell out exactly how words map to audio time and to character positions in `transcript.md`.
