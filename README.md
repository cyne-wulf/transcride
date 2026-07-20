# Transcride

> [!CAUTION]
> This branch is an archive of a failed multi-agent implementation. It is kept
> only as reference material. It is not a release candidate, it has not passed
> the required human verification, and it should not be merged into `main`.

## What this archived branch contains

This branch preserves the worktree produced by an overnight multi-agent effort on
2026-07-20. The source snapshot is commit `dbc4212` on
`codex/archive-broken-agent-swarm-2026-07-20`. Its comparison point is `main` at
commit `f5d8dab`, **Render waveform immediately on selection**.

The archive is much more than a single editor experiment. It combines a large,
previously uncommitted Milestone 8 implementation with an attempted Milestone 9
editor rewrite. Those two bodies of work touch recording controls, application
commands, vault navigation, search, file persistence, editor lifecycle, and most
of the main workbench at the same time. That breadth is the main reason this
snapshot is difficult to reason about and unsafe to continue maintaining as one
change.

Relative to the restored `main`, the archive changes 104 files, adds roughly
22,800 lines, and removes roughly 2,000 lines. The rest of this section describes
that delta in product and architectural terms rather than as a source-code diff.

## Human-readable delta from `main`

### Project status and milestone governance

The restored `main` identifies Milestone 7 as the last verified milestone and
Milestone 8 as not started. This branch rewrites the project state to say that:

- Milestone 7 remains the last verified gate, with all 17 human checks completed
  on 2026-07-12.
- Milestone 8 has been implemented in the worktree but its 23-item human checklist
  was skipped. It is explicitly unverified and has no `milestone-8` tag.
- A one-time waiver dated 2026-07-17 allowed Milestone 9 implementation to begin
  without verifying Milestone 8. The waiver does not verify either milestone and
  does not apply to later milestones.
- A new Milestone 9 handoff describes the large dirty starting state, the intended
  CodeMirror architecture, the accumulated Milestone 8 contracts, and known risks.

The branch also substantially rewrites the Milestone 8 and Milestone 9 product
documents. In particular, its Milestone 9 is narrower and more editor-focused than
the version on `main`. It permanently removes outline navigation, backlinks,
Linked Mentions, wikilink autocomplete and note creation, inbound-link rewriting,
a tag browser or tag-writing interface, and Original-versus-Edited diff view. It
retains only existing-link navigation and read-only tag extraction/filtering.

### System-wide recording controls

The branch carries forward an attempted Milestone 8 implementation that lets the
user control recording while Transcride is unfocused:

- Configurable global Start/Stop-and-Save and Pause/Resume shortcuts are registered
  through the native macOS hotkey system.
- A native menu-bar item presents recording state, elapsed time, recording
  commands, app/window commands, settings, and quit behavior.
- A small floating recording widget can appear above other applications and across
  Spaces without taking keyboard focus. Its position is stored relative to the
  active display, and it has both automatic background visibility and a manual,
  session-only visibility override.
- Recording requests from the app, menu bar, global shortcuts, and floating widget
  are routed through one serialized command path intended to prevent overlapping
  start, pause, and stop operations.
- Window presentation is reworked so the main window, Settings, About, and Keyboard
  Shortcuts can be reopened after the last main window closes.
- Application termination is changed to wait for both active recording handling
  and editor persistence before allowing the process to exit.

### Remappable application shortcuts

Beyond the two global recording shortcuts, the branch attempts a full application
shortcut system:

- About 60 Transcride actions are represented by stable identifiers grouped into
  Recording/File, Notes/Entry, Playback, Library/View, and App/Help categories.
- Each action can have a primary and alternate physical-key binding. Existing
  Transcride shortcuts become defaults, including top-row and numeric-keypad
  alternates for percentage jumps.
- Settings gains searchable shortcut groups, two capture slots, clearing, conflict
  feedback, and independent reset controls for app shortcuts and global controls.
- Menus and the Keyboard Shortcuts window display the current live bindings instead
  of a separate hard-coded list.
- The event router attempts to protect text entry by yielding bare keys and editing
  commands when a text control, CodeMirror, composition session, search field, or
  shortcut-capture field owns input.
- Reserved macOS commands, structural keys, duplicates, and conflicts with global
  shortcuts are detected and left inactive rather than dispatched ambiguously.

### Quick Move and path coherence

The branch adds an Obsidian-style **Move Note** workflow, normally opened with
Option-M:

- A searchable picker lists Vault Root and eligible folders, with exact, prefix,
  substring, typo-tolerant, and abbreviation matching.
- The current parent is excluded, results have deterministic ordering, and the
  picker keeps keyboard selection stable as its query changes.
- Moving refuses to overwrite another entry and reports missing source,
  missing destination, collisions, and file-system failures as distinct cases.
- An edited note is supposed to finish its pending save before the picker opens.
- The move path attempts to update the visible vault snapshot, selected entry,
  transcription queue, active search results, search-index paths, Recently Deleted
  sidecars, and clip-edit history together.
- Existing context-menu and drag moves are routed through the same underlying move
  intent so they do not become independent mutation implementations.

### Folder browsing and speaker presentation

Two additional library behaviors are included:

- Selecting a folder can include entries from all descendant folders. This is on
  by default and can be disabled in General settings. Disabling it clears a
  selection that is no longer visible but does not change the destination for new
  recordings or imports.
- Entries with cached diarization can hide or restore speaker labels without
  retranscribing. The intended contract keeps speaker IDs and names in the cached
  Original, regenerates only an unforked Markdown projection, and leaves a
  hand-edited Markdown body untouched.

Speaker visibility is threaded through Markdown generation, word mapping, search,
export, vocabulary reapplication, transcription application, and workbench UI so
those surfaces are intended to agree about whether labels are visible.

### Replacement of the native transcript editor

The largest Milestone 9 change replaces the prior native transcript text views
with a CodeMirror 6 editor hosted inside a secured `WKWebView`.

The new editor is packaged as an offline TypeScript project under `EditorWeb`. Its
CodeMirror dependencies are pinned by an exact lockfile; a built JavaScript bundle,
HTML shell, license notices, tests, and a bundle-freshness check are committed to
the branch. Normal Xcode builds are intended to copy the checked-in bundle rather
than run npm or access the network. The Xcode project definition is changed to link
WebKit and embed these resources.

One reusable web editor is intended to serve three states:

- immutable Original transcript;
- read-only Edited view; and
- editable Edited mode.

The attempted workbench preserves separate Original and Edited selection/scroll
state, click-to-seek and speaker actions in Original, click-to-edit in Edited,
karaoke highlighting, search cues, copy-as-Markdown, the first-change fork, the
600 ms autosave delay, explicit Save, and undoing back to an unforked body.

### Markdown presentation and editing behavior

The CodeMirror layer attempts to turn the note into decorated Markdown source,
not WYSIWYG. Syntax characters remain visible while headings, emphasis,
strikethrough, lists, tasks, quotes, links, tables, rules, code, highlights,
callouts, Obsidian comments, tags, and wikilinks receive styling.

Unsupported or unsafe constructs—including embeds, images, raw HTML, Mermaid,
math, footnotes, file links, and relative links—are intended to remain visible and
inert. The web view should not execute or fetch them.

Editing additions include:

- continuation and exit behavior for lists, tasks, ordered lists, and quotes;
- list indent/outdent with Tab and Shift-Tab only when the selection is in a list;
- clickable and accessible task checkboxes that still modify the literal Markdown;
- contextual bold, italic, and Markdown-link commands;
- in-editor find in every mode and replace only during Edited editing;
- case, whole-word, regular-expression, next/previous, replace-one, and replace-all
  search behavior, with replace-all intended to be one undo step;
- app-wide font size, reading width, Edited alignment, and Focus Mode preferences;
- an `Aa` workbench control plus matching View menu and Editor settings controls;
- live light/dark appearance, increased-contrast, and reduced-motion updates; and
- spelling, native suggestions, contextual menus, Unicode input, IME, and dictation
  handling, while disabling automatic substitutions that could mutate Markdown.

### Existing links and tag-aware search

This branch does not attempt a full knowledge graph. It adds two smaller features:

- Existing `[[Title]]`, folder-qualified, and aliased wikilinks are parsed and can
  be opened inside Transcride when resolved. Duplicate titles are resolved
  deterministically. Unresolved links remain inert. Ordinary Markdown links are
  handed to macOS only for `http`, `https`, and `mailto`; all other destinations
  remain non-navigating.
- Obsidian-style tags are extracted from Markdown bodies and YAML tag lists. Tag
  syntax inside code, escaped text, and link destinations is excluded. Vault search
  gains a multi-select tag filter with OR behavior inside the tag group, AND
  behavior with existing filters, parent/descendant matching, and tag-only results.

No persistent backlink/tag index, tag-count pane, tag editor, link autocomplete,
automatic note creation, or rename-time link rewriting is included.

### Editor bridge, autosave, and recovery architecture

The native and web halves communicate through a new versioned, typed message
protocol. Messages carry a web-session identity, request identity, strict sequence,
method, and validated payload. Text edits cross the boundary as UTF-16 patch
batches; invalid or out-of-order data is supposed to trigger a full snapshot
instead of a guessed repair.

The ownership split is intended to be:

- CodeMirror owns the live text, selection, scroll position, composition state,
  search UI, and text undo/redo history.
- Swift owns the acknowledged text mirror, fork state, autosave scheduling, exact
  on-disk body revision, frontmatter-preserving writes, vault transitions, and
  recovery decisions.

New lifecycle coordination attempts to obtain an acknowledged full snapshot before
changing entries, layers, or vaults; before moving, renaming, duplicating, deleting,
or retranscribing the selected entry; before closing the workbench; and before
terminating the app. A generation-aware save queue is intended to prevent an older
autosave from committing after a newer edit or destination change.

If the web process crashes, the host attempts to rebuild it from the last
acknowledged native buffer, restore view state, and report any window in which
unacknowledged keystrokes may have been lost.

### External edits and conflict recovery

The old body-save path is replaced with exact compare-and-save behavior:

- Body revisions are hashes of the exact UTF-8 bytes, without normalizing
  whitespace or line endings.
- A frontmatter-only external edit is preserved while the local body is saved.
- If only the external body changed, the editor is intended to reload it while
  preserving an approximate view position.
- Non-overlapping local and external line changes are intended to merge
  automatically while keeping local undo meaningful.
- Overlapping changes freeze editing and create a recovery draft in Application
  Support. A conflict sheet offers **Keep Mine**, **Keep External**, or **Keep
  Both** per hunk, without writing conflict-marker text into the note.
- Recovery records are intended to survive cancellation, save failure, relaunch,
  and further disk changes, and to be deleted only after a durable resolved save.

Atomic file replacement is also strengthened with file and directory syncing so a
successful save is intended to represent durable storage rather than only a rename
in the operating-system cache.

### Main-workbench and application integration

Integrating the editor and Milestone 8 work causes broad changes outside the new
files:

- `AppModel` gains editor lifecycle ownership, generation-aware selection and vault
  transitions, app-command dispatch, Quick Move state, tag-only searching,
  recursive-folder preferences, and speaker-presentation state.
- Entry-list and sidebar selection no longer mutate bindings directly; selection
  requests pass through editor persistence barriers.
- The transcription queue asks the mounted editor for a safe mutation boundary
  before applying a finished transcript or auto-renaming an entry.
- Vault writes gain expected-revision comparisons, exact-body conflict results,
  path-repoint support, and speaker-presentation updates.
- Search metadata gains tags and a tag-only match type. The scanner extracts tags
  while rebuilding the in-memory vault snapshot.
- The menu bar, app menus, settings, About window, keyboard help, entry detail,
  entry list, sidebar, search overlay, and transcript toolbar are all changed to
  participate in the new command or editor state.

### Tests, build inputs, and documentation

The branch adds three layers of automated test code:

- JavaScript tests for the typed bridge, Markdown decorations, smart editing,
  search/replace, exact mixed line endings, composition, task history, focus mode,
  process recovery, and 10,000-word editing behavior.
- Swift Core tests for bridge validation, UTF-16 patch safety, exact revisions,
  wikilink and tag parsing, three-way merge and recovery records, preferences,
  app shortcuts, and Quick Move.
- App-hosted integration tests for a real WebKit editor, lifecycle barriers,
  compare-and-save races, external merges, Quick Move coordination, shortcut
  dispatch, and speaker toggling.

Existing tests are also expanded around frontmatter line endings, global recording,
search filters, speaker presentation, transcription application, trash/history
repointing, and vault scanning.

The build definition embeds the offline editor bundle and links WebKit. The ignore
rules add repository-local Xcode Derived Data. Project-state, milestone, Obsidian
compatibility, and master requirement documents are rewritten to describe the new
waiver, the broader Milestone 8 work, and the narrower Milestone 9 roadmap.

## What this branch deliberately does not contain

Despite the size of the change, this archive does not add a WYSIWYG or separate
reading mode, outline panel, backlinks, Linked Mentions, wikilink autocomplete,
automatic creation of unresolved notes, inbound-link updates on rename, tag pane,
tag counts, tag-writing UI, or a layer-comparison diff. Those features were removed
from the branch's rewritten Milestone 9 scope rather than left half implemented.

It also does not change the product into a cloud editor. Vault files remain the
intended source of truth, model/editor assets are intended to stay local, and the
web editor is not supposed to receive arbitrary file-system or network access.

## Validation and known condition

This snapshot must be treated as broken and unverified even though it contains a
large amount of test code.

- The combined archive was not accepted through the Milestone 8 or Milestone 9
  human checklists.
- No `milestone-8` or `milestone-9` verified tag was created.
- Historical notes inside the branch mention successful Milestone 8 Core and
  app-hosted test runs before the editor rewrite. They do not establish that this
  final combined snapshot builds, passes, or behaves correctly.
- The overnight result was observed to be messy, difficult to maintain, and broken
  in multiple places. No claim in this README should be interpreted as proof that
  an attempted feature works end to end.
- The source snapshot was preserved before `main` was restored specifically so
  individual ideas, tests, algorithms, and contracts could be consulted later
  without making this branch the basis of ongoing development.

## Sensible salvage boundaries

If code is reused later, it should be extracted in small, independently reviewed
pieces rather than merging this branch wholesale. The clearest candidate boundaries
are:

- the pure Quick Move ranking and destination model;
- the physical-key shortcut types and validation rules;
- tag and wikilink parsing tests;
- exact UTF-16 patch validation and the documented bridge envelope;
- exact-body revision and three-way merge tests;
- the offline CodeMirror packaging and bundle-freshness approach;
- focused Markdown decoration or editing behaviors; and
- individual integration tests that express a still-desired lifecycle invariant.

Each candidate should be compared against current `main`, rewritten where needed,
and proven independently before adoption. The archive branch itself should remain
a read-only historical reference.

## Original v1.2 project overview

Transcride is a native, local-first macOS voice recorder and transcription
workbench. Record or import audio, transcribe it on-device, edit the result as
Markdown, search the whole vault, and delete the audio when the text is all you
want to keep.

Version 1.2 is built for Apple silicon and macOS 15 or later.

## Mac compatibility

Transcride 1.2 is compatible with **every Apple-silicon M-series Mac (M1 or
newer)** running macOS 15 or later, including all M-series MacBook Air,
MacBook Pro, Mac mini, iMac, Mac Studio, and Mac Pro models. The downloadable
beta app is a native `arm64` build. Intel Macs are not supported.

## What it does

- Records compressed AAC or lossless ALAC audio and imports common audio/video formats.
- Extends an existing recording safely and keeps its pre-extension version recoverable.
- Replaces an exact region with the best of multiple takes while preserving the
  recording's total duration and keeping prior versions recoverable.
- Lets each entry detect silence from the real audio level or timed speech gaps;
  the speech option keeps Skip Silence useful in noisy rooms.
- Compresses recordings with that same per-entry mode while keeping the
  pre-compression version recoverable.
- Transcribes locally with Parakeet, WhisperKit, or Apple Speech where available.
- Shows live transcription while recording, with a distraction-free Zen mode.
- Keeps an immutable timed original beside an editable Markdown note.
- Synchronizes playback, waveform scrubbing, transcript highlighting, and search hits.
- Supports speaker detection and names, trimming, favorites, duplication, sorting, and filtered search.
- Exports clean Markdown, shares audio through macOS, and opens compatible vaults directly in Obsidian.
- Moves entries and audio to Recently Deleted instead of destroying them immediately.

No account, cloud service, telemetry, or proprietary vault database is required.
Notes, audio, transcript JSON, and waveform caches remain ordinary files in a
folder the user chooses.

## Build from source

Requirements:

- macOS 15 or later on Apple silicon
- Xcode with the macOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
xcodegen generate
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project Transcride.xcodeproj -scheme Transcride \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

`Transcride.xcodeproj` is generated from `project.yml`; make project changes in
the YAML file and regenerate rather than editing the project by hand.

The project uses FluidAudio and WhisperKit through Swift Package Manager. Model
downloads happen only when the user requests them. Apple Speech availability is
determined by the running macOS version.

## Data format

Each entry is a timestamped folder containing a Markdown note and, while
retained, an audio file. Timed engine output is stored in
`transcript.original.json`; `waveform.json` is a disposable cache. The search
database lives outside the vault and can be rebuilt from the plain files.
The per-entry silence source is ordinary line-preserving frontmatter:
`silence_detection: waveform` or `silence_detection: speech`.

See [PROJECT-STATE.md](PROJECT-STATE.md) for the architecture, known limitations,
and contributor handoff. Product intent and requirement history live in
[master-prd-backup.md](master-prd-backup.md) and the milestone PRDs.

## Release status

Milestones 1–7 and the v1.2 acceptance workflow were human-verified through
2026-07-12. The repository declares version `1.2.0` build `3`.

Binary distribution still requires a Developer ID Application certificate and
Apple notarization credentials; local builds are ad-hoc signed for development.
