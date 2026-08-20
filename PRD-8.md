# PRD-8 — Milestone 8: Global Recording Controls

> **Before starting:** read [PROJECT-STATE.md](PROJECT-STATE.md) and `PRD-8-start-here.md`. **Do not start until the human confirms Milestone 7 is verified.** Reuse the existing `AppModel` recording intents and `RecorderService`; global controls are another input surface over the same state machine, not a second recorder. Crash safety from Milestone 6 applies unchanged to recordings started outside the focused app.

## Goal

Let the user control Transcride from any app using configurable system-wide keybinds. Without bringing Transcride to the front, the user can start a new recording, pause or resume it, and stop and save it. A small floating, draggable indicator appears while Transcride is not focused so recording state is always visible.

## Scope

**In:** keybinds settings/menu; configurable global shortcuts; start, pause/resume, and stop-and-save commands; conflict and availability handling; unfocused/minimized/hidden operation; floating draggable status indicator; recording timer and state animation; multi-display/Space behavior; accessibility; launch/session persistence.

**Out:** listening while Transcride is not running; a privileged helper or login daemon; global playback controls; voice commands; media-key interception; automatic recording based on other apps; uploading or remote control; arbitrary macro scripting.

## Requirements

### Keybinds menu (GLB-1)

- Add a dedicated **Keybinds** pane in Settings and keep Help → Keyboard Shortcuts as the readable reference. The Settings pane is where the user enables, disables, records, changes, and resets global shortcuts.
- Provide two global actions:
  1. **Start / Stop & Save Recording**
  2. **Pause / Resume Recording**
- Ship simple defaults: **⌥R** starts a new recording while idle and stops and saves the active recording; **⌥P** pauses or resumes. These are defaults only—the user may clear or replace either binding.
- Shortcut capture requires at least one non-Shift modifier and rejects a modifier-only chord, plain typing key, or duplicate assignment. Show the recorded chord in standard macOS glyph order.
- Detect registration failures and likely conflicts. A shortcut that could not be registered is visibly marked and must not appear enabled. Never silently steal a chord from another application.
- Include **Enable Global Controls**, **Show Transcride in menu bar**, **Show indicator while Transcride is in the background**, a post-recording visibility duration from Quick through Never (10 minutes by default), and **Reset to Defaults** controls. Settings persist across relaunch. The menu-bar item is shown by default and can also hide itself persistently.
- The native menu-bar item shows honest live recording state and elapsed time; Start/Stop & Save and Pause/Resume controls with their current global shortcut assignments; Open Transcride; Settings; Hide Menu Bar Item; and Quit. Its clicked controls remain usable when global shortcuts are disabled and call the same serialized `AppModel` intents.
- The existing in-app shortcuts continue to work. The menu bar and Keyboard Shortcuts window show both local and global chords without implying that a local bare-key shortcut works outside Transcride or registering a duplicate menu key equivalent.

### System-wide shortcut behavior (GLB-2)

- Global keybinds work while Transcride is running but unfocused, hidden, minimized, or on another Space. They do not require the main window to become key or move Spaces.
- Use the macOS global-hotkey registration mechanism, not a broad keystroke event tap or keylogger. The feature should not request Accessibility permission merely to register explicit shortcut chords.
- Registration is centralized in one `GlobalShortcutService`. It emits typed actions into `AppModel` on the main actor; it never manipulates `RecorderService` or vault files directly.
- Register shortcuts only after preferences load, and unregister/re-register atomically when bindings change. Remove registrations on shutdown. Multiple windows or scenes must never register duplicates.
- Secure input, system-reserved chords, or another app may prevent delivery. Surface registration status in Settings and keep in-app controls available.

### Recording command semantics (GLB-3)

- **Start / Stop & Save Recording** uses the same intents as the main recording controls. While idle it starts a new recording in the last valid selected folder when available, otherwise the vault root; while recording or paused it stops and saves. It never extends the currently selected entry.
- Start is ignored when a recording is already active, accompanied by state feedback rather than a second recording. It is unavailable without an open writable vault, microphone permission, or usable input device.
- The first global Start may trigger the standard macOS microphone permission prompt. If setup or permission requires foreground interaction, activate Transcride and show the exact required step; do not pretend recording began.
- **Pause / Resume** is one state-dependent binding: recording → paused, paused → recording. When idle or finalizing it performs no destructive action and the indicator gives brief unavailable feedback.
- The active-state behavior of **Start / Stop & Save** stops capture, finalizes the file, persists the transcription queue item, and then reports Finished/Recording Saved. It is not a discard command.
- Commands are serialized so rapid or repeated key presses cannot create two entries, double-stop, resume during finalization, or enqueue transcription twice.
- A globally started recording has every normal guarantee: selected quality/microphone, live capture safety, pause/resume, Milestone 6 crash recovery, waveform generation, plain vault files, and automatic transcription.

## Floating recording indicator

### Window and placement (GLB-4)

- When global controls and the background indicator are enabled, show a compact floating status panel whenever Transcride is not the active application. Hide it when Transcride becomes active because the normal recorder UI already shows state.
- The panel is draggable from its full background, does not steal keyboard focus, stays above ordinary application windows, and follows the user across Spaces. It must coexist with full-screen apps without forcing Transcride's main window forward.
- Remember its position. Store a screen-relative anchor so it returns sensibly after resolution, scale, display arrangement, or monitor changes. Clamp it fully onscreen and provide **Reset Indicator Position** in Keybinds settings.
- The panel has a compact visual footprint and a generous drag hit target. A normal click brings Transcride to the front; dragging does not.
- The indicator is not a second source of recording state. It renders one explicit `GlobalRecordingPresentationState` derived from `AppModel`/`RecorderService`.

### Required visual states (GLB-5)

The indicator clearly distinguishes these states without relying on color alone:

- **Ready to record:** stationary red ring, label **Ready**, and the Start shortcut. This means a writable vault, microphone authorization, and registered Start shortcut are available.
- **Recording:** solid red circle with a calm pulse, label **Recording**, increasing recorded-audio timer, and the Pause/Resume and Stop & Save shortcut hints. Respect Reduce Motion by replacing the pulse with a static high-contrast state.
- **Paused:** non-pulsing red circle containing a pause glyph, label **Paused**, and a frozen recorded-audio timer. It must never look like recording is continuing.
- **Finished recording / Recording saved:** checkmark plus label **Recording Saved** and final duration for a short confirmation interval, then transition to Ready if Transcride remains unfocused. By default the compact indicator remains available for follow-up recordings for 10 minutes after the last save; the user may choose Quick, a longer duration, or Never, and may always dismiss it immediately from its hover control.

Internal/transitional states may also appear when necessary:

- **Saving…:** spinner/progress treatment after Stop & Save and before finalization succeeds. Do not show Recording Saved early.
- **Needs attention:** clear non-recording treatment when a vault, microphone permission, input device, disk space, or shortcut registration prevents Ready. Clicking it brings Transcride forward to resolve the problem.
- **Save failed / recoverable:** never show Finished. Explain that captured audio is retained under Milestone 6's recovery contract and bring the app forward for details.

### Animation, feedback, and accessibility (GLB-6)

- Animations are calm and state-driven: a recording pulse, a short saved transition, and no decorative constant movement in Ready or Paused.
- Honor Reduce Motion and Increase Contrast. Recording, Paused, Ready, Saving, Saved, and Needs Attention remain distinguishable through text, shape/icon, and motion—not color alone.
- VoiceOver exposes the current state, elapsed duration, and relevant shortcut hints. State changes are announced without repeatedly announcing every timer tick.
- Successful global actions produce immediate visual state feedback. Optional subtle system sounds may be offered, off by default; the microphone recording must never capture an app-generated confirmation sound by default.

## Lifecycle and edge cases

### Background readiness (GLB-7)

- Global controls require the Transcride process to be running. State this plainly in Keybinds settings; this milestone does not install a login item or always-running helper.
- If Transcride launches without a restorable vault, global Start activates the app to vault setup. If its vault bookmark is stale or write access is lost, the indicator shows Needs Attention.
- If the main window is closed but the application remains running, global controls and the indicator continue to work. Define app termination behavior deliberately so closing a window does not unexpectedly disable configured global capture.
- Sleep, wake, screen lock, Fast User Switching, and microphone device changes preserve honest state. Follow the existing recorder rule: incompatible input changes pause rather than silently continuing with uncertain audio.
- On wake or session activation, revalidate hotkey registrations, vault access, and indicator placement without interrupting an active recoverable recording.

## Architecture requirements

### One command path (GLB-8)

- Add a pure, unit-testable global-shortcut model: action ids, chord validation, duplicate/conflict status, persistence representation, and state-dependent availability.
- `GlobalShortcutService` owns OS registration only. `AppModel` exposes serialized intents for start, pause/resume, and stop/save. The in-app menu, local shortcuts, global shortcuts, and floating indicator all call those same intents.
- Implement the menu-bar surface as one stable AppKit `NSStatusItem`/`NSMenu` graph. Update existing item titles, symbols, and enablement in place rather than rebuilding rows while AppKit tracks the pointer; sample elapsed time once per second only while the menu is open. It derives state from `AppModel`, remains independent of global-hotkey enablement, and targets the identified main window rather than an auxiliary Settings/help window when opening Transcride.
- Implement the indicator as a dedicated nonactivating `NSPanel`/window controller hosting SwiftUI content. Keep window-level, Space, drag, and screen-position policy outside ordinary app views.
- The indicator observes state; it does not own timers, recording state, or finalization tasks. Use the recorder's recorded-audio elapsed value so pauses do not inflate duration.
- Do not add a general event tap, Accessibility-trusted listener, or background agent unless the human explicitly expands scope after this milestone.

## Decisions already made (do not relitigate)

- There are two configurable global commands: Start/Stop & Save and Pause/Resume.
- Global Start always creates a new recording; it never extends an entry.
- Global controls work while Transcride is running without focus. They do not work after the process has quit.
- The background indicator is floating, draggable, position-persistent, and visible only when Transcride is not active.
- Required visible states are Ready, Recording, Paused, and Recording Saved; Saving and Needs Attention may appear to keep feedback honest.
- Stop means save. There is no global discard shortcut.
- No broad keystroke monitoring and no Accessibility permission solely for shortcuts.
- Reduce Motion disables the recording pulse without weakening state visibility.

## Definition of done

- Both configurable shortcuts work from at least Finder, Safari, a full-screen app, and another Space without activating Transcride.
- Unit tests cover chord validation; duplicate/default handling; persistence; registration-state mapping; serialized command transitions; rapid-key-repeat suppression; indicator presentation states; stable menu-item identity and menu presentation mapping; saved-state timeout; screen-anchor restoration/clamping.
- Integration tests cover registration/unregistration; minimized/hidden/background operation; permission/setup failure; start/pause/resume/stop-save; finalization failure; sleep/wake; display removal; app activation hiding the panel; Milestone 6 recovery of a globally started recording.
- The global listener observes only registered chords. Privacy review confirms there is no general keystroke capture or telemetry.
- `xcodebuild test` passes and the installed `/Applications/Transcride.app` is the build used for global-hotkey and multi-Space verification.

## Verification checklist (human-run)

**Verification is interactive.** Present one item at a time with exact steps, wait for pass/fail, and keep a running tally. On failure, fix it and repeat affected passed items. Write the handoff only after every box is human-confirmed.

- [ ] Open Keybinds settings: the two defaults (**⌥R** and **⌥P**) appear, can be changed/cleared/reset, reject plain or duplicate chords, and report a deliberately conflicting/reserved chord honestly. The menu-bar item and background indicator can be disabled independently, and the indicator's post-recording duration offers Quick through Never with 10 minutes selected by default.
- [ ] Open the native menu-bar item: it shows live state/time; Start/Stop & Save and Pause/Resume with the current shortcut assignments; Open Transcride; Settings; Hide; and Quit. During a recording, leave it open for at least 15 seconds and repeatedly hover every row plus the nonselectable status header; the highlight never jumps to another row or selects the recording-status region as the timer advances. Disable global shortcuts and confirm clicked recording controls still work. Hide the item, relaunch, confirm it stays hidden, then restore it from Settings. Close/minimize/hide the main window and confirm Open Transcride restores exactly one focused main window.
- [ ] With Transcride behind Finder, press **⌥R**: Transcride does not take focus, a new recording begins in the expected vault folder, and the floating indicator changes from Ready to Recording immediately.
- [ ] Press **⌥P** twice while typing in another app: the indicator clearly changes to Paused with a frozen timer, then Recording with the timer advancing; the shortcut characters do not leak into the foreground app.
- [ ] Press **⌥R** again: the indicator shows Saving, then Recording Saved only after finalization succeeds, including final duration; it returns to a clickable Ready circle after the confirmation interval, remains for the configured duration, starts a follow-up recording when clicked, and hides immediately when dismissed from its hover control.
- [ ] Play the saved audio in Transcride: it contains the expected speech, excludes the pause interval, has waveform/duration metadata, and automatically transcribes.
- [ ] Repeat from Safari, a full-screen app, another Space, a minimized Transcride window, and a hidden Transcride app. No action unexpectedly brings the main window forward.
- [ ] Drag the indicator to another corner and relaunch: it returns there. Disconnect that monitor: the indicator moves fully onto an available screen. Reset Indicator Position works.
- [ ] Activate Transcride: the floating indicator hides and the in-app recording UI shows the same state. Deactivate Transcride: the indicator returns without resetting the timer.
- [ ] Enable Reduce Motion and Increase Contrast: all four required states remain unmistakable and Recording no longer pulses.
- [ ] Run the flow with VoiceOver: state changes, elapsed time, and shortcut hints are understandable without excessive timer announcements.
- [ ] Remove microphone permission or close the vault, then invoke Start: recording does not falsely begin; the indicator shows Needs Attention and clicking it opens the exact setup needed.
- [ ] Force finalization failure: the indicator never says Recording Saved, captured audio remains recoverable, and the app provides a route to resolve it.
- [ ] Force-kill a recording started globally, relaunch, and complete PRD-6 recovery. The audio is preserved and exactly one transcription is queued.
- [ ] Rapidly repeat each global chord: there is still one recording, one stop/finalization, and one saved entry.
- [ ] Quit Transcride completely: global shortcuts no longer intercept anything, matching the Keybinds pane's explanation.
- [ ] `xcodebuild test` passes.

## Addendum (2026-07-20, user-approved out-of-band addition): Quick Move and app-wide key remapping

The human approved expanding this milestone with an Obsidian-style **Move
Note…** command and a complete in-app shortcut remapper. This addendum extends
the milestone's scope, definition of done, and verification checklist; the
original GLB requirements are unchanged and milestone status does not advance
until the combined checklist is human-confirmed.

### App shortcut catalog and preferences (KEY-1)

- Shared shortcut types (`ShortcutChord`/`ShortcutModifiers`) carry physical
  key code, modifiers, display glyphs, validation, persistence, and pure event
  matching for both the app-local and global systems. The existing
  global-preference wire format is unchanged.
- A versioned `AppShortcutPreferences` store maps stable `AppShortcutAction`
  IDs to up to two ordered bindings (primary and alternate) and covers every
  Transcride-specific command: recording/file, notes/entry (including Move
  Note), playback (clip undo/redo, skips, jumps 0–9, speed, Skip Silence, Zen),
  library/view (find/search, folder navigation, four sort choices, sidebar
  destinations, Transcription Queue), and app/help (About, Keyboard Shortcuts).
- Every pre-existing default and alternate is preserved — including **E/⌘⇧R**
  for Extend and **⌘⌫/⇧⌫** for Recently Deleted. Previously unbound commands
  stay unbound. **Move Note… defaults to ⌥M.**
- Escape, Return, Tab, plain Up/Down, unmodified Delete, and macOS-owned
  App/Edit/Window chords are fixed and rejected at capture. System commands,
  menu-bar-widget commands, and Debug Testing commands are excluded from the
  catalog.
- Bare local keys are allowed but never fire while editable text has focus;
  clip undo/redo, entry deletion, and folder navigation (⌥↑/⌥↓) defer to
  text editing even when modified.
- Validation rejects modifier-only chords, reserved chords, duplicates across
  every primary/alternate slot, and conflicts with global bindings. A
  configured global chord outranks a conflicting local binding; ambiguous or
  shadowed persisted bindings stay disabled and are visibly flagged in
  Settings rather than silently dropped.

### One dispatcher (KEY-2)

- Menu clicks and matched keyboard events route through
  `AppModel.performAppCommand(_:)` with one availability calculation
  (`isAppCommandEnabled(_:)`).
- Menus display the primary binding (falling back to a menu-safe alternate);
  bare and focus-sensitive chords remain monitor-owned so menu key
  equivalents can never steal typing.
- Remapping applies live without relaunch. While a shortcut-capture control
  owns input, normal command dispatch is suppressed.

### Keybinds settings and help (KEY-3)

- Settings → Keybinds splits into **App Shortcuts** (search, category
  grouping, primary/alternate capture slots, per-slot clearing,
  conflict/reserved feedback, **Reset App Shortcuts**) and **Global Controls**
  (the existing GLB-1 pane with **Reset Global Shortcuts**). The resets are
  independent.
- Help → Keyboard Shortcuts derives its rows from live preferences, showing
  local bindings and accurately distinguishing app-only from global commands.

### Quick Move (MOV-1)

- **Entry → Move Note…** (⌥M, remappable) opens a compact centered picker
  titled for the selected note: search focused immediately; Vault Root and
  every existing folder listed with the current parent excluded; empty-query
  results put Vault Root first with natural ordering; typed queries rank
  leaf/path exact/prefix/substring/fuzzy matches deterministically.
- Arrow keys change selection, Return or click moves, Escape cancels. The
  picker never creates folders and never overwrites a same-named destination
  entry.
- If the note is being edited, pending autosaves are flushed and editing
  finishes before the picker opens; a failed save keeps the picker closed.
  The command is disabled with no selection or during incompatible
  recording/mutation states.
- Failures (vanished destination, collision, filesystem error) keep the
  picker open with an inline error. Success atomically refreshes the
  snapshot, repoints transcription-queue paths, refreshes the search index,
  and follows the selection to the new path with no empty intermediate frame.
  The sidebar/list context is unchanged; drag/drop and the context-menu Move
  To submenu keep working.

### Addendum — definition of done

- Unit tests cover shortcut defaults, unique stable IDs,
  persistence/migration, reset, primary/alternate ordering, bare-key
  acceptance, reserved-key rejection, local/local and local/global conflicts,
  corrupted persisted conflicts, modifier normalization, editable-text
  deferral, and catalog coverage; plus quick-move destination enumeration,
  filtering/ranking, and vault-move edge cases (nested, root, same-folder
  no-op, missing destination, collision, content preservation).
- Integration tests cover dispatcher availability, live remapping without
  relaunch, store round-trips, global registration remaining unchanged, and
  the quick-move flow end to end (move + queue repoint + selection
  continuity, collision, vanished destination).
- `xcodegen generate` and the full `xcodebuild test` pass; the installed
  `/Applications/Transcride.app` is the build used for verification.

### Addendum — verification checklist (human-run)

- [ ] Settings → Keybinds shows App Shortcuts and Global Controls. In App
  Shortcuts, remap a modified chord (e.g. Show Info) and a bare key (e.g.
  Trim), confirm both work immediately without relaunch, and confirm the menu
  bar and Help window update to match.
- [ ] While editing a note, press the bare remapped key: the letter types
  into the note and no command fires. ⌘Z in the editor still performs text
  undo.
- [ ] Attempt to capture a duplicate chord, a reserved key (Return, plain ↓,
  ⌘Q), and the global ⌥R: each is rejected with an inline explanation and the
  previous binding survives.
- [ ] Reset App Shortcuts restores every default (including ⌥M for Move
  Note) without touching the global ⌥R/⌥P bindings; Reset Global Shortcuts
  leaves app shortcuts alone.
- [ ] Select a note and press ⌥M: the picker opens with search focused. Type
  to filter, use ↑/↓ then Return to move the note into a nested folder;
  repeat moving to Vault Root. The sidebar stays on the original folder, the
  detail pane follows the moved note, and its queued transcription (if any)
  completes against the new path.
- [ ] Create a same-named entry collision and attempt the move: the picker
  stays open with an inline error and neither entry is modified.
- [ ] Start editing a note, press ⌥M without saving: the edit is saved
  first, then the picker opens; the moved note contains the edit.
- [ ] With no note selected (or while recording into the selected note),
  Entry → Move Note… is disabled / gives honest feedback.
- [ ] `xcodebuild test` passes.

## Addendum (2026-08-12; revised 2026-08-13, user-approved): Universal recording and capture honesty

The human approved one universal Record action for voice notes and calls. There
is no Voice/Meeting mode or persistent source selector. Every new recording
starts the selected microphone immediately and opportunistically includes audio
playing on the Mac. Capture is app-agnostic, so browser Google Meet plus Zoom,
Telegram, and WhatsApp work without per-app setup when their audio plays on the
Mac, including through headphones. Calls running entirely on another device are
out of scope unless that device's audio is routed through the Mac.

### Universal source (MTG-1)

- The existing AVAudioEngine microphone path is authoritative for start,
  quality, latency, duration, pause/resume, crash recovery, and final output.
  ScreenCaptureKit captures only Mac system audio; it never replaces or delays
  the microphone and never captures or retains video. Transcride's own playback
  is excluded. Explain that notifications and other Mac sounds may be included.
- System-audio permission denial/restriction, required relaunch, start failure,
  invalid format/timing, stream stall, sidecar-write failure, or mix failure
  must never block, pause, or fail microphone recording. Show honest live state:
  checking/available, meaningful Mac audio captured, or microphone-only with a
  reason. Stop & Save never awaits a permission/start continuation; detached
  cleanup serializes any future optional capture. A retired source preference
  is ignored and removed during migration.
- Retain Mac audio in a bounded sparse source-separated sidecar with finite
  pre-roll and release hysteresis. Qualified pre-roll participates in the mix;
  release is capped exactly even when one callback exceeds the remaining
  window. Persisted records may not overlap. Do not create a durable sidecar
  until meaningful Mac signal exists; silence before/between useful regions
  must not grow a second full-length audio file. Explicitly stop every partially
  or fully started stream, synchronously detach its output, and invalidate late
  callbacks on stop, cancel, vault change, or quit/recover-later.
- Map ScreenCaptureKit presentation timestamps through its synchronization
  clock onto timestamped microphone segments. Callback arrival time is not
  media time. Pause intervals, route-restart gaps, invalid timing, and samples
  outside retained microphone coverage cannot add, shift, or fill frames.
- On stop, render source-separated audio offline in bounded chunks with fixed
  headroom-safe gains and smooth attack/release; do not use a unity live sum or
  hard clamp. The pristine mic journal remains untouched until the staged mix
  validates. The final render has exactly the microphone frame count and
  preserves mic samples outside system-audio overlap. Any failure installs the
  mic master instead. With no meaningful Mac audio, output is the ordinary
  mic-only path with no retained sidecar or extra file growth. The same
  validate-or-fall-back rule governs crash and quit-and-recover recovery,
  which re-render the retained sidecar; recovery additionally tolerates a
  single truncated tail record (what a power cut leaves), while any other
  sidecar defect still installs the pristine mic master.
- Atomically install the validated mixed-or-mic-only canonical audio before
  queuing batch transcription. Live transcription remains a display-only mic
  preview, is cleared at stop, and is replaced by post-stop transcription of
  the final canonical audio. This preserves playback seek and word-level
  karaoke highlighting without time compression, extension, or shifted start.
  A meaningful system source promotes an otherwise silent microphone capture
  to transcribable only after the mix validates; a failed canonical install can
  never enqueue a hidden journal.
- Extensions and replacement takes remain microphone-only because their edit
  semantics are tied to the selected canonical region. This boundary is stated
  in Recording Settings.

### Capture honesty and reliability (MTG-2)

- Starting an audio engine/stream is not sufficient proof of capture. Track
  first-buffer delivery, continued buffer delivery, and meaningful signal.
  Warn visibly within seconds when no audio is detected; never leave a dead
  capture graph presenting an unqualified Recording state.
- Explicitly downmix every input channel before sample-rate conversion. A
  multi-channel microphone whose first channel is silent must not produce a
  silent mono recording when another channel carries signal.
- A zero-frame recording is not a successful save and is never queued for
  transcription. A framed recording containing only digital silence is
  retained for recovery/inspection but is reported honestly and is not queued
  as if speech were captured.
- A configured microphone that is absent or cannot be bound must fail visibly
  rather than silently falling back to an unintended device. System Default is
  the only selection allowed to follow the current default route.
- `AVAudioEngine.start()` alone is not proof that recording began. Publish an
  active recording only after the requested physical route is stable and at
  least one microphone buffer has been normalized and written to the canonical
  journal. A failed/no-buffer attempt must tear down its graph completely,
  persist a diagnostic event, and retry with a fresh engine within a bounded
  startup deadline.
- Keep an always-on, append-only microphone-failure ledger across relaunches and
  app updates. Record every permission/device/format/journal/engine startup
  failure; every no-buffer, prolonged-silence, stall, and sink-write episode;
  and every terminal zero-frame or perfectly silent microphone result before
  optional Mac audio can mask it. Stop, cancel, quit-and-recover, and crash
  recovery use the same microphone-only classification; a recovered mix never
  alters the microphone classification. The ledger is local,
  owner-readable only, and contains no vault paths, titles, audio samples,
  device names, raw hardware identifiers, or error descriptions.

### Universal-recording addendum — definition of done

- Unit/integration tests cover multi-channel downmix with signal absent from
  channel zero; first-buffer timeout; stream stall; prolonged digital silence;
  zero-frame finalization; selected-device mismatch; retired-preference
  migration; optional permission/start/stall fallback; no-system bit-equivalent
  bypass/no artifact; later system-signal alignment; pause/resume and route-gap
  timestamp mapping; offline headroom/release; corrupt/mix-failure mic fallback;
  exact canonical frame/seek mapping; qualified pre-roll; exact zero/nonzero
  release bounds; Core/file parity across renderer blocks; overlap rejection;
  silent-mic/system-signal classification; suspended optional-start cleanup;
  live-clear → canonical-install → batch-enqueue ordering (including install
  failure suppression); honest UI status mapping; canonical written-sample
  silence classification; terminal/cancel/recovery logging; durable JSONL
  append across relaunches; concurrent complete records; restrictive file
  permissions; nonfatal log-write failure; and hard-crash zero/silent journal
  classification for new recordings, extensions, and replacement takes.
- Human verification records both sides of calls in browser Google Meet, Zoom,
  Telegram, and WhatsApp, with speakers and headphones where supported. It
  also verifies Bluetooth microphone quality/latency, permission
  denial/recovery, pause/resume, global background start/stop, honest live
  status, app-audio exclusion, crash recovery, late-starting Mac audio, and
  playback karaoke highlighting against the final transcript.
- The full test suite passes and the tested build is installed at
  `/Applications/Transcride.app`.

## Handoff (required, after the checklist is verified)

Write **`PRD-9-start-here.md`** with: state summary; build/run/test commands; changed file map; global action ids and default chords; registration lifecycle; `AppModel` intent signatures; command serialization rules; indicator state model; panel level/Space/activation behavior; screen-position persistence; permissions and failure states; the app-shortcut catalog/dispatcher architecture and quick-move flow from the addendum; deviations; known issues. Append milestone deviations and global-control architecture to `PROJECT-STATE.md`. Close with the fresh-model assumption line used by prior milestone handoffs.
