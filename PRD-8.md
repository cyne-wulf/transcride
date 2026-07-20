# PRD-8 — Milestone 8: Global Recording Controls

> **Before starting:** read [PROJECT-STATE.md](PROJECT-STATE.md) and `PRD-8-start-here.md`. **Do not start until the human confirms Milestone 7 is verified.** Reuse the existing `AppModel` recording intents and `RecorderService`; global controls are another input surface over the same state machine, not a second recorder. Crash safety from Milestone 6 applies unchanged to recordings started outside the focused app.

> **One-time transition waiver — 2026-07-17:** The human directed Milestone 9 to
> begin without running this milestone's human checklist. The Milestone 8
> implementation task is complete in the current worktree but remains unverified;
> all 23 checklist boxes below remain deliberately unchecked, and no `milestone-8`
> verified tag may be created or claimed. This exception applies only to the
> Milestone 8 → 9 transition and does not change any other verification gate.
> `PRD-9-start-here.md` records implementation state and automated evidence; it is
> not proof of human verification.

## Goal

Let the user control Transcride from any app using configurable system-wide keybinds. Without bringing Transcride to the front, the user can start a new recording, pause or resume it, and stop and save it. A small floating, draggable indicator appears while Transcride is not focused so recording state is always visible.

## Scope

**In:** keybinds settings/menu; configurable global shortcuts; start, pause/resume, and stop-and-save commands; conflict and availability handling; unfocused/minimized/hidden operation; floating draggable status indicator; recording timer and state animation; multi-display/Space behavior; accessibility; launch/session persistence; **user-approved out-of-band Quick Move and app-wide remapping addition:** a two-slot remapper for Transcride-specific app-local commands, live menu/help shortcut presentation, and an Obsidian-style **Move Note…** picker that keeps vault, queue, search, and selection state coherent; **out-of-band Library addition:** subfolder entry aggregation — a selected parent folder's entry list includes descendant entries, with an on-by-default **Include entries from subfolders** toggle in General settings; **out-of-band diarization correction:** an entry with cached speaker detection can toggle its speaker presentation off and on without retranscription or discarding speaker ids/names.

**Out:** listening while Transcride is not running; a privileged helper or login daemon; global playback controls; voice commands; media-key interception; automatic recording based on other apps; uploading or remote control; arbitrary macro scripting; remapping macOS-owned commands such as Cut/Copy/Paste, Settings, Close, Minimize, Hide, Quit, and standard dialog actions; remapping Escape, Return, Tab, plain Up/Down, or unmodified Delete; remapping status-item-only controls or Debug Testing commands; creating folders or overwriting an entry from Quick Move.

## Requirements

### Keybinds menu (GLB-1)

- Add a dedicated **Keybinds** pane in Settings, split into **App Shortcuts** and **Global Controls**, and keep Help → Keyboard Shortcuts as the readable reference. App-local and global bindings have independent reset controls.
- Provide two global actions:
  1. **Start / Stop & Save Recording**
  2. **Pause / Resume Recording**
- Ship simple defaults: **⌥R** starts a new recording while idle and stops and saves the active recording; **⌥P** pauses or resumes. These are defaults only—the user may clear or replace either binding.
- Global shortcut capture requires at least one non-Shift modifier and rejects a modifier-only chord, plain typing key, or duplicate assignment. Show the recorded chord in standard macOS glyph order. App-local capture follows the separate GLB-9 rules and may accept bare keys.
- Detect registration failures and likely conflicts. A shortcut that could not be registered is visibly marked and must not appear enabled. Never silently steal a chord from another application.
- Include **Enable Global Controls**, **Show Transcride in menu bar**, **Show indicator while Transcride is in the background**, a post-recording visibility duration from Quick through Never (10 minutes by default), and **Reset Global Shortcuts** controls. Settings persist across relaunch. The menu-bar item is shown by default and can also hide itself persistently.
- The native menu-bar item shows honest live recording state and elapsed time; Start/Stop & Save and Pause/Resume controls with their current global shortcut assignments; Show Floating Widget; Open Transcride; Settings; Hide Menu Bar Item; and Quit. Its clicked controls remain usable when global shortcuts are disabled and call the same serialized `AppModel` intents.
- The existing in-app shortcuts become the default app-shortcut profile and continue to work until the user changes them. The menu bar and Keyboard Shortcuts window show both local and global chords without implying that a local bare-key shortcut works outside Transcride or registering a duplicate menu key equivalent.

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
- **Show Floating Widget** is a session-only manual visibility override. It shows the widget across application focus changes even when global controls or automatic background-indicator visibility are disabled, without changing saved preferences. The override ends only when the widget's hover dismiss control is clicked or Transcride quits.
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

### App-wide shortcut remapping (GLB-9)

- Introduce shared `ShortcutChord` types for physical key code, normalized modifiers, macOS-ordered display glyphs, persistence, and pure event matching. Global-only rules such as requiring a non-Shift modifier belong to the global validator rather than the shared chord type so app-local bare keys remain valid. Keep the existing `GlobalShortcutPreferences` wire format, action raw values, defaults key, and migration behavior compatible.
- Add stable, versioned `AppShortcutAction` ids grouped by `AppShortcutCategory`, plus a versioned `AppShortcutPreferences` store. Every action has two ordered optional slots, primary and alternate; clearing one slot does not reorder or overwrite the other.
- The app-shortcut catalog includes:
  - **Recording/File:** new recording; start/stop-and-save recording; the contextual pause/resume-recording or play/pause action; import; new folder.
  - **Notes/Entry:** favorite; rename; duplicate; Move Note; move the selected entry to Recently Deleted; extend; edit/save; copy Markdown; layer toggle; cached speaker-presentation toggle with stable id `toggleSpeakerDetection`; retranscribe; trim; replace; compress; restore original; rename speakers; delete audio; info; reveal; export; share; Open in Obsidian.
  - **Playback:** clip undo and redo; skip back and forward; jumps 0–9; speed down, up, and reset; Skip Silence; Zen mode.
  - **Library/View:** Find in Note; Search Vault; previous and next folder; Date, Duration, Title, and Recently Edited sorts; Vault Root; Favorites; Recently Deleted; Transcription Queue.
  - **App/Help:** About and Keyboard Shortcuts.
- Preserve the exact existing app-local assignments as defaults, with **Move Note** added as **⌥M**: New Recording **⌘N**; Start/Stop & Save **⇧Space**; contextual Pause/Resume or Play/Pause **Space**; Import **⌘⇧I**; New Folder **⌘⇧N**; Favorite **⌘D**; Extend **E** primary and **⌘⇧R** alternate; Edit/Save **⌘E**; Copy Markdown **⌘⇧C**; move to Recently Deleted **⌘⌫** primary and **⇧⌫** alternate; Trim **T**; Replace **R**; Info **⌘I**; Export **⌘⇧E**; clip Undo **⌘Z**; clip Redo **⌘⇧Z**; Skip Back **←**; Skip Forward **→**; top-row **0–9** with each corresponding numeric-keypad digit as its alternate; Speed Down **[**; Speed Up **]**; Speed Reset on the backslash key; Skip Silence **S**; Zen **Z**; Find in Note **⌘F**; Search Vault **⌘⇧F**; Previous/Next Folder **⌥↑/⌥↓**; Keyboard Shortcuts **⌘?**. Actions not named in this default list, including `toggleSpeakerDetection` and About, remain unbound.
- Escape, Return, Tab, plain Up/Down, and unmodified Delete remain structural and fixed. Standard macOS App/Edit/Window commands, status-item-only commands, and Debug Testing commands are not `AppShortcutAction`s. The existing intentional Transcride assignments such as **⌘N**, **⌘F**, and clip **⌘Z** remain allowed while native text editing retains its documented precedence.
- Reject modifier-only chords, reserved native/system chords, duplicate primary/alternate slots, duplicates between app actions, and conflicts with either global action. Existing global bindings win over a newly introduced or reset local default; if a global change or corrupted persisted state creates ambiguity, keep the global binding registered and leave every ambiguous local binding disabled and visibly flagged rather than choosing a winner silently.
- Bare app-local keys may dispatch only while Transcride is active and no editable text control owns input. Clip undo/redo and moving an entry to Recently Deleted continue to defer to text editing even when their binding has modifiers. Normal command dispatch is suspended while any shortcut-capture control owns input, so captured keys cannot also trigger an app action.
- Route menu clicks and keyboard events through one `AppModel.isAppCommandEnabled(_:)` calculation and one `AppModel.performAppCommand(_:)` dispatcher. Commands whose dialogs, sheets, sharing surface, or other presentation state is view-owned use typed revision requests, but completion still returns through the same command path. A shortcut must never bypass the enablement or mutation guards used by its visible control.
- Menus display the live primary binding. Modified bindings that are safe as native menu key equivalents may use them; bare and focus-sensitive bindings remain owned by the app-local event matcher so a menu equivalent cannot steal typing or cause duplicate dispatch. Remapping, clearing, or resetting takes effect without relaunch.
- **App Shortcuts** settings provide search, category grouping, primary and alternate capture slots, per-slot clearing, conflict/reserved feedback, and **Reset App Shortcuts**. **Global Controls** retains registration status, indicator/menu-bar options, and its independent **Reset Global Shortcuts**. Resetting either store leaves the other byte-for-byte unchanged.
- Help → Keyboard Shortcuts derives every row and glyph from the live app and global preference stores, shows both ordered local bindings, and clearly labels which commands are app-only versus system-wide. It must not retain hard-coded shortcut rows that drift after remapping.

### Quick Move (GLB-10)

- Add **Entry → Move Note…** and route its default **⌥M** through GLB-9. Keep the existing drag/drop and context-menu **Move To** behavior, but route their final filesystem mutation through the same result-returning move intent.
- Present a compact centered picker titled for the selected note with its search field focused immediately. List Vault Root and every existing subfolder except the entry's current parent. With an empty query, Vault Root is first and all remaining paths sort naturally.
- Filtering considers both leaf name and full relative path. Rank exact, prefix, substring, and fuzzy matches deterministically, with stable natural-path tie breaking; the same query over an unchanged snapshot must never reorder results. Arrow keys move selection, Return moves to the selected destination, a click moves directly, and Escape cancels.
- The picker never creates a folder and never overwrites a same-named destination entry. A same-folder move remains a safe no-op at the vault-operation layer even though the picker excludes the current parent.
- If the note is being edited, cancel and await pending autosaves, finish editing, and confirm the final save before presenting the picker. If saving fails, preserve the editing session and do not open Quick Move.
- Disable Move Note when no note is selected or while the selected note is recording, finalizing, replacing, trimming, compressing, undergoing another clip mutation, or otherwise unavailable under the centralized command calculation.
- Keep the picker open with an inline, accessible error if the destination disappears, a collision is discovered, or the filesystem move fails. Preserve the source and current selection, let the user choose another destination, and dismiss only after the move and refresh are confirmed successful.
- On success, synchronize the search index at the old and new paths, repoint every affected transcription-queue path, publish the refreshed vault snapshot and new selected-entry path in one main-actor turn, and avoid any empty intermediate detail frame. Keep the current sidebar/list context unchanged: the moved row may disappear from the current list, while the detail remains on the moved note until the user chooses another note.

## Decisions already made (do not relitigate)

- There are two configurable global commands: Start/Stop & Save and Pause/Resume.
- Global Start always creates a new recording; it never extends an entry.
- Global controls work while Transcride is running without focus. They do not work after the process has quit.
- The background indicator is floating, draggable, position-persistent, and visible only when Transcride is not active.
- Required visible states are Ready, Recording, Paused, and Recording Saved; Saving and Needs Attention may appear to keep feedback honest.
- Stop means save. There is no global discard shortcut.
- No broad keystroke monitoring and no Accessibility permission solely for shortcuts.
- Reduce Motion disables the recording pulse without weakening state visibility.
- App-local commands have at most two ordered bindings, work only while Transcride is active, and never turn playback or entry actions into global hotkeys.
- Standard macOS commands and the fixed structural keys remain native. Existing Transcride defaults are the reset baseline, not immutable bindings.
- Move Note moves the complete plain-file entry without creating folders or overwriting a collision; a successful move keeps the current library context and selected-note continuity.

## Definition of done

- Both configurable shortcuts work from at least Finder, Safari, a full-screen app, and another Space without activating Transcride.
- Unit tests cover chord validation; duplicate/default handling; persistence; registration-state mapping; serialized command transitions; rapid-key-repeat suppression; indicator presentation states; stable menu-item identity and menu presentation mapping; saved-state timeout; screen-anchor restoration/clamping.
- Integration tests cover registration/unregistration; minimized/hidden/background operation; permission/setup failure; start/pause/resume/stop-save; finalization failure; sleep/wake; display removal; app activation hiding the panel; Milestone 6 recovery of a globally started recording.
- The app-shortcut catalog has unique stable ids, contains every GLB-9 action including `toggleSpeakerDetection`, excludes every named native/fixed/status-item/Debug command, preserves the exact primary/alternate defaults, and applies live preference changes consistently to keyboard routing, menu presentation, and Help.
- Unit tests cover shared chord normalization, glyphs, persistence, and event matching; app-action catalog coverage and stable ids; exact defaults; primary/alternate ordering; preference migration and reset; bare-key acceptance; reserved-key rejection; local/local and local/global conflicts; global-wins migration; corrupted persisted ambiguity; editable-text deferral; and capture-mode isolation.
- Unit tests cover Quick Move destination enumeration, root/current-folder behavior, natural ordering, deterministic leaf/full-path ranking, no-result behavior, and selection movement; vault-operation tests cover nested and root moves, same-folder no-ops, missing destinations, collisions/no-overwrite, and preservation of every entry file.
- Integration tests cover menu clicks and keyboard events reaching the same dispatcher; centralized availability; live remapping without relaunch; alternate bindings; clearing and independent resets; menu/Help updates; unchanged global registration and legacy global-preference decoding; selection continuity; queue repointing; search-index old/new paths; picker error recovery; and editor-save-before-move including save failure.
- The global listener observes only registered chords. The app-local matcher runs only while Transcride is active, never installs a system-wide event tap, and defers to editable text and capture controls as specified. Privacy review confirms there is no general system-wide keystroke capture or telemetry.
- `xcodebuild test` passes and the installed `/Applications/Transcride.app` is the build used for global-hotkey and multi-Space verification.

## Verification checklist (human-run)

**Verification is interactive.** Present one item at a time with exact steps, wait for pass/fail, and keep a running tally. On failure, fix it and repeat affected passed items. Normally, write the handoff only after every box is human-confirmed. The one-time 2026-07-17 transition waiver above authorized this milestone's handoff without checking any box; it did not turn the checklist green.

- [ ] Open Keybinds → Global Controls: the two defaults (**⌥R** and **⌥P**) appear, can be changed, cleared, and restored with **Reset Global Shortcuts**; global capture rejects a plain key or duplicate chord and reports a deliberately conflicting/reserved chord honestly. The menu-bar item and background indicator can be disabled independently, and the indicator's post-recording duration offers Quick through Never with 10 minutes selected by default.
- [ ] Open Keybinds → App Shortcuts and search for **Extend**, **Move Note**, and both commands titled for Recently Deleted: Extend shows **E** then **⌘⇧R**, Move Note shows **⌥M**, moving the selected note to Recently Deleted shows **⌘⌫** then **⇧⌫**, and navigating to Recently Deleted is a distinct unbound action. Give an initially unbound action both a modified primary and a bare alternate, confirm both work immediately outside text input, and confirm the app menu shows the primary while Help → Keyboard Shortcuts shows both as app-only. Clear one slot, relaunch to confirm persistence, then use **Reset App Shortcuts** and confirm every exact default returns while **⌥R/⌥P** and all Global Controls settings remain unchanged. Reset Global Shortcuts separately and confirm the app profile remains unchanged.
- [ ] In App Shortcuts, try assigning one chord to two app actions, **⌥R** to an app action, and a macOS-owned chord such as **⌘C**: each rejected or disabled binding is visibly explained, the existing global chord remains registered, and no ambiguous command fires. While a capture field owns input, press the current Replace key and confirm it is captured without opening Replace. Assign bare **Q** to Favorite, type `q` in a title field, Quick Move search, and the note editor, and confirm typing wins; move focus outside editable text and confirm **Q** invokes Favorite. In the note editor, confirm **⌘Z/⌘⇧Z** remain text undo/redo and **⌘⌫/⇧⌫** edit text rather than moving the entry to Recently Deleted.
- [ ] Create nested destination folders including two similarly named leaf folders, select a note in a third folder, and invoke **Move Note…** with **⌥M**. Confirm the search field is focused, Vault Root is first with an empty query, the current parent is absent, full-path and leaf-name searches rank exact/prefix/substring/fuzzy results consistently, Arrow keys change selection, and Return moves to a nested destination. The picker closes only after success; the sidebar selection does not change, the moved row may disappear, and the detail remains on the moved note with all of its files intact. Invoke Move Note again and click Vault Root; confirm the transcription queue and a vault search follow the new path. Confirm the command is disabled with no selected note and during an incompatible active recording/mutation.
- [ ] Begin editing a note, type text without waiting for autosave, and invoke **Move Note…**: the edit saves and editing finishes before the picker appears, and the moved note contains the new text. For collision recovery, open the picker, copy the entry's folder into the intended destination in Finder, then choose that destination; confirm an inline error appears, the picker stays open, and the source is unchanged. Remove the collision and retry successfully. Repeat after deleting a listed destination in Finder, confirm a retryable inline error, then press Escape and confirm nothing moves.
- [ ] Open the native menu-bar item: it shows live state/time; Start/Stop & Save and Pause/Resume with the current shortcut assignments; Show Floating Widget; Open Transcride; Settings; Hide; and Quit. During a recording, leave it open for at least 15 seconds and repeatedly hover every row plus the nonselectable status header; the highlight never jumps to another row or selects the recording-status region as the timer advances. Disable global shortcuts and automatic background-indicator visibility, choose Show Floating Widget (the menu item shows a checkmark while the override is active), and confirm the widget remains visible across Transcride focus changes until its hover dismiss control is clicked without changing either saved setting. Relaunch and confirm the manual widget does not return. Confirm clicked recording controls still work. Hide the menu-bar item, relaunch, confirm it stays hidden, then restore it from Settings. Close/minimize/hide the main window and confirm Open Transcride restores exactly one focused main window.
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
- [ ] In General settings, toggle **Include entries from subfolders** off: a selected parent folder lists only its direct entries, and a previously selected descendant entry is deselected. Toggle it back on (the default): descendant entries appear again in the parent folder's list, new recordings still save directly to the selected folder, and the choice persists across relaunch.
- [ ] On a diarized entry, rename a speaker and toggle **Detect Speakers** off: Original, generated Markdown, search, Copy as Markdown, and Original export omit speaker labels and speaker-driven grouping without running transcription. Toggle it back on: the cached labels, grouping, and chosen name return immediately. Repeat on a hand-edited entry and confirm its Edited Markdown remains byte-for-byte unchanged.
- [ ] Force finalization failure: the indicator never says Recording Saved, captured audio remains recoverable, and the app provides a route to resolve it.
- [ ] Force-kill a recording started globally, relaunch, and complete PRD-6 recovery. The audio is preserved and exactly one transcription is queued.
- [ ] Rapidly repeat each global chord: there is still one recording, one stop/finalization, and one saved entry.
- [ ] Quit Transcride completely: global shortcuts no longer intercept anything, matching the Keybinds pane's explanation.
- [ ] `xcodebuild test` passes.

## Handoff (created under the one-time transition waiver; not verification)

Under the dated waiver, write **`PRD-9-start-here.md`** as implementation evidence and transition context, not as a verified-gate artifact, with: state summary; build/run/test commands; changed file map; global action ids and default chords; app action ids, categories, exact defaults, preference schema/migration, and conflict precedence; registration lifecycle; `AppModel` intent and app-command dispatcher signatures; command serialization and availability rules; Quick Move destination/ranking model, editor-save handshake, move result, queue/index synchronization, and selection publication; indicator state model; panel level/Space/activation behavior; screen-position persistence; permissions and failure states; deviations; known issues. Append milestone deviations and global-control/app-shortcut/Quick Move architecture to `PROJECT-STATE.md`. Close with the fresh-model assumption line used by prior milestone handoffs.
