# PRD-4 Start Here — Milestone 3 handoff

> Assume you are a fresh model with zero context beyond PRD-4.md and this document.

## Project summary

Transcride is a native macOS (Swift 6 + SwiftUI, macOS 15+, Apple Silicon, App Sandbox) voice recorder + transcription workbench whose data layer is a plain-folder **vault**. M1 = vault foundation; M2 = Voice Memos core (recording, import, playback). Milestone 3 (verified 2026-07-09, tag `milestone-3`) made every recording and import become text automatically and locally: an engine protocol with three runtimes (Parakeet v3 via FluidAudio = default, WhisperKit large-v3-turbo + small, Apple SpeechTranscriber on macOS 26+), a model manager (download/progress/cancel/delete/Show-in-Finder), a persistent per-vault transcription queue, the `transcript.original.json` data contract, generated `transcript.md` with hand-edit protection, retranscribe with archiving, a custom-vocabulary system (native biasing + conservative correction backstop), auto-titling, and — added by user request during verification — **live transcription while recording** (display-only; the batch pipeline stays authoritative). Measured throughput: a 1-hour file in ~41 s (~88× realtime) with Parakeet on the dev machine.

**Read PRD-4.md's "Operating procedure — orchestrate to preserve context" before starting**: implementation is delegated to full-context forked subagents on the same top-tier model, run sequentially whenever they build; the orchestrator reviews reports, records state in memory, owns commits, and runs checklist verification with the human personally.

## Build / run / test

- `project.yml` (XcodeGen) defines the project; `Transcride.xcodeproj` is generated — **never edit it by hand**; run `xcodegen generate` after adding/removing files.
- SPM packages (app target only, NOT the test target): FluidAudio 0.15.5, WhisperKit 1.0.0. Sandbox has `com.apple.security.network.client` for model downloads.
- Build/test: `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build` / `… test` (**110 tests, 19 suites**; the test target compiles `Transcride/Core` directly with no app host and no packages — Core must never import FluidAudio/WhisperKit/AppKit/SwiftUI).
- Run: after every build, deploy and launch from /Applications (user preference):
  `ditto ~/Library/Developer/Xcode/DerivedData/Transcride-*/Build/Products/Debug/Transcride.app /Applications/Transcride.app && pkill -x Transcride; open /Applications/Transcride.app`
- Fixtures: `Scripts/make-fixture-vault.sh` → `TestVault-500/` (the user's live test vault — it contains real transcribed entries you can inspect); import samples in `TestVault-materials/import-samples/`.
- `~/Library/Containers/<bundle>/Data/Library/Application Support/transcride-debug.log` (`DebugLog`) records every transcription with segment/correction counts — first stop when debugging.

## File map (M3 additions; see PRD-3-start-here.md for the M1/M2 files, all still accurate)

**Transcride/Core** (pure, unit-tested):
- `TranscriptOriginal.swift` — the schema-1 data contract (below): Codable model, atomic pretty/sorted write, `load`, `archiveExisting(inEntry:date:)` → `transcript.original.<yyyy-MM-dd-HHmmss>.json` (collision counter), `allWords`, `text(of:)`.
- `TranscriptMarkdown.swift` — `body(from:)` generation, `isGeneratedBody`, `isStubBody` (see word↔character mapping below).
- `AutoTitle.swift` — title extraction (see auto-title flow).
- `Vocabulary.swift` — `VocabularyFile` (vault/vocabulary.txt IO) + `VocabularyCorrector` (the backstop; thresholds below).
- `TranscriptionEngineTypes.swift` — `TranscriptionOptions`, `TranscriptionModelInfo` (capability flags), `ModelDownloadProgress` (.downloading(Double)/.preparing), `TranscriptionError` taxonomy, `SegmentBuilder` (words→segments: pause ≥1.2 s, sentence punctuation, 60-word cap; also `strippingSpecialTokens` — Whisper control-token scrubber).
- `TranscriptionQueueStore.swift` — queue persistence (below).
- `TranscriptionApplier.swift` — the post-transcription pipeline applied inside VaultService: backstop → archive prior original → write JSON → regenerate md unless hand-edited → auto-title. Returns `Outcome { entryRelativePath, appliedTitle, archivedOriginalName, markdownLeftAlone, correctionCount }`.
- `LiveTranscript.swift` — confirmed/volatile split for live streaming display (+ `tail()` for one-line tickers).

**Transcride/App/Transcription**:
- `TranscriptionEngine.swift` — the protocol + `ModelCatalog` + `EngineRegistry` (actor; caches one engine per model id for the app's lifetime).
- `ParakeetEngine.swift`, `WhisperKitEngine.swift`, `AppleSpeechEngine.swift` — the three runtimes (all actors).
- `TranscriptionQueue.swift` — the @MainActor queue service (below).
- `ModelManager.swift` — @Observable download-state machine for Settings (`ModelState`: checking/notDownloaded/downloading/preparing/downloaded/failed); `didOfferDefaultModelDownload` UserDefaults key gates the one-shot first-run offer.
- `LiveTranscriber.swift` — live streaming session owner (below).

**Transcride/App**: `AppModel` gained `transcriptionQueue` (per vault, recreated in openVault), `modelManager`, `liveTranscriber`, `transcriptRevision: Int` (bumped after each landed transcription; EntryDetailView keys its load `.task(id:)` on it), delete/rename hooks calling `queue.evictItems/repointItems`. `VaultService` gained `applyTranscription(...)` (wraps TranscriptionApplier on the actor), `audioFileName(atEntryPath:)`, `vocabularyTerms()`, `saveVocabularyTerms(_:)`. `TranscriptionSeam` is now a @MainActor enum forwarding `audioEntryReady` to `queue?.enqueue` — call sites unchanged. `RecorderService` gained `liveTee: LiveAudioTee` (lock-guarded optional buffer handler on the existing tap; a no-op when unset).

**Transcride/UI**: `TranscriptionQueueView.swift` (toolbar progress-ring button + popover), `TranscriptionSettings.swift` (Settings → Transcription: default-model picker, per-model rows, vocabulary editor), `RetranscribeSheet.swift`, `LiveTranscriptViews.swift` (Zen panel + main-window strip). `EntryDetailView` has the Retranscribe toolbar button and inline queue status ("Waiting to transcribe…"/"Preparing model…"/"Transcribing…" + progress/failure+Retry).

**TranscrideTests** new suites: TranscriptOriginalTests, TranscriptMarkdownTests (+AutoTitle+SegmentBuilder), VocabularyTests, TranscriptionQueueStoreTests, TranscriptionApplierTests, LiveTranscriptTests.

## The transcript data contract — `transcript.original.json`

Written atomically, pretty-printed, sorted keys. Real example (from `TestVault-500/transcride-2026-07-09T05-07-17-…/`, abbreviated):

```json
{
  "schema": 1,
  "engine": {
    "app_version": "0 (0)",
    "created": "2026-07-09T22:29:00Z",
    "engine": "parakeet",
    "model": "parakeet-tdt-0.6b-v3",
    "options": {}
  },
  "segments": [
    {
      "start": 0.88,
      "end": 13.6,
      "speaker": null,
      "words": [
        { "text": "This", "start": 0.88, "end": 1.2 },
        { "text": "is",   "start": 1.2,  "end": 1.36 },
        { "text": "a",    "start": 1.36, "end": 1.6 },
        { "text": "Airakeet,", "start": 6.32, "end": 7.2,
          "corrected_from": "Erikeet," },
        { "text": "Ashan Devine,", "start": 7.2, "end": 8.4,
          "corrected_from": "Oshan Divine," }
      ]
    }
  ]
}
```

Rules baked into the Codable model (`TranscriptOriginal.swift`):
- `speaker` is **always emitted** (as `null` until M5 diarization) via a custom `encode`; `corrected_from` appears only on corrected words.
- `engine.engine` = engine family id ("parakeet"/"whisperkit"/"apple-speech"), `engine.model` = concrete model id. **The frontmatter `engine:` key is different** — it holds the catalog id (e.g. `parakeet-tdt-v3`, `whisperkit-small`) so the UI can name the model.
- `options` = `TranscriptionOptions.metadataDictionary`: `language_hint` if set (currently always nil — auto-detect), `vocabulary_terms` = term count when native biasing was used.
- A backstop merge (multi-word correction like "Oshan Divine," → one word "Ashan Devine,") keeps the first word's `start` and the last word's `end`, so word→audio mapping stays valid. Note the merged `text` can contain a space.
- Retranscribe archives the prior file to `transcript.original.<date>.json` in the entry folder before writing the new one; archives are plain copies of this same schema.

## Words ↔ audio time ↔ `transcript.md` characters (the M4 foundation)

**Word → audio:** every word carries `start`/`end` in seconds from the start of the audio file. Click-to-seek = seek to `word.start`; the playhead word = the word whose `[start, end)` contains the current time (fall back to nearest-previous for inter-word gaps). Segments also carry start/end but are a presentation grouping (SegmentBuilder: pause ≥ 1.2 s, sentence-final punctuation, 60-word cap) — for sync, iterate `transcript.allWords`.

**Word → characters in `transcript.md`:** the generated body is a **pure deterministic function of the word list** (`TranscriptMarkdown.body(from:)`):
1. Iterate all words across all segments in order; each word's `text` is whitespace-trimmed (empty ones skipped).
2. A new paragraph starts when `word.start − previousWord.end ≥ 2.0` s (`paragraphPauseThreshold`).
3. Words within a paragraph are joined with single spaces; paragraphs are joined with `"\n\n"`.
4. The applier writes the body as `"\n" + body + "\n"` after the frontmatter block.

So M4 can compute an exact character-offset ↔ word-index mapping for a **never-hand-edited** file by replaying that walk: offset starts after the frontmatter's closing `---\n` plus the leading `"\n"`; each word occupies `text.count` characters followed by either one space (same paragraph) or `"\n\n"` (paragraph break decided by the ≥2.0 s rule). Verify per entry with `isGeneratedBody` (below) before trusting the mapping; for the **original layer** (rendered straight from JSON), M4 should render from the word list itself and keep word identity per rendered run — no character math needed.

**Hand-edit detection (`isGeneratedBody`)**: an existing body is "still machine-generated" iff its whitespace-normalized form (split on all whitespace, joined with single spaces) equals the normalized regeneration **from the previous original JSON**. The applier regenerates `transcript.md` only when the body is the empty stub or passes this test; otherwise it sets `markdownLeftAlone = true` and leaves the file byte-identical (the queue logs "md left alone (hand-edited)"). Implications for M4's layered editing:
- **There is no `hand_edited` frontmatter flag yet.** M3 detects edits by comparison only (zero state, conservative: unknown formats compare unequal → never overwritten). M4's EDT-3 fork-on-first-edit should add the flag (the `Frontmatter.swift` accessor pattern makes that trivial) or keep using the comparison; if you add the flag, keep the comparison as a backstop for files edited externally (Obsidian).
- The whitespace normalization means an edit that only reflows whitespace is NOT a fork — acceptable and intentional.
- After a retranscribe of a hand-edited entry, `transcript.original.json` reflects the new run while `transcript.md` still reflects the old text — the `markdownLeftAlone` outcome is the "original changed underneath your edit" signal PRD-4's EDT-4 must surface.

## Engine protocol & capabilities

`TranscriptionEngine` (protocol, Sendable): `info: TranscriptionModelInfo`, `isDownloaded()`, `downloadModel(progress: (ModelDownloadProgress) -> Void)`, `deleteModel()`, `downloadedByteSize()`, `modelDirectory()` (for Show-in-Finder; nil when system-managed), `transcribe(audioURL:options:progress:) -> [TranscriptOriginal.Segment]`. Cancellation = structured Task cancellation throughout; errors use the `TranscriptionError` taxonomy. The protocol is async/cancellable so P2 cloud engines slot in without change.

Capabilities live on `TranscriptionModelInfo`: `supportsVocabularyBiasing`, `supportsDiarization` (all false until M5), `languageCodes` (empty = many/auto), `downloadSizeBytes`. Query via `ModelCatalog.info(forID:)`/`ModelCatalog.available` (dropdown order; Apple Speech appended only under `#available(macOS 26, *)`). `ModelCatalog.preferredDefaultModelID()` reads the `defaultTranscriptionModel` UserDefaults key, falling back to Parakeet. `EngineRegistry.shared.engine(forModelInfoID:)` returns the cached engine instance.

Catalog (id / biasing):
- `parakeet-tdt-v3` (default) — biasing **false**: FluidAudio 0.15.5's CTC keyword-spotting/CustomVocabularyContext is wired only to its *streaming* managers, not batch `AsrManager` (verified in source). The backstop covers it.
- `whisperkit-large-v3-turbo` — biasing **false**, deliberately: the turbo variant's distilled decoder cannot handle `<|startofprev|>` prompt conditioning and emits an immediate `<|endoftext|>` (whole-file empty decode; reproduced deterministically against WhisperKit 1.0.0 with a headless harness). Backstop covers it. Re-test if WhisperKit or the model checkpoint updates.
- `whisperkit-small` — biasing **true** (prompt tokens; verified catching 100% of test vocabulary).
- `apple-speech` — macOS 26+ only, zero download (`isDownloaded()` always true; OS installs locale assets on first use).

Engine notes: Parakeet subscribes to `manager.transcriptionProgressStream` **before** starting (subscribing after can attach to a dead session); WhisperKit `downloadModel` pays the ~minutes-long first-load CoreML/ANE specialization + tokenizer fetch **at download time** (loads the pipe once before writing the `.transcride-download-complete` marker — so "downloaded" means "runnable"); Whisper fallback segment text (no word timings) is scrubbed with `SegmentBuilder.strippingSpecialTokens` and an effectively-empty decode throws `engineFailure` rather than writing garbage; AppleSpeechEngine splits multi-word attributed runs linearly over the run's `audioTimeRange` so the schema stays word-granular.

## The queue

`TranscriptionQueue` (@MainActor @Observable, one per open vault, owned by AppModel): serial worker Task; per item → resolve audio via `VaultService.audioFileName` → engine from registry (not-downloaded fails with a message pointing at Settings) → `engine.transcribe` with progress into `progressByItemID[itemID]` → `VaultService.applyTranscription` → remove item, `onEntryTranscribed(originalPath, outcome)` (AppModel bumps `transcriptRevision`, re-points selection after auto-title renames, refreshes).

- **Persistence:** `<vault>/.transcride/queue.json` (`TranscriptionQueueStore`, atomic, ISO8601, `{version: 1, items: […]}`), states `waiting|running|failed` + errorMessage. Done items are never persisted; anything `running` at load returns as `waiting` (relaunch resume). The scanner ignores dot-directories, so `.transcride/` is invisible to the vault.
- **Eviction & cancel:** each item runs in its own child task so one item's cancellation never tears down the worker. `remove(itemID:)` on a running item cancels in-flight work and drops it (never re-queued; nothing written); `evictItems(underPath:)` is called on entry/folder delete; a `VaultError.notFound` mid-run (entry vanished) is silently dropped with a log line. Shutdown (vault close) is the only path that re-queues a running item as waiting.
- **Rename tracking:** `repointItems(from:to:)` follows renames/moves (called from AppModel rename/move and from the queue's own success path after an auto-title rename) so queued duplicates never go stale.
- **UI phases:** the toolbar button is a determinate progress ring with the queued count (red on failure); rows and the entry-inline status show "Preparing model…" (indeterminate) whenever a running item has no engine progress yet, flipping to a determinate "Transcribing…" bar at the first progress event.

## Auto-title & slug update

Applier step 4: only when the entry's frontmatter title equals `AutoTitle.placeholderTitle` ("New Recording" — recordings; imports are title-from-filename and never placeholder). `AutoTitle.extract`: skips leading fillers (um/uh/okay/so/well/…), takes ≤ 8 cleaned words up to the first sentence end, strips wrapping punctuation (keeps `'`/`-`), capitalizes the first letter. The rename goes through `VaultOperations.renameEntry` (writes title, renames the `.md` per `TranscriptFile.fileName(forTitle:)`, updates the folder slug); a name collision is swallowed — it must not fail the transcription. Consumers get the new path via `Outcome.entryRelativePath`; AppModel fixes `selectedEntryID`, and the queue re-points other items.

## Vocabulary & correction backstop

`<vault>/vocabulary.txt`, one term per line, `#` comments; edited live in Settings (immediate atomic persistence via VaultService). Native biasing goes to engines whose flag allows (whisper-small only, as decoder prompt tokens). The backstop (`VocabularyCorrector.apply`) runs **inside the applier for every engine**, rewriting word `text` and preserving the engine's output in `corrected_from`. Exact rules as shipped (all in `Vocabulary.swift`, extensively unit-tested — extend the tests if you touch anything):

- Term key = lowercased alphanumerics (spaces/apostrophes/hyphens dropped); terms with key < 2 ignored. Windows of up to **4** adjacent words are joined and compared (longest window wins; a multi-word window may exceed the term key by at most 2 chars).
- **Exact key match:** corrected only when the written form differs and the term is multi-word, matched across a multi-word window, or has internal capitals/digits ("FluidAudio"); a case-only difference on a plain word is left alone (sentence capitalization survives).
- **Fuzzy match** requires ALL of: term key ≥ 5 chars (`minFuzzyLength`); window/term length difference ≤ 2; window key not itself an exact vocabulary term; Damerau–Levenshtein distance ≤ 1 — or ≤ 2 for terms of 8+ chars, or ≤ 3 **only for single-word windows** against 8+-char terms; for distance ≥ 2, first characters equal **or both vowels**; and **equal phonetic key** (soundex-style consonant skeleton, unbounded length, vowels/h/w/y dropped except a neutral leading `"0"` for any vowel onset, repeats collapsed).
- Merged corrections keep first.start/last.end; trailing punctuation of the last replaced word is preserved; corrected words are never re-corrected.
- Real-world calibration (from the user's torture memo, locked in tests): `Oshan Divine,` → `Ashan Devine,` and `Erikeet,` → `Airakeet,` correct; `Mythish` → `Mitesh` (3 edits on a 6-char term), `ocean`, `transcribe/transcribed` → `Transcride`, `flat audio` → `FluidAudio` are **deliberately never corrected**. False corrections are worse than misses — keep it that way (relevant to M5's VOC-4 re-apply).

## Model files on disk

- **Parakeet v3** (and the live EOU model): `~/Library/Containers/<bundle>/Data/Library/Application Support/FluidAudio/Models/…` — `AsrModels.defaultCacheDirectory(for: .v3)`; FluidAudio manages the layout. Delete = `manager.cleanup()` + remove directory.
- **WhisperKit**: `…/Application Support/WhisperKit/models/argmaxinc/whisperkit-coreml/<variant>/` (variants `openai_whisper-large-v3-v20240930_626MB`, `openai_whisper-small`). A `.transcride-download-complete` marker is written only after the file set verifies AND the first load succeeds; `isDownloaded` requires marker + required files (MelSpectrogram/AudioEncoder/TextDecoder.mlmodelc, config.json). Tokenizer is fetched into the container during that first load.
- **Apple Speech**: system-managed, nothing on our disk, no reveal button.
- Settings model rows expose `modelDirectory()` via a Show-in-Finder button (`NSWorkspace.activateFileViewerSelecting`).

## Fifth-model decision: Qwen3-ASR — excluded

PRD-3 asked to evaluate Qwen3-ASR via FluidAudio. **It does not exist anywhere in FluidAudio 0.15.5** (their ASR families are Parakeet, Cohere, Paraformer, SenseVoice — verified against the full source tree). Nothing to integrate; revisit if a FluidAudio upgrade ships it. The catalog + registry make adding a model a ~30-line change.

## Live transcription (M3 addendum — shipped)

Words appear as spoken while recording. **Display-only**: on stop, the normal seam → queue → batch pipeline produces the authoritative transcript; live text is never written to the vault.

- Engine: FluidAudio `StreamingEouAsrManager(chunkSize: .ms160)` — Parakeet EOU 120M (`FluidInference/parakeet-realtime-eou-120m-coreml/160ms`, ~450 MB, lazily downloaded by the manager into the FluidAudio cache on first use, surfaced as "Preparing live transcription… N%"). Two callbacks drive the display: partial (every chunk) and EOU-confirmed (~1.28 s silence).
- Audio path: `RecorderService.liveTee` (lock-guarded handler on the existing tap — recording writes first, tee second, no-op when detached) → channel-0 samples copied to a plain `[Float]` chunk on the audio thread → AsyncStream → detached task rebuilds mono PCM buffers for the manager (it resamples to 16 kHz internally). The recorded file/waveform/batch pipeline are identical with live mode on or off; any live failure degrades to a status note and can never affect the recording.
- `LiveTranscriber` (@MainActor @Observable) owns the session (`begin() -> handler`, `end()`, `markModelMissing()`; status idle/preparing/listening/unavailable); `LiveTranscript` (Core) splits confirmed vs volatile text (volatile renders dimmed; `tail()` for the one-line ticker).
- UX: **default in Zen mode** (no selector; requires the batch Parakeet model downloaded, else a hint shows); opt-in checkbox in the main recorder bar (UserDefaults `liveTranscriptionEnabled`) showing a ticker strip while recording.
- Known limitations (accepted): toggling off mid-recording doesn't kill the active session (clears at stop); entering Zen mid-recording starts live text from attach time, not recording start.
- **M4 interaction:** live mode is orthogonal to playback sync/editing — but if you touch `RecorderService`'s tap or `AppModel.stopRecording`, preserve the tee ordering and the `liveTranscriber.end()`/`updateLiveTranscription()` calls.

## Known issues / quirks

- `engine.app_version` records `"0 (0)"` — the dev build has no CFBundleShortVersionString set. Cosmetic; set real versions before release.
- Whisper large-v3-turbo vocabulary biasing disabled (see catalog); Mythish-class vocabulary misses are by design.
- Retranscribe of a hand-edited entry currently surfaces divergence only via the debug log and the unchanged md — PRD-4's EDT-4 requires a user-visible notice; `Outcome.markdownLeftAlone` is the hook.
- xcodebuild prints a benign "CoreSimulator is out of date" warning on every run — not ours.
- Deploying (pkill + relaunch) mid-transcription is safe (queue resumes) but kills in-flight model compilation; avoid deploying while a model row says "Preparing".
- `EngineRegistry` keeps loaded models in memory for the app's lifetime (an hour-long file peaks noticeable RAM in WhisperKit large); acceptable for now.
- All M2 gotchas in PRD-3-start-here.md (audio-tap @Sendable, keyboard monitor, FSEvents IgnoreSelf + explicit refresh, dialog-payload @State) still apply. The FSEvents pattern matters for M4's search index: in-app writes don't fire the watcher — index updates need the same explicit-refresh hooks the queue uses.
