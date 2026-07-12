# PRD-10 — Milestone 10: Local AI Summary Layer

> **Before starting:** read `PRD-10-start-here.md` (written after Milestone 9),
> [PROJECT-STATE.md](PROJECT-STATE.md), and the Original/Edited layer contracts in
> [master-prd-backup.md](master-prd-backup.md). **Do not start until the human
> confirms Milestone 9 is verified.** Summary generation must remain local-only and
> must never mutate either transcript layer.

## Goal

Add a simple local summary beside the existing transcript layers. The layer selector
becomes **Original / Edited / Summary**, allowing a user to generate and read a basic
Markdown summary without sending audio or text to a server and without requiring
more than 8 GB of RAM.

## Scope

**In:** third Summary selector option; local model download/removal and readiness;
basic in-place summary generation and regeneration; explicit source selection;
under-8-GB peak-memory enforcement; progress/cancel/error states; plain Markdown
storage; stale-summary handling; copy/export/search integration; offline operation.

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
  claims unsupported by the source.
- Store the result as ordinary UTF-8 Markdown inside the entry using a dedicated
  filename/schema documented during implementation. Include derived metadata for
  source layer, source-content fingerprint, model id, and generation date without
  modifying the source layer.
- Summary is read-only in this milestone. **Regenerate Summary** replaces only the
  prior derived Summary after confirmation. Copy as Markdown and Markdown export
  operate on Summary when Summary is selected.

### Local model and memory ceiling

- Inference is entirely on-device. No transcript text, summary text, prompt, or
  telemetry leaves the Mac. Once the model is downloaded, generation works with
  network access disabled.
- The selected model/runtime must keep the app's measured peak resident memory below
  **8 GB** while summarizing the milestone's longest supported test transcript. This
  is a runtime ceiling, not merely a model-download-size limit.
- Do not hard-code a model choice in this roadmap document. At milestone start,
  benchmark current local runtimes/models on the minimum supported Apple-silicon Mac
  and record the chosen model, quantization, context limit, license, disk size, peak
  memory, and fallback behavior in `PRD-10-start-here.md` before implementation.
- Model management reuses the existing download/readiness/delete presentation where
  practical. The UI states disk size and that generation is local. Cancellation must
  release inference resources promptly.
- If a transcript exceeds the chosen context window, summarize deterministic chunks
  and perform a final local reduction pass. Chunk boundaries must not silently omit
  source text.

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
  atomic replacement, cancellation preservation, and Summary search-layer routing.
- Integration tests cover first model download, offline generation, regeneration,
  hand-edited source protection, retranscription staleness, oversized transcript
  chunking, cancellation, generation failure, and relaunch with a prior Summary.
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
  are accurate.
- [ ] VoiceOver identifies the three layers and announces generation progress and
  completion; all actions are keyboard reachable.
- [ ] Regression: Original karaoke/click-to-seek, Edited autosave, transcription,
  Compress Audio, Skip Silence, search, and export still work.
- [ ] `xcodebuild test`, Release build, and analysis pass.

## Handoff

After verification, update `PROJECT-STATE.md` with the chosen model/runtime and
license, memory benchmark, Summary storage schema, freshness fingerprint, chunking
strategy, atomic-write behavior, search integration, file map, deviations, and any
deferred AI work.
