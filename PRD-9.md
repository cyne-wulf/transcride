# PRD-9 — Milestone 9: Editor-First CodeMirror Markdown Workbench

> **One-time implementation authorization — 2026-07-17:** The human explicitly
> waived this PRD's prior Milestone 8 verification and commit prerequisites for the
> Milestone 8 → 9 transition only. Milestone 8 implementation is complete in the
> current worktree but remains unverified; its human checklist was skipped, every
> box remains unchecked, and no `milestone-8` verified tag may be created or
> claimed. Begin from the exact partially uncommitted worktree described in
> `PRD-9-start-here.md`, then read [PROJECT-STATE.md](PROJECT-STATE.md) and
> [master-prd-backup.md](master-prd-backup.md) and re-ground this PRD against the
> implemented editor, shortcut, search, vault, and lifecycle interfaces before
> changing source code. Normal Milestone 9 verification and the Milestone 9 → 10
> gate remain fully in force.

## Goal

Make the transcript pane an exceptionally polished Markdown authoring surface while
keeping Transcride's native shell, plain-file vault, immutable Original, and explicit
Edited-layer lifecycle intact. One locally bundled CodeMirror 6 workbench presents
Original, Edited view, and Edited editing as decorated source: Markdown syntax is
always visible, the file on disk stays ordinary Markdown, and there is no separate
WYSIWYG or Reading mode.

This milestone is editor-first. It does not add permanent navigation panels,
knowledge-graph features, or another way to browse the vault.

## Scope

**In:** a secured, offline CodeMirror 6 host; CommonMark/GFM and selected
Obsidian-style source decorations; Original/Edited behavior parity; smart lists and
tasks; contextual formatting commands; in-editor find/replace; typography,
alignment, width, and Focus Mode preferences; navigation of existing web and
wikilinks; body/frontmatter tag extraction and vault-search filtering; snapshot-safe
autosave; exact-body compare-and-save; external-edit merging and conflict recovery;
accessibility, input-method, security, and performance hardening.

**Permanently removed from the roadmap:** Outline; backlinks/Linked Mentions;
wikilink autocomplete; creating a note from an unresolved link; rewriting inbound
links during rename; a Transcride tag pane, tag-count browser, or tag-writing UI;
and an Original-versus-Edited layer diff. These are not deferred Milestone 9 items.

**Preserve as visible, inert source rather than render or execute:** embeds, images,
math, Mermaid, footnotes, raw HTML, file/relative links, heading and block fragments,
and other unsupported extensions. Preservation remains mandatory even where a
visual preview is not supplied.

**Still out:** AI features; cloud or collaboration; telemetry; runtime CDN or
editor network access; a vault schema migration; and broad app-wide appearance work.

## Product requirements

### One decorated-source workbench

- Replace both transcript `NSTextView` implementations with one reusable
  CodeMirror-backed host. Mount one editor per workbench and reconfigure it as:
  **Original read-only**, **Edited view**, or **Edited editing**. This is not a
  process-global singleton and must remain safe if the app later supports multiple
  workbench windows.
- Show only `FrontmatterDocument.body`. Frontmatter remains hidden from the editor
  and must continue to round-trip through the line-preserving native parser.
- Preserve separate in-memory selection and scroll state for Original and Edited
  while an entry remains mounted. Reconfiguring Edited view to editing and back must
  preserve selection, scroll, and CodeMirror history.
- Preserve the existing layer lifecycle exactly: Edit/Save remains explicit;
  entering Edit alone does not fork; the first real body change creates the
  `hand_edited` fork; autosave remains debounced by 600 ms; Save remains explicit;
  and a session that began unforked can undo to its exact starting body and Save to
  clear the fork and return to Original.
- Original is immutable through every path. A normal Original click seeks the
  spoken word or invokes the existing speaker-label action. A normal Edited-view
  click enters editing at that source position. Command-clicking a navigable link
  takes precedence in either layer, and clicking an Edited task marker toggles it
  without entering general text editing.
- Preserve karaoke, click-to-seek, speaker actions, in-note search cues, Edited
  prefix mapping, copy-as-Markdown, and all existing UTF-16 coordinate contracts.
  Decorations and widgets must never remove, replace, or renumber source text.

### Markdown rendering contract

- Style CommonMark/GFM headings, emphasis, strikethrough, unordered and ordered
  lists, tasks, blockquotes, Markdown links, tables, thematic rules, inline code,
  and fenced code. Add visible-source styling for Obsidian-style `==highlights==`,
  callouts, `%%comments%%`, tags, and wikilinks. Comment delimiters and contents
  remain visible and styled; they are never executed or removed.
- Markdown delimiters always remain present. They may be dimmed, but cursor-proximity
  hiding, WYSIWYG substitution, and a separate preview DOM are out of scope.
- Unsupported embeds, images, math, Mermaid, footnotes, and raw HTML remain intact
  as visible source and are never executed, fetched, or previewed.
- Prose may be centered according to the mode's alignment rules. Structured blocks
  — lists, tasks, quotes, fenced code, and tables — are always left-aligned so their
  structure remains readable.
- Styling must be incremental and viewport-aware. Typing, playback decorations,
  search cues, and focus changes must not trigger whole-document parsing or styling
  work on the hot path.

### Smart editing, formatting, and text services

- Use first-party CodeMirror Markdown list continuation and exit behavior. Return
  continues `- `, ordered-list, task, and `> ` prefixes; Return on an empty item
  exits the block.
- Tab and Shift-Tab indent or outdent only when every active selection is inside a
  list item. Elsewhere, Tab leaves the editor in normal macOS keyboard-navigation
  order.
- Render literal `[ ]` and `[x]` task markers as visible, dimmed source that also
  exposes an accessible checkbox control labelled by the task text. Tasks are
  interactive in Edited view and Edited editing, immutable in Original, and update
  the literal marker through one ordinary CodeMirror transaction, fork, and
  autosave path.
- An Edited-view task toggle does not enable general typing. After the toggle, the
  editor retains focus and owns Undo/Redo until focus leaves so Command-Z can reverse
  it; ordinary read-only transcript focus otherwise retains the existing application
  shortcut behavior.
- While Edited editing owns input, Command-B and Command-I toggle bold and italic
  delimiters around the selection or current word. A collapsed selection inserts a
  delimiter pair with the caret inside; a selection already wrapped by the same
  delimiters is unwrapped.
- While Edited editing owns input, Command-K wraps selected text as `[text]()` and
  places the caret in the destination, inserts `[]()` for an empty selection, or
  unwraps the current Markdown link to its visible label. Outside editable focus,
  these editor commands do not intercept application commands; Command-I continues
  to mean Show Info.
- Enable spelling, native spelling suggestions, and contextual menus. Disable smart
  quotes, smart dashes, autocorrection, and automatic text replacement. IME,
  dictation, marked-text composition, and Unicode input must produce a single
  coherent editor transaction rather than intermediate corrupt saves.

### In-surface find and replace

- Command-F opens CodeMirror's in-surface search panel in all three modes. It shows
  match count and controls for case sensitivity, whole-word matching, regular
  expressions, next, and previous.
- Option-Command-F, replace-one, and replace-all are available only while Edited
  editing is active. They do not silently enter editing and are unavailable in
  Original and Edited view.
- Replace-all is one CodeMirror transaction and one Undo step. Search and replace
  fields explicitly own text input so app-local bare-key recording/playback
  shortcuts cannot fire while the user types in them.

### Typography, alignment, and Focus Mode

- Default prose typography is the macOS system font at 16 points with a 1.55 line
  height. Inline and fenced code use the system monospaced font.
- Font size ranges from 12 through 28 points. Command-Plus and Command-Minus adjust
  it; Command-0 restores 16 points.
- Width presets are **Narrow** (620 points), **Wide** (800 points, default), and
  **Full** (the available pane width with normal editor insets).
- Original prose is always centered. Edited prose defaults to centered and has one
  app-wide **Center / Left** preference that applies to Edited view and editing.
  Structured blocks remain left-aligned under both settings.
- Add one `Aa` toolbar popover for font size, width, Edited alignment, and Focus
  Mode. Mirror the same commands and current values in the View menu and a new
  Editor settings pane; do not add a permanent editor sidebar.
- Focus Mode is an app-wide persisted preference. During Edited editing it dims
  every Markdown block except the caret's current paragraph, heading, list item,
  quote, or fenced-code block. Original and Edited view have no editable caret, so
  they do not dim content; the preference remains enabled and resumes on Edit.
- Store all editor preferences in app-wide `UserDefaults` and apply changes live.

### Existing-link navigation only

- Recognize `[[Title]]`, `[[Folder/Title]]`, and `[[Title|alias]]` against the
  current vault snapshot. Matching is Unicode case-insensitive; an alias changes
  display text only.
- Folder qualification disambiguates when it identifies one matching entry.
  Otherwise choose the most recently modified title match and show an ambiguity
  tooltip. If modification times tie, choose the naturally sorted normalized
  relative path so resolution is deterministic.
- Unresolved wikilinks use a dotted treatment and remain inert. There is no
  autocomplete, note creation, backlink/Linked Mentions UI, inbound-link rewrite,
  rename blocking, or persistent link index. Renaming a target may therefore leave
  existing wikilinks unresolved.
- Command-click and Command-Return open a resolved wikilink inside Transcride.
  Allowlisted `http`, `https`, and `mailto` Markdown links are handed to macOS by
  native code. The web view never navigates itself.
- File URLs, relative Markdown links, heading/block fragments, embeds, and every
  other scheme are styled as source but remain non-navigating.

### Tags and vault-search filtering

- Parse tags from the persisted Markdown body (the Edited body when forked,
  otherwise the unforked Markdown body) and from inline or block YAML `tags` lists.
  Never scan timed Original JSON for tags and never write or normalize a user's tag
  syntax in this milestone.
- Follow current Obsidian tag rules: Unicode-aware and case-insensitive; letters,
  digits, `_`, `-`, and `/` nesting are supported; a tag must contain at least one
  non-numeric character. Exclude escaped tag markers, inline/fenced code, and link
  destinations. See [Obsidian tags](https://obsidian.md/help/tags).
- Store a canonical case-folded tag set on entry/search metadata while preserving a
  display spelling. Do not add a separate link/tag knowledge index or tag-count
  table; tag-only queries enumerate the current vault metadata snapshot.
- Extend the existing vault-search filter with a multi-select tag menu. Multiple
  selected tags use OR semantics. Selecting a parent matches that exact tag and its
  `/` descendants. The tag group combines with every other filter using the
  existing cross-filter AND behavior.
- Tag filtering works with an empty text query and with exact or fuzzy text. Add a
  metadata/tag-only result kind so a matching entry can appear without inventing a
  text snippet. There is no tag browser, count pane, or tag-writing UI.

## Architecture and interfaces

### Reproducible local web package

- Add `EditorWeb/` with TypeScript sources, Vitest/jsdom tests, an exact
  `package-lock.json`, and a checked-in minified `dist` bundle. Normal Xcode builds
  never invoke npm and never access the network.
- Pin only the required first-party packages: `@codemirror/state` 6.7.1,
  `@codemirror/view` 6.43.6, `@codemirror/commands` 6.10.4,
  `@codemirror/search` 6.7.1, `@codemirror/language` 6.12.4,
  `@codemirror/lang-markdown` 6.5.1, and `@lezer/markdown` 1.7.2. Pin
  TypeScript 7.0.2, esbuild 0.28.1, Vitest 4.1.10, and jsdom 29.1.1.
- Do not add the `basicSetup` umbrella, autocomplete, or merge packages. Prefer
  individual CodeMirror extensions and first-party commands. Follow
  [CodeMirror's bundling guidance](https://codemirror.net/examples/bundle/) and
  [reference](https://codemirror.net/docs/ref/).
- Commit third-party notices. Add a developer/CI freshness check that performs an
  exact-lock install, rebuilds in a temporary location, and fails when checked-in
  `dist` differs; the check is separate from normal Xcode compilation.
- Add the bundled `dist` folder as an explicit XcodeGen resource, link WebKit, and
  regenerate the project rather than editing the generated Xcode project.

### Secured WebKit host

- Use a nonpersistent `WKWebsiteDataStore` and `loadFileURL` with read access scoped
  to the exact bundled `dist` directory. The editor receives no vault path or
  general filesystem access.
- Use a strict CSP with no remote origins. Permit only the packaged script/style
  behavior required by CodeMirror; set network connections, media, frames, objects,
  forms, and base-URL changes to none.
- Deny camera, microphone, `getUserMedia`, and every other WebKit permission request
  from the editor host even though the native Transcride process may hold microphone
  permission for recording.
- Cancel all page navigation, redirects, downloads, and new-window creation.
  Validated link activations cross the native bridge and are opened only by the
  allowlist above. Enable Web Inspector only in Debug builds.

### Typed bridge and ownership

- Every bridge message uses a typed envelope containing `protocolVersion: 1`,
  `sessionID`, `requestID`, `sequence`, `method`, and a method-specific payload.
  Reject unsupported versions, stale sessions, duplicate/out-of-order sequences,
  unknown methods, invalid ranges, and messages not sent by the active editor's
  main frame and bundled file origin.
- JavaScript-to-Swift requests use `WKScriptMessageHandlerWithReply`. Swift-to-
  JavaScript calls use argument-based `callAsyncJavaScript`; note text is never
  interpolated into executable JavaScript. See [Apple's reply bridge](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply).
- User edits cross as ordered UTF-16 patch batches with `baseLength` and sequence.
  Every `{from,to,insert}` range refers to the same pre-transaction document, is
  half-open, sorted, and non-overlapping. Swift validates the full batch and applies
  it from the highest range to the lowest. Any mismatch requests a full snapshot
  resynchronization rather than guessing.
- CodeMirror owns selection, scroll, composition, and text Undo/Redo history. Swift
  owns the acknowledged mirrored body, baseline revision, fork state, 600 ms
  autosave, frontmatter-preserving file writes, vault state, and recovery policy.
- Native document/configuration messages suppress bridge echo. Pure configuration
  changes do not enter text history. Clean external replacement resets history;
  non-overlapping external merge portions are applied outside history while mapped
  local transactions remain undoable.
- Define typed commands for readiness, patches, full snapshots, focus/input
  ownership, link/click actions, view-state capture, configuration, document/mode
  replacement, native playback/search decorations, freeze/recovery, and editor
  command execution. All request/reply paths are session- and sequence-checked.

### Snapshot and process lifecycle

- Require an acknowledged full-document snapshot before explicit Save, entry or
  layer changes, vault changes, workbench teardown, and application termination.
  Retain the web view until asynchronous snapshot and persistence work finishes.
- If the web content process terminates, rebuild from the last acknowledged native
  buffer and restore mode/configuration/view state. Report clearly when an
  unacknowledged input window means text may have been lost; never claim it was
  saved.
- Preserve approximate selection and scroll through clean external reloads and web
  process recovery. Clamp all restored UTF-16 positions to valid boundaries.

### Native focus, commands, and Core contracts

- Extend the app's shortcut router with explicit editor-input ownership. Editable
  CodeMirror content, composition, and its search/replace fields suppress app-local
  bare-key recording/playback commands and route Undo/Redo through CodeMirror.
  Ordinary read-only transcript focus retains existing application shortcuts.
- Feed live editor readiness, mode, focus ownership, and command availability into
  the existing menu/command state. Extend the handoff-documented Milestone 8
  shortcut catalog in the current worktree;
  do not create a second hard-coded shortcut system.
- Add pure Core contracts for bridge envelopes, UTF-16 patch validation/application,
  wikilink parsing/resolution, tag extraction/canonicalization, exact body revisions,
  and line-based three-way body merging so they compile in the existing unit-test
  target.
- Extend `Entry` with canonical tags, `VaultSearchFilters` with selected tags, and
  search results with a metadata/tag-only kind. Tags may ride on the current
  rebuildable search metadata, but no independent link/tag index is introduced.

### Exact-body saves and simultaneous external edits

- Define the expected body revision as SHA-256 over the exact body UTF-8 bytes, with
  no whitespace or line-ending normalization. Before each atomic body replacement,
  re-read the current file and compare its body revision with the expected baseline.
- A frontmatter-only external edit keeps the same body revision. The save path
  therefore uses the newly read `FrontmatterDocument`, replaces only the body and
  owned fork field, and preserves every current unknown/frontmatter line.
- If the local buffer is clean and the external body changed, load the external
  body, preserve approximate selection/scroll, establish its revision as the new
  baseline, and reset text history.
- If local and external bodies are both dirty but their line-based changes from the
  common base do not overlap, perform a deterministic three-way merge. Apply the
  external portions outside CodeMirror history, map and preserve local Undo, then
  compare-and-save the merged body. If the disk revision changes again, repeat the
  comparison rather than overwriting it.
- If changes overlap, pause autosave, freeze editing, and persist a recovery record
  under Application Support containing entry identity/path, base, Mine, External,
  revisions, and timestamp. Present a per-hunk sheet with **Mine**, **External**,
  and **Keep Both**. Keep Both places Mine before External and inserts only the
  minimum newline needed to prevent concatenation; it never writes conflict labels
  or markers.
- Applying conflict choices establishes a new baseline, clears stale text history,
  saves through the same exact-revision path, and deletes the recovery record only
  after the resolved body is durably saved. Canceling or a failed save retains the
  recovery record and never mutates the vault file.

## Decisions already made — do not relitigate

- CodeMirror 6 in a locally bundled, secured `WKWebView` is the editor engine.
- The UI is decorated source with permanently visible Markdown syntax, not WYSIWYG
  and not a separate Reading mode.
- One reusable host serves Original, Edited view, and Edited editing while Swift
  remains authoritative for vault I/O and lifecycle state.
- The editor shows the body only; line-preserved frontmatter and the Markdown body
  remain the sole durable note content.
- Existing links may be opened, but Transcride does not autocomplete, create,
  backlink, rewrite, or persistently index them.
- Tags are read for decoration and search filtering only. There is no tag-writing or
  tag-browser surface.
- Outline, Linked Mentions/backlinks, unresolved-note creation, inbound rename
  rewriting, tag panes/counts, and layer diff are removed rather than deferred.
- CodeMirror owns text history; Swift owns fork/autosave/disk state. Snapshot
  barriers and exact-body compare-and-save are required boundaries.
- Editor preferences are app-wide. No vault schema migration, telemetry, CDN, or
  editor network access is introduced.

## Implementation sequence under the authorization

1. Re-read `PRD-9-start-here.md` and the implemented Milestone 8 editor, shortcuts,
   search, settings, and vault lifecycle. Reconcile interface names without changing
   this product boundary.
2. Add the reproducible `EditorWeb` package, checked-in bundle, secured WebKit host,
   typed bridge, local resource packaging, CSP/navigation policy, snapshot barriers,
   and real-`WKWebView` integration harness.
3. Reach behavioral parity before adding polish: all three modes, fork/autosave/Save,
   Undo/Redo, copy, find navigation, karaoke, seek, speaker actions, external reload,
   and native command routing.
4. Add Markdown/GFM/Obsidian decorations, typography/alignment/width preferences,
   Focus Mode, smart lists, tasks, formatting commands, CodeMirror search/replace,
   existing-link navigation, and tag filtering.
5. Add exact compare-and-save, three-way external merge/conflict recovery,
   accessibility/input hardening, offline/security checks, and performance
   instrumentation.
6. Regenerate the Xcode project, run web and Swift tests, build, install the verified
   app at `/Applications/Transcride.app`, and conduct the checklist below one item at
   a time. Only after human confirmation update project state, write the Milestone 10
   handoff, commit green checklist work, and tag `milestone-9`.

## Automated acceptance

- **JavaScript:** transaction serialization; incremental decoration invalidation;
  every supported syntax and visible delimiter; inert unsupported syntax; list
  continuation/exit/indent; task accessibility/toggle/Undo; formatting commands;
  all search modes; one-step replace-all Undo; focus-block detection; live preference
  reconfiguration; link actions; and UTF-16/Unicode positions.
- **Swift Core:** bridge version/session/sequence rejection; multi-range UTF-16
  patches including emoji; fork restoration; body and YAML tag rules; nested OR
  filtering; wikilink ambiguity/folder qualification/tie-breaking; exact
  compare-and-save; three-way merge and overlap detection; and recovery-draft
  lifecycle.
- **App integration with a real `WKWebView`:** offline bundled handshake;
  CSP/navigation blocking; editable/read-only enforcement; snapshot barriers;
  process-termination recovery; focus and shortcut ownership; native Edit-menu
  behavior; search/replace; task changes; and live appearance/preferences.
- **Performance:** on the development Mac, 200 edits in the middle of a 10,000-word
  note have p95 input-to-visual-update latency below 16.7 ms and no stall above
  50 ms. Playback highlighting and bridge traffic do not perform whole-document
  work.
- The web suite and final `xcodebuild test` pass without regressions. The editor
  launches and functions with networking unavailable.

## Verification checklist (human-run)

**Interactive, one item at a time, with human confirmation.** Fix and re-run any
failed item plus affected previously passed items before moving on.

- [ ] In one note, exercise every supported CommonMark/GFM and selected Obsidian
  decoration. Delimiters remain visible, unsupported constructs remain inert source,
  and the `.md` body on disk exactly matches the Markdown typed in the editor with
  no decoration-generated markup.
- [ ] Verify Original, Edited view, and Edited editing click behavior: seek and
  speaker actions in Original, click-to-edit in Edited, Command-link precedence, and
  task toggling without unintended mode changes.
- [ ] Enter Edit without typing, then make and undo changes around the 600 ms
  autosave boundary. Confirm first-change fork, explicit Save, and exact-body
  undo-back-to-unforked behavior remain intact.
- [ ] Run the 200-edit, 10,000-word performance fixture and meet p95 < 16.7 ms with
  no stall > 50 ms while playback decoration updates continue.
- [ ] Verify list/quote/task continuation and empty-item exit. Tab/Shift-Tab nest
  list items, while Tab outside a list leaves the editor.
- [ ] With VoiceOver and keyboard-only navigation, toggle tasks in Edited view and
  editing, Undo each toggle once, and confirm Original tasks cannot change.
- [ ] Verify Command-B/I/K wrapping, unwrapping, and collapsed-caret behavior only
  during Edited editing; outside it, Command-I still opens Show Info.
- [ ] Use Command-F in every mode with case, whole-word, regex, counts, and
  navigation. Confirm replacement exists only in active editing and one Command-Z
  reverses replace-all.
- [ ] Verify 16-point/1.55/Wide defaults, Narrow/Wide/Full widths, 12–28 sizing,
  Original centering, Edited Center/Left preference, and left-aligned structured
  blocks. Confirm `Aa`, View menu, and Editor settings stay synchronized across
  relaunch.
- [ ] Enable Focus Mode, move the caret through paragraphs, headings, list items,
  quotes, and fenced code, and confirm block-level dimming and persisted state.
- [ ] Exercise resolved, folder-qualified, aliased, duplicate/ambiguous, tied, and
  unresolved wikilinks plus `http`, `https`, and `mailto` links. Confirm only the
  allowlist navigates and file/relative/fragment/embed targets remain inert.
- [ ] Exercise body tags, inline and block YAML tags, Unicode, nesting, exclusions,
  parent matching, multi-tag OR, tag-only search, and tags combined with every
  current filter.
- [ ] Make clean, frontmatter-only, non-overlapping body, and overlapping body edits
  externally. Confirm reload/merge behavior, per-hunk conflict choices, no conflict
  markers, and recovery-record retention/deletion rules.
- [ ] Trigger entry/layer/vault transitions and simulated web-process termination
  around unsaved input. Confirm snapshot barriers, honest recovery reporting, and no
  silent last-keystroke loss.
- [ ] Regression-test karaoke, click-to-seek, search cueing, speaker rename, Copy as
  Markdown, playback/audio commands, and an external Obsidian round-trip including
  unknown frontmatter, callouts, highlights, comments, and unsupported syntax.
- [ ] Verify VoiceOver, full keyboard access, IME, dictation, spelling suggestions,
  contextual menus, disabled substitutions, Increase Contrast, and Reduce Motion.
- [ ] Launch offline, verify CSP/navigation blocking, run the web tests, and finish
  with a passing `xcodebuild test` and installed-app smoke test.

## Handoff (required after the checklist is verified)

Write **`PRD-10-start-here.md`** and update **`PROJECT-STATE.md`** with the final
state summary; build/run/test commands; changed file map; exact web package,
lockfile, bundle-freshness, notices, and Xcode resource contract; secured WebKit/CSP
policy; typed bridge and UTF-16 transaction protocol; snapshot, autosave, fork,
Undo, and process-recovery ownership; Markdown support boundary; wikilink resolver;
tag parsing/filtering contract; exact-body save and three-way conflict-recovery
architecture; editor preferences and command integration; accessibility/input
results; measured performance; deviations; and known issues.

The handoff must not choose a summarization model for Milestone 10 without measured
license, context-window, disk, and peak-memory evidence.
