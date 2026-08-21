# PRD-9 — Milestone 9: Local AI Summary Layer

> **Before starting:** read `milestone-8-handoff.md`, [PROJECT-STATE.md](PROJECT-STATE.md),
> and the Original/Edited layer contracts in [master-prd-backup.md](master-prd-backup.md).
> Milestone 8 was human-verified on 2026-08-20, so this milestone's gate is satisfied.
> Summary generation must remain local-only and must never mutate either transcript layer.
> (This document was renamed from PRD-10 and amended when the milestone was pulled
> forward: summaries are editable, and the model/runtime decision is recorded below.)

## Goal

Add a local AI summary beside the existing transcript layers. The layer selector
becomes **Original / Edited / Summary**, allowing a user to generate, read, and edit a
basic Markdown summary without sending audio or text to a server and without requiring
more than 8 GB of RAM.

## MVP-first implementation route

The milestone deliberately ships in two phases:

1. **MVP (first):** a Summary button in the transcript workbench toolbar swaps the
   karaoke/edit pane for the summary view — generate, read, edit, save, regenerate.
   Model download/selection lives in Settings. No selector segment, search, export,
   or menu integration yet. The MVP exists so the human can iterate on the UI design
   hands-on before the full surface is built.
2. **Full milestone (after UI iteration with the human):** the three-segment
   Original / Edited / Summary selector, Summary as a labeled search layer,
   copy/export integration, menu commands, and accessibility polish.

The verification checklist below is run only when the full milestone is implemented;
the MVP is reviewed informally with the human as it evolves.

## Scope

**In:** third Summary selector option; local model download/removal and readiness;
basic in-place summary generation and regeneration; explicit source selection;
user-editable summaries with hand-edit tracking; under-8-GB peak-memory enforcement;
progress/cancel/error states; plain Markdown storage; stale-summary handling;
copy/export/search integration; offline operation.

**Out:** chat, arbitrary prompting, cloud inference, agent workflows, chapters,
action-item extraction, automatic tags, background generation without user intent,
summaries spanning multiple entries, or rewriting Original/Edited text.

## Requirements

### Three-layer selector

- Replace the two-way Original/Edited selector with **Original / Edited / Summary**.
- Original remains immutable engine output. Edited remains the user-owned Markdown
  layer. Summary is a separate derived layer and never substitutes for either one.
- Summary is selectable before generation and shows a designed empty state with a
  **Generate Summary** action. While unavailable because no transcript exists, it
  explains why rather than disappearing.
- Remember the viewed layer per entry during the app session. Opening another entry
  must never make its Summary appear as the current entry's content.

### Source and output

- Generation summarizes the Edited layer when the entry has a real hand-edited
  layer; otherwise it summarizes Original. The confirmation/progress UI names the
  chosen source. A compact source picker may override this when both layers exist.
- The default output is intentionally basic Markdown: a short overview followed by
  a small set of concise bullet points. No invented headings, action items, tags, or
  claims unsupported by the source. Output is produced by filling a fixed Markdown
  section template (template-as-data, so richer templates can be added later) rather
  than by structured JSON generation.
- Store the result as ordinary UTF-8 Markdown inside the entry as a hidden sidecar
  **`.summary.md`** (dot-named so vault entry scanning ignores it, and never injected
  into the note body — fork detection compares the whole body). Its frontmatter
  carries the derived metadata: `summary_model`, `summary_source_layer`,
  `summary_source_fingerprint`, `summary_generated`, and `hand_edited`. The source
  layer is never modified.
- **Summary is editable.** Edits save independently of both transcript layers and
  set `hand_edited`. **Regenerate Summary** replaces the prior Summary after
  confirmation — always confirming when it would discard hand edits — and a failed
  or cancelled regeneration leaves the previous Summary untouched. Copy as Markdown
  and Markdown export operate on Summary when Summary is selected.
- **Generation may propose an entry title** (harvested from a leading `# Title`
  line in the template output and recorded as `summary_title`). It renames the
  entry — through the canonical rename bookkeeping — only while the current title
  is machine-derived: the recording placeholder, the transcription auto-title
  heuristic, or a prior AI summary title. A human rename is never overwritten,
  and a title failure never fails the summary.
- The Summary reads as rendered GitHub-flavored Markdown; editing switches to the
  raw Markdown editor and saving returns to the rendered view.

### Local model and memory ceiling

- Inference is entirely on-device. No transcript text, summary text, prompt, or
  telemetry leaves the Mac. Once the model is downloaded, generation works with
  network access disabled.
- **Runtime and models (decided 2026-08-20):** MLX Swift (`mlx-swift-lm`, products
  `MLXLLM`/`MLXLMCommon`) running Gemma 3 QAT 4-bit checkpoints from Hugging Face:
  `mlx-community/gemma-3-1b-it-qat-4bit` (~0.75 GB, "Fast") and
  `mlx-community/gemma-3-4b-it-qat-4bit` (~3.2 GB, "High Quality"). Every offered
  model stays under a **5 GB download cap**. The default is RAM-adaptive: Macs with
  less than 16 GB of physical memory default to the 1B model, others to the 4B; the
  user can override the default in Settings.
- The selected model/runtime must keep the app's measured peak resident memory below
  **8 GB** while summarizing the milestone's longest supported test transcript. This
  is a runtime ceiling, not merely a model-download-size limit. The chunker's
  context budget is capped accordingly regardless of the model's native window.
- Model management reuses the existing download/readiness/delete presentation where
  practical. The UI states disk size and that generation is local. Cancellation must
  release inference resources promptly, and loaded weights are released after each
  generation.
- If a transcript exceeds the chunker's context budget, summarize deterministic
  chunks and perform a final local reduction pass. Chunk boundaries must not
  silently omit source text.

### Freshness and safety

- Fingerprint the exact source text used. If that source changes or a new Original
  arrives, keep the prior Summary readable but mark it **Out of Date** and offer
  regeneration. Never regenerate automatically.
- Write new output to a temporary file and atomically replace the prior Summary only
  after successful generation and validation. Cancellation, model failure, app quit,
  or a crash leaves the last valid Summary unchanged.
- A summary-generation failure has no effect on audio, Original, Edited, transcript
  timing, or search data.
- Search indexes Summary as a separately labeled layer. Summary hits open the entry
  with Summary selected and never claim an audio timestamp.

### Accessibility and commands

- The selector and Generate/Regenerate/Cancel actions are keyboard reachable and
  have explicit VoiceOver labels and progress announcements.
- Add menu commands for **Show Summary** and **Generate Summary…** without stealing
  bare keys from text editing or PRD-8 global recording controls.

## Definition of done

- Unit tests cover source selection, deterministic prompt/input construction,
  content fingerprinting, stale-state transitions, chunk coverage, output validation,
  atomic replacement, cancellation preservation, summary edit persistence, and
  Summary search-layer routing.
- Integration tests cover first model download, offline generation, regeneration,
  hand-edited source protection, hand-edited summary protection, retranscription
  staleness, oversized transcript chunking, cancellation, generation failure, and
  relaunch with a prior Summary.
- A recorded benchmark on the minimum supported Apple-silicon test Mac demonstrates
  peak resident memory below 8 GB for the longest supported transcript.
- `xcodebuild test`, Release build, and `xcodebuild analyze` pass.

## Verification checklist (human-run)

**Interactive, one item at a time; the human confirms each.**

- [ ] The selector reads Original / Edited / Summary and each choice displays only
  that entry's corresponding content.
- [ ] On an unedited entry, Generate Summary clearly uses Original and produces a
  short overview plus concise bullets.
- [ ] On a hand-edited entry, generation defaults to Edited; Original and Edited are
  byte-identical before and after generation.
- [ ] Editing the Summary saves independently, survives relaunch, and marks the
  Summary hand-edited; neither transcript layer changes.
- [ ] Regenerating a hand-edited Summary asks for confirmation first; declining
  leaves the edited Summary intact.
- [ ] Copy as Markdown and export while viewing Summary produce the Summary text.
- [ ] Disable networking after model download and generate another Summary
  successfully; no network request is made.
- [ ] Edit the chosen source: the old Summary stays readable, is marked Out of Date,
  and changes only after explicit regeneration.
- [ ] Retranscribe an unedited entry: its prior Summary becomes Out of Date; audio,
  timing, and the new Original remain correct.
- [ ] Cancel during generation and force a generation failure: the last valid Summary
  remains intact and neither transcript layer changes.
- [ ] Summarize a transcript beyond one context window: the result covers content
  from the beginning, middle, and end.
- [ ] Search for a phrase unique to a Summary: the result is labeled Summary, opens
  that layer, and does not offer a false audio jump.
- [ ] Observe generation on the minimum supported test Mac: recorded peak resident
  memory stays below 8 GB and the app remains responsive enough to cancel.
- [ ] Remove and re-download the local model; readiness, disk-size copy, and errors
  are accurate. The RAM-adaptive default picks the expected model.
- [ ] VoiceOver identifies the three layers and announces generation progress and
  completion; all actions are keyboard reachable.
- [ ] Regression: Original karaoke/click-to-seek, Edited autosave, transcription,
  Compress Audio, Skip Silence, search, and export still work.
- [ ] `xcodebuild test`, Release build, and analysis pass.

## Handoff

After verification, update `PROJECT-STATE.md` with the chosen model/runtime and
license, memory benchmark, Summary storage schema, freshness fingerprint, chunking
strategy, atomic-write behavior, search integration, file map, deviations, and any
deferred AI work, and write the next milestone's start-here handoff if a next
milestone is defined.
