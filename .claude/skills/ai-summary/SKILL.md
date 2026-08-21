---
name: ai-summary
description: Work on Transcride's local AI summary feature (MLX + Gemma) — architecture map, model management, prompt pipeline, storage contract, and the gotchas that are not obvious from the code.
---

# Transcride AI summaries (PRD-9)

Local, on-device transcript summaries via MLX Swift + Gemma 3 QAT 4-bit. The
governing spec is `PRD-9.md` (renamed from PRD-10; summaries are **editable**,
gated milestone workflow applies). The MVP surface is a Summary button in the
workbench toolbar that swaps the transcript pane for the summary; the full
three-segment Original/Edited/Summary selector, search layer, export, and menu
commands are later-in-milestone work.

## Architecture map

| File | Responsibility |
|---|---|
| `Transcride/Core/SummaryDocument.swift` | `.summary.md` sidecar parse/serialize on `FrontmatterDocument`; `SummaryFingerprint` (SHA256 of whitespace-normalized text) |
| `Transcride/Core/SummarySource.swift` | Source selection: Edited iff `TranscriptEditDocument.isForked`, else Original via `TranscriptMarkdown.body` (speaker labels kept for attribution) |
| `Transcride/Core/SummaryPrompt.swift` | `SummaryTemplate` (sections as data, leads with `# [Title]`), `SummaryChunker` (chars×0.35 token estimate, sentence-snapped, 100-token overlap), prompts, `cleanedOutput`, `extractTitle` (harvest+strip the H1, meetily pattern), `validate` |
| `Transcride/Core/SummaryTitlePolicy.swift` | `entryTitleIsMachineDerived(currentTitle:original:previousSummaryTitle:)` — the only gate on AI renames |
| `Transcride/App/Summarization/SummaryModelCatalog.swift` | Two `TranscriptionModelInfo` entries + `SummaryModelSpec` (context budget, sampling preset); RAM-adaptive default |
| `Transcride/App/Summarization/SummarizationEngine.swift` | The ONLY file importing MLX/HuggingFace. `actor : ModelManaging`; download, load, map/combine/final generation, cancellation |
| `Transcride/App/Summarization/SummaryGenerationController.swift` | `@MainActor @Observable` per-entry phase (`idle/generating(part:total:fraction:)/failed`), one job per entry via mutable `JobToken`, `summaryRevision` reload key |
| `Transcride/UI/TranscriptionQueueView.swift` | The toolbar "AI Queue" ring + popover — transcription items AND summary jobs (progress bar from `phase.fraction`, cancel, Retry via `AppModel.retrySummary`) |
| `Transcride/App/VaultService.swift` | `loadSummary` / `saveSummaryBody` / `writeGeneratedSummary` (AtomicFile; no search sync, no transcript hand-edited semantics) |
| `Transcride/App/AppModel.swift` | `summaryController` + async wrappers `loadSummary/saveSummaryBody/generateSummary` |
| `Transcride/UI/TranscriptWorkbenchView.swift` | Summary button (between Copy and Edit), `summaryContent` overlay states, click-to-edit via `MarkdownBodyEditor`, 600 ms debounced save, regenerate confirm, staleness badge |
| `Transcride/UI/TranscriptionSettings.swift` | `AISummaryModelsSection` (picker + `ModelRow`s), wired into `TranscriptionSettingsPane` |
| `TranscrideTests/SummaryTests.swift` | Unit tests for all Core pieces |

## Storage contract — `.summary.md`

- Hidden sidecar in the entry folder. Dot-named because `VaultScanner` skips
  leading-dot names (VaultScanner.swift:68,93) — a visible second `.md` would
  confuse entry scanning.
- **NEVER inject the summary into the note body.** `TranscriptEditDocument.isForked`
  compares the whole body against a regeneration of the original; any injected
  section permanently forks the entry and freezes regeneration on retranscribe.
- Frontmatter keys: `summary_model`, `summary_source_layer` (original|edited),
  `summary_source_fingerprint` (SHA256 hex of whitespace-normalized source),
  `summary_generated` (FrontmatterDate), `hand_edited` (set by user edits;
  regenerate-over-hand-edits requires a confirmation dialog).
- Writes go through `AtomicFile` — replace-only-on-success is the whole
  regeneration-safety story (meetily needed a result_backup column for this).
- Staleness = stored fingerprint ≠ fingerprint of current source text; show
  "Out of date", never regenerate automatically.

## Model catalog & download

- Models: `mlx-community/gemma-3-1b-it-qat-4bit` (~0.75 GB, "Fast") and
  `mlx-community/gemma-3-4b-it-qat-4bit` (~3.2 GB, "High Quality"). Keep every
  offered model under the 5 GB download cap; runtime ceiling is 8 GB peak RSS.
- Default: UserDefaults `defaultSummaryModel` override, else RAM-adaptive
  (`physicalMemory >= 16 GiB → 4B, else 1B`); empty string = Automatic in the
  Settings picker.
- The 4B repo is a **multimodal** checkpoint: mlx-swift-lm's `LLMTypeRegistry`
  maps model_type `"gemma3"` → `Gemma3TextModel`, which sanitizes vision
  weights and reads nested `text_config`, so it loads text-only. Fallback if a
  QAT repo breaks: `gemma3n_E4B_it_lm_4bit` (registry-blessed, text-only LM repo).
- Adding a model: catalog entry + `SummaryModelSpec` + (if not in `LLMRegistry`)
  `ModelConfiguration(id:, extraEOSTokens: ["<end_of_turn>"])` for Gemma.
- Download: `HubClient(cache: HubCache(cacheDirectory: Application Support/SummaryModels))`
  through the `#hubDownloader(client)` + `#huggingFaceTokenizerLoader()` macros
  into `MLXLMCommon.loadModelContainer(from:using:configuration:progressHandler:)`.
  Layout is Python-hub-style `models--org--repo` with blob symlinks; the repo
  dir is the delete unit. `.transcride-download-complete` sentinel is written
  only after a successful first load (WhisperKitEngine precedent — "downloaded"
  means "runnable"). `useLatest: false` (default) returns the cached snapshot,
  which is what makes offline generation work.
- `ModelManager.managing(forID:)` resolves summary ids to `SummarizationEngine`
  before the ASR registry (same shape as the diarizer); `refresh()` iterates
  `SummaryModelCatalog.available` too. The whole Settings state machine
  (download/progress/cancel/delete/Show in Finder) then works unchanged.

## Generation pipeline (meetily-derived)

- **Template-fill, not JSON.** Meetily's abandoned Python pipeline proved
  small local models emit malformed JSON too often; their shipped Rust
  pipeline fills a markdown skeleton with per-section instructions. Keep it.
  `SummaryTemplate.basic` = **Summary** (paragraph) + **Key Points** (bullets);
  sections are data so richer templates can be added later.
- Chunking: token estimate = chars × 0.35; chunk budget = model context
  (`SummaryModelSpec.contextTokens`, capped at 8K for memory) − 300 reserve;
  ~100-token overlap; boundaries snap back to ". " then whitespace, never past
  mid-chunk (a boundary desert can't stall progress).
- Passes: single final pass when the text fits; else map (per chunk) →
  combine → final template fill. Progress = "part n/m" pushed via callback
  (meetily computes this but never surfaces it — we do).
- Sampling: Gemma official preset temp 1.0 / top_k 64 / top_p 0.95,
  maxTokens 1024. Do NOT "safety-lower" the temperature — QAT checkpoints are
  tuned for the official preset.
- Prompts fence the transcript in `<transcript>`/`<transcript_chunk>` tags and
  instruct the model to ignore any instructions inside them (transcripts are
  untrusted speech). Empty sections get "None noted." — never invented content.
- Output hygiene: strip `<think>` blocks, unwrap code fences
  (`SummaryPrompt.cleanedOutput`); then `validate` checks every section header
  survived + some content exists, with ONE retry of the final pass.
- Memory: `MLX.GPU.set(cacheLimit: 512 MB)` on load; the `ModelContainer` is
  released after every generation (defer) so RSS falls back; one generation at
  a time; `Task.checkCancellation()` per streamed token (typed
  `CancellationError`, never string matching).
- Progress: the engine reports `GenerationProgress(part:total:fraction:)` —
  overall fraction = completed passes + streamed-token fraction of the running
  pass against `maxTokens`, capped at 0.95 within a pass (output length is
  unknowable), throttled to every 8 pieces. Surfaced in the workbench pane and
  in the toolbar AI Queue ring/popover, which merges transcription items and
  summary jobs (transcription wins the ring when both run).

## Entry titling (AI rename)

- Pipeline: template output leads with `# Title` → `SummaryPrompt.extractTitle`
  cleans it (strip emphasis/quotes, clamp 80 chars) and strips it from the body
  → stored as sidecar `summary_title` → controller fires
  `onTitleProposed(path, title, previousTitle)` AFTER releasing its job slot
  (previousTitle is read from the OLD sidecar before the overwrite — that
  ordering is what lets regeneration refresh an AI title) → `AppModel.
  applySummaryTitle` re-checks eligibility fresh and renames.
- Eligibility (`SummaryTitlePolicy`): rename only while the current title is
  machine-derived — nil/empty, `AutoTitle.placeholderTitle`, the recomputed
  transcription heuristic (`AutoTitle.extract` regenerate-and-compare, no flag),
  or the previous `summary_title`. A human rename is permanent.
- The rename mirrors `entryTranscribed` (AppModel): `service.renameEntry` inside
  `refresh(apply:)` with queue/recovery/summary `repointItems` + selection remap
  in ONE main-actor turn (prevents the "No Entry Selected" flash). Best-effort:
  errors are swallowed to DebugLog — a title must never fail a summary.
- `SummaryGenerationController` keys jobs through a mutable `JobToken` whose
  `path` is updated by `repointItems` — a rename mid-generation (user or AI)
  must not orphan phase state or strand the job slot. All three rename/move
  paths in AppModel call `summaryController.repointItems`.

## Rendered markdown

- Read mode renders via **MarkdownUI 2.4.1** (`gonzalezreal/swift-markdown-ui`,
  UI layer only): `Markdown(body).markdownTheme(.transcride).textSelection(.enabled)`
  (the custom theme lives in `Transcride/UI/SummaryMarkdownTheme.swift`)
  in a ScrollView (insets 22/20 matching the raw editor); double-click enters
  the raw `MarkdownBodyEditor`, Save returns to rendered. MarkdownUI is
  maintenance-mode but stable; its successor Textual was 0.1.0 (not adopted).

## Gotchas

- `TranscrideTests` compiles `Transcride/Core` **without SPM packages** — no
  MLX/HuggingFace import may appear in Core. Pure logic (chunker, prompts,
  fingerprint, sidecar) lives in Core for testability; MLX binding stays in
  `SummarizationEngine.swift` (also confines package API drift to one file).
- `xcodegen generate` after adding/removing files; never edit the xcodeproj.
- Builds need `-skipPackagePluginValidation -skipMacroValidation` (mlx-swift
  ships a CudaBuild plugin; mlx-swift-lm uses macros), and the machine needs
  the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).
- Swift 6 strict concurrency: engine is an actor; controller is `@MainActor`
  with deliberate strong self-capture in its task; don't re-capture a `weak
  self` binding inside a nested `@Sendable` closure (won't compile).
- An entry rename **recreates the workbench view**: `EntryDetailView` renders
  it only while `loadedEntryPath == entry.relativePath`, so the AI title
  rename swaps in the loading branch and all workbench `@State` (incl.
  `showingSummary`) is lost. Any "still showing after generation" intent must
  live outside the view — the controller's `pendingReveal` (repointed on
  rename, matched by `EntryIdentity.sameEntry`, consumed once in
  `reloadSummary()`) is that mechanism; it is what auto-reveals the finished
  summary instead of flashing back to the transcript.
- The workbench autosave (600 ms debounce) must NOT bump `summaryRevision` —
  the reload `.task` keys on it and would clobber in-flight typing. Only
  generation bumps it, and `reloadSummary()` no-ops while `isEditingSummary`.
- UI iteration status: the button/overlay MVP is the current state; the
  three-segment selector, SearchLayer `.summary`, export and menu integration
  are still open PRD-9 work.
