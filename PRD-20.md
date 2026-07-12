# PRD-20 — Milestone 20: Transcride CLI and Agent Interface

> **Far-horizon roadmap item:** Milestones 11–19 are intentionally unspecified and
> remain available for nearer product work. Do not begin this milestone until every
> preceding milestone that is ultimately defined has been human-verified. At
> milestone start, read the then-current `PROJECT-STATE.md`, vault schema, import
> pipeline, transcription queue contract, and app/CLI coordination architecture.

## Goal

Ship a stable `transcride` command-line interface that lets people, scripts, and
agents discover how Transcride expects audio and vault data to be addressed, inspect
the active/recent vault context, and import an audio file through the same safe
pipeline as the macOS app.

The CLI is Transcride's long-term agent interface: machine-readable, composable,
local-first, and explicit enough that an agent can discover the contract without
reverse-engineering the vault or editing its files directly.

## Scope

**In:** a signed `transcride` executable installed with the app and made available on
`PATH`; self-describing no-argument output; stable JSON mode and schema version;
current-vault discovery; recent-vault listing; single and batch audio import; explicit
vault targeting; transcription-queue handoff; import/job status; deterministic exit
codes; stdout/stderr discipline; app/CLI mutation coordination; privacy, security,
and automation documentation.

**Out:** arbitrary transcript editing, direct mutation of vault internals, agent chat,
remote/cloud control, a general plugin runtime, MCP server implementation, shelling
out to private app internals, or exposing every GUI action as a command. Those may be
designed later on top of the stable CLI contract.

## Command surface

### Self-describing root command (CLI-1)

Running `transcride` with no arguments prints a concise discovery document containing:

- CLI and output-schema versions.
- The currently selected vault's absolute path and stable local identifier, or a
  structured `no_current_vault` state.
- Supported input media types and whether video containers with audio are accepted.
- The canonical entry/vault format the CLI creates or expects, described without
  encouraging callers to write those files themselves.
- The minimum commands needed to import audio, list recent vaults, inspect an import,
  and request the full schema/help output.
- Whether the app must be running and which capabilities are currently available.

Interactive terminals receive readable text. `transcride --json` emits one complete
JSON object with a documented, versioned schema and no decorative text. Agents must
not need to scrape prose or ANSI formatting.

### Import audio (CLI-2)

The primary command is:

```sh
transcride import <audio-file>
```

- Import uses the same validated import, entry creation, waveform, metadata, and
  transcription-queue path as drag-and-drop in the app. The CLI never assembles an
  entry folder independently and never edits the source file in place.
- Relative paths resolve from the caller's working directory. `-` may represent one
  streamed input only if the caller supplies an explicit filename/media type; a
  temporary copy must be safely finalized before import begins.
- Multiple path arguments and directories are supported for batch work. Directory
  traversal is non-recursive by default; `--recursive` is explicit. Unsupported files
  are reported individually rather than aborting unrelated valid imports.
- The default destination is the current vault. `--vault <id-or-path>` targets a
  specific known or valid vault without silently changing the GUI's selected vault.
- The source is copied into the vault. Default behavior queues transcription using
  the vault/app defaults. Flags may select a supported model, disable automatic
  transcription, or wait for completion, but capability values come from discovery
  output rather than hard-coded agent assumptions.
- A successful enqueue returns the stable entry id/path, import job id, destination
  vault id/path, copied audio filename, and transcription job id/state. `--wait`
  streams human progress on stderr while reserving stdout for the final result.
- Repeating an import is not silently deduplicated. An explicit `--idempotency-key`
  gives automation a safe retry contract; reuse returns the original result or a
  specific conflict when the request differs.

### Vault discovery (CLI-3)

Provide:

```sh
transcride vault current
transcride vault list --recent
```

- `vault current` reports the selected vault without launching UI or changing state.
- Recent-vault output includes stable local id, display name, absolute path,
  last-opened time, availability, writability, and whether it is current.
- Missing, moved, disconnected, or permission-denied vaults remain distinguishable.
  A stale recent path must never be treated as a writable destination.
- A path supplied to `--vault` is validated as a Transcride vault. Creating,
  registering, selecting, or forgetting a vault requires an explicit future command;
  import must not perform those state changes as a side effect.

### Jobs and capabilities (CLI-4)

Provide a minimal inspection surface so asynchronous imports are actually usable:

```sh
transcride job status <job-id>
transcride capabilities
transcride schema
```

- Job status distinguishes copying, imported, queued, transcribing, completed,
  failed, canceled, and recoverable/interrupted states. Failures include a stable
  error code, safe message, and retryability without leaking transcript/audio data.
- `capabilities` is the authoritative inventory of formats, engines/models,
  features, app-service availability, and relevant limits on this Mac.
- `schema` emits the exact current JSON schemas and compatibility policy. Every JSON
  response carries `schema_version`, `command`, `ok`, and either `result` or `error`.

## Automation contract

### Output and errors (CLI-5)

- In `--json` mode, stdout contains JSON only. Diagnostics and progress go to stderr.
- Success is exit code 0. Usage errors, unavailable vaults, unsupported media,
  permission failures, coordination failures, partial batch success, and internal
  failures have documented non-zero exit codes. Stable structured error codes are the
  primary automation contract; prose may improve without breaking clients.
- Batch output reports every requested item and uses a partial-success exit code when
  at least one item failed. Ordering matches the input ordering.
- `--quiet`, `--no-color`, and `--version` behave conventionally. Commands never
  prompt when stdin is not a TTY; a needed choice becomes a structured error unless
  the caller supplied an explicit flag.
- JSON fields are additive within a schema major version. Removing/changing a field
  requires a version bump and a documented compatibility window.

### App and vault coordination (CLI-6)

- The CLI and GUI share one mutation authority rather than racing independent file
  writers. At milestone start, choose and document either an app-owned XPC service,
  a launchable background service, or a shared coordination layer with cross-process
  locking and transaction recovery.
- Define behavior when the GUI is open, closed, updating, or an older incompatible
  version. The CLI must either start/connect to the compatible local service or fail
  clearly; it must never bypass coordination and write directly as a fallback.
- Concurrent imports are serialized or bounded through the canonical queue. File
  copying, entry creation, indexing, waveform generation, and transcription remain
  crash-safe and idempotently recoverable.
- External vault edits and FSEvents refresh use the same existing contracts as the
  app. The CLI must not leave the GUI with stale state.

### Installation, privacy, and security (CLI-7)

- The CLI ships from the same source/version as the app, is code-signed, and exposes
  a supported installation/link flow into a standard user-accessible `PATH` location.
  App updates keep the CLI compatible and do not leave stale binaries behind.
- All commands are local-only unless a later command explicitly documents otherwise.
  No audio, transcript, path, prompt, usage, or telemetry data leaves the Mac.
- Resolve symlinks and file permissions deliberately; reject path traversal and
  destinations outside the selected vault contract. Never print transcript content,
  secrets, or full diagnostic payloads unless the caller asks for that data.
- Respect macOS privacy permissions and sandbox boundaries. Permission errors explain
  the exact user action needed and do not trigger surprise UI in non-interactive use.

## Decisions already made (do not relitigate)

- This is Milestone 20, intentionally far behind the currently specified roadmap.
- The executable and root command are named `transcride`.
- `transcride import <audio-file>` is the primary action.
- Running `transcride` describes the interaction contract, supported input format,
  expected vault/entry format, and current vault location.
- Recent vaults are discoverable through a dedicated command.
- The CLI is the foundation for agent integration, but agents use supported commands
  rather than directly mutating plain vault files.
- Machine-readable output is a versioned product API, not an incidental rendering of
  human help text.

## Open design questions for Milestone 20

These are intentionally deferred until the surrounding architecture exists:

1. Does a headless background service own imports, or does the CLI launch/connect to
   the GUI app? The answer determines reliability in SSH, Shortcuts, and agent runs.
2. Where is the signed executable linked so both GUI installs and updates remain
   compatible without requiring unsafe installer privileges?
3. Should the first release support stdin, recursive directories, model selection,
   and `--wait`, or stage those immediately after single-file import?
4. What is the stable identity for a vault, entry, and job across moves, relaunches,
   and app upgrades?
5. How long are completed job records retained, and where does an agent retrieve a
   failure after the submitting process exits?
6. Is a future MCP server a thin adapter over this CLI/schema, or should both share a
   lower-level local service API? The CLI contract must not preclude either path.

## Definition of done

- A fresh agent can run `transcride --json`, discover the current vault and supported
  contract, import an audio file, wait or poll for completion, and identify the new
  entry without reading source code or scraping human text.
- CLI import and GUI import produce equivalent canonical entry artifacts and queue
  behavior for the same input and settings.
- Unit/contract tests cover schemas, exit/error codes, path and vault resolution,
  capability discovery, batch partial success, idempotency keys, and compatibility.
- Integration tests cover GUI open/closed, concurrent GUI/CLI imports, app/CLI version
  mismatch, missing/unwritable/disconnected vaults, unsupported/corrupt media,
  interruption during copy/queue/transcription, retry, and non-interactive execution.
- Release tests verify signing, installation on `PATH`, app update compatibility,
  uninstall behavior, and zero unintended network traffic.
- Documentation includes copy-paste human examples and an agent-oriented JSON example
  for every public command.

## Verification checklist (human-run)

**Interactive, one item at a time; the human confirms each.**

- [ ] From a new terminal, `transcride` clearly reports the current vault, supported
  input/entry contract, essential commands, and app/service readiness.
- [ ] `transcride --json` emits valid JSON only; an agent can select fields without
  stripping color, logs, or prose.
- [ ] `transcride vault current` and `transcride vault list --recent` distinguish the
  current, available, missing, and unwritable vault cases accurately.
- [ ] `transcride import <audio-file>` copies the source into the current vault,
  returns stable identifiers, and follows the same waveform/transcription path as GUI
  import without altering the source.
- [ ] `--vault` targets another vault without changing the GUI's selected vault.
- [ ] Batch import reports all successes and failures in input order and returns the
  documented partial-success code.
- [ ] Retrying with the same idempotency key cannot create a duplicate entry.
- [ ] A submitting process can exit and later recover state with
  `transcride job status <job-id>`.
- [ ] Imports remain correct with the GUI open and closed, and concurrent requests do
  not corrupt entries, duplicate transcription, or leave the app stale.
- [ ] Unsupported media, corrupt input, permission denial, disconnected vault, and
  app/CLI version mismatch each return a stable structured error and useful exit code.
- [ ] Force-kill during copy and queue handoff: relaunch/retry converges without a
  half-visible entry or duplicate work.
- [ ] The installed CLI is signed, on `PATH`, version-matched to the app, and remains
  correct through an app update.
- [ ] Network monitoring confirms import, discovery, and job inspection remain local.

## Handoff

After verification, update `PROJECT-STATE.md` with the command/schema version,
executable installation path, service/coordination architecture, vault/entry/job
identity contracts, JSON schemas, exit codes, idempotency behavior, queue handoff,
privacy/security decisions, compatibility policy, test matrix, deviations, and known
issues. Write the next milestone handoff only after the human confirms every item.
