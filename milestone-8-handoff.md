# Milestone 8 handoff

> Assume you are a fresh model with zero context beyond this document and the
> next milestone's PRD, whichever it turns out to be. PRD-9 was removed from
> the roadmap at milestone-8 closeout; no successor milestone is defined yet.

## State summary

Milestone 8 (global recording controls) is implemented, human-verified on
2026-08-20, and tagged `milestone-8`. Transcride now records from anywhere:
two Carbon global hotkeys (⌥R start/stop-and-save, ⌥P pause/resume), a menu
bar item, and a floating background indicator drive the same single-recorder
contract as the in-app controls. The milestone also delivered, as
user-approved additions: a complete in-app shortcut remapper (59 actions,
two slots each), the Quick Move sheet (⌥M), optional universal recording
(Mac system audio mixed onto the microphone via ScreenCaptureKit), a durable
microphone-failure ledger, a 34-finding audit-fix program, power-loss
durability barriers with an adversarial-audit remediation pass, Zen-mode
spacebar control, and an explicit permission-status section in Settings.
The full suite is green: 565 unit tests (61 suites) + 68 integration tests
(7 suites). PRD-9 (the editor workbench) was removed from the roadmap at
closeout; the next milestone is not yet defined.

## Build, run, test

- `xcodegen generate` — required after adding/removing source files;
  `Transcride.xcodeproj` is generated from `project.yml`, never hand-edited.
- `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build`
- `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' test`
- `Scripts/make-fixture-vault.sh [count] [dir]` — fixture vault.
- Deploy for hands-on use: quit Transcride, `ditto` the DerivedData
  `Transcride.app` over `/Applications/Transcride.app`, relaunch.
- `TranscrideTests` compiles `Transcride/Core` directly (no app host);
  `Transcride/App` and `Transcride/UI` are covered by build success,
  integration tests, and hands-on verification only.

## Changed file map (milestone-7 → milestone-8)

117 files changed. The ones that define this milestone:

- **Global controls, Core**: `Core/GlobalRecordingControls.swift` (actions,
  chords/validation, preferences v4, command gate, presentation state,
  screen anchor), `Core/AppShortcuts.swift` (shared chord primitives +
  app-shortcut catalog), `Core/QuickMove.swift`.
- **Global controls, App**: `App/GlobalShortcutService.swift` (Carbon
  registration), `App/GlobalRecordingIndicatorController.swift` (floating
  panel), `App/AppWindowPresenter.swift`, `App/AppTerminationDelegate.swift`,
  `UI/TranscrideMenuBar.swift`, `UI/GlobalShortcutSettings.swift`,
  `UI/AppShortcutSettings.swift`, `UI/ShortcutCaptureField.swift`,
  `UI/ShortcutKeyEquivalents.swift`, `UI/QuickMoveView.swift`,
  `UI/KeyboardShortcutsView.swift`; dispatcher + intents in
  `App/AppModel.swift`.
- **Universal recording**: `App/UniversalSystemAudioCaptureService.swift`
  (ScreenCaptureKit adapter), `Core/SparseSystemAudioSidecar.swift` (sparse
  sidecar writer/reader + offline mixer), `Core/MeetingAudioMixer.swift`,
  `Core/RecordingAudioProcessing.swift`, `Transcride/Info.plist` (usage
  descriptions).
- **Durability**: `Core/DurableAudioJournalWriter.swift` (hand-rolled CAF
  journal with F_FULLFSYNC barriers + torn-patch repair),
  `Core/FileDurability.swift` (shared barrier primitive),
  `Core/AtomicFile.swift`, `Core/InterruptedRecordingRecovery.swift`,
  `Core/RecordingExtension.swift`, `App/RecorderService.swift`,
  `App/VaultService.swift`.
- **Diagnostics**: `App/MicrophoneFailureLogger.swift`,
  `Core/MicrophoneCaptureDiagnostics.swift`.
- **Tests**: new suites `GlobalRecordingControlsTests`, `AppShortcutsTests`,
  `QuickMoveTests`, `DurableAudioJournalWriterTests`,
  `SparseSidecarTailPolicyTests`, `MeetingAudioMixerTests`,
  `RecordingAudioProcessingTests`, plus integration suites
  `GlobalRecordingIntegrationTests`, `AppCommandIntegrationTests`,
  `UniversalRecordingIntegrationTests`,
  `MicrophoneFailureLoggerIntegrationTests`,
  `VaultServiceRecoveryIntegrationTests`.

## Global actions and default chords

`GlobalShortcutAction` (`Core/GlobalRecordingControls.swift`), exactly two
cases; raw values are the stable persistence ids:

| id | title | default chord |
|---|---|---|
| `toggleRecording` | Start / Stop & Save Recording | ⌥R (keyCode 15 + option) |
| `pauseResumeRecording` | Pause / Resume Recording | ⌥P (keyCode 35 + option) |

A global chord must be a real key plus at least one of ⌘⌥⌃ (Shift alone is
rejected). Validation outcomes: `.valid`, `.modifierOnly`,
`.requiresNonShiftModifier`, `.duplicate(action)`.
`GlobalShortcutPreferences` (version 4) also carries `isEnabled`,
`showsMenuBarItem`, `showsBackgroundIndicator`, and
`backgroundIndicatorRetention` (default ten minutes; options quick/1/5/10/30
minutes, one hour, never).

## Registration lifecycle

`App/GlobalShortcutService.swift` uses **Carbon `RegisterEventHotKey`** with
one `InstallEventHandler` on the application target — no CGEventTap, no
NSEvent global monitor, no Accessibility or Input Monitoring permission.
Signature `'TRCD'`, hotkey ids 1/2. `apply(preferences)` unregisters then
re-registers atomically; any registration failure unregisters again, rolls
back to the previously active preferences, and publishes per-action
`GlobalShortcutRegistrationStatus` (`.disabled | .cleared | .registered |
.failed(message)`; `eventHotKeyExistsErr` maps to "That shortcut is reserved
by macOS or another application."). Auto-repeat is suppressed via a
pressed-actions set until key release. Preferences persist as JSON in
UserDefaults key `globalShortcutPreferencesV2` (versions 2…4 accepted and
migrated forward; anything else falls back to defaults). The indicator
controller re-applies registration on `NSWorkspace.didWakeNotification` and
session-activation. `shutdown()` unregisters everything and removes the
handler at termination.

## AppModel intents and command serialization

All recording entry points funnel into one intent surface
(`App/AppModel.swift`):

```swift
func startRecording() async                    // performRecordingCommand(.startNew)
func toggleRecordingPause() async              // .pauseResume
func stopRecording() async                     // .stopAndSave
func stopRecordingForTermination() async
func toggleRecordingFromIndicator() async
func performRecordingCommand(_ command: RecordingCommand) async
```

Serialization rules:

- `RecordingCommandGate` admits one command at a time; a second arrival
  returns `.suppressedRepeat` (silently ignored — hold-down safety).
- Otherwise a (command × availability-state) matrix yields `.perform` or
  `.unavailable(reason)` with canned reasons ("A recording is already
  active.", "The microphone is still starting.", …). Unavailable shows a
  2-second transient on the indicator; an unavailable `.startNew` also
  activates the app.
- Availability states: `.idleReady`, `.idleUnavailable(reason)`,
  `.recording`, `.paused`, `.pausedResumeUnavailable(reason)`,
  `.startingMicrophone`, `.finalizing`. Idle-ready requires a ready phase,
  a vault, and a writable vault volume.
- A second gate (`RecordingWorkflowStartGate` + start tokens) serializes
  extension/replacement starts across suspension points.
- The termination path parks continuations until both gates release, so
  quit-time stop cannot be lost to repeat suppression.
- The global `toggleRecording` hotkey maps to `.startNew` when the recorder
  is idle and `.stopAndSave` otherwise.

## Indicator state model and panel behavior

`GlobalRecordingPresentationState` (Core) drives both the indicator and the
menu bar: `.hidden`, `.ready(startShortcut:)`,
`.recording(elapsed:pauseShortcut:stopShortcut:)`,
`.recordingNeedsAttention`, `.paused`, `.startingMicrophone`, `.saving`,
`.saved(duration:until:)`, `.needsAttention(message)`,
`.saveFailed(message)`, `.unavailable(message, until:)`. The indicator
variant requires a registered Start chord; the menu bar variant does not.

Panel (`App/GlobalRecordingIndicatorController.swift`): a 72×72 borderless
non-activating `NSPanel`, `level = .floating`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, never key/main,
movable by background, `orderFrontRegardless()`. The app's activation policy
is never changed; it stays a regular app that keeps running windowless
(`applicationShouldTerminateAfterLastWindowClosed == false`). Visible only
when enabled + indicator on + (recording session active or retention window
open) + app inactive + not dismissed. Click toggles recording; a 0.55 s
long-press opens the main window. VoiceOver announcements fire once per
state kind; Reduce Motion and Differentiate Without Color are respected.

Screen position persists as `GlobalIndicatorScreenAnchor` (display id +
normalized 0…1 coordinates, default 0.97/0.93 on the main screen) in
UserDefaults key `globalIndicatorScreenAnchorV1`, restored on wake, screen
change, and activation changes; Settings offers a reset that removes the key.

## Permissions and failure states

- Global controls need **no** extra permission (Carbon hotkeys). Microphone
  is the only required TCC; Screen & System Audio Recording is optional and
  only gates the Mac-audio half of universal recording.
- `recordingPresentationState` surfaces, in priority order: vault not ready,
  recorder alerts, microphone permission denied/restricted ("Enable
  Microphone access in System Settings."), not-yet-requested, no usable
  input device, missing preferred microphone, low disk (< 32 MB), and — for
  the indicator only — an unregistered Start chord.
- Settings → Recording opens with a `PermissionsSection`: Microphone shows
  the full four-state authorization with Request Access… / Open System
  Settings… actions; System Audio Recording shows the prompt-free
  `CGPreflightScreenCaptureAccess()` result (Granted / Not granted — macOS
  offers no tri-state for this TCC) with a deep link. Both re-poll every 2
  seconds while the pane is open.

## App-shortcut catalog and dispatcher

Catalog (`Core/AppShortcuts.swift`): `AppShortcutAction` has **59 actions**
in 5 categories (Recording & Files 5, Notes & Entries 21, Playback 19,
Library & View 12, App & Help 2); raw values are stable persistence ids.
Each action has `.primary`/`.alternate` slots. Notable defaults: ⌘N new
recording, ⇧Space start/stop, bare Space pause-or-playback, ⌥M Quick Move,
bare E extend, bare T trim, bare R replace; 20 actions ship unbound.
Reserved: structural keys (↩ ⌤ Tab Esc, unmodified Delete, plain ↑/↓) and
14 macOS system chords. Validation returns `.valid | .modifierOnly |
.reserved | .duplicate | .conflictsWithGlobal`; persisted chords that become
invalid are *shadowed with a visible reason*, never silently dropped, and
**global chords always outrank local bindings**. Preferences persist under
`appShortcutPreferencesV1` with tolerant decoding.

Dispatcher: one local `NSEvent` keyDown monitor installed at launch. It
bails during shortcut capture, keeps fixed handling only for Escape and
collapsed-layout ↑/↓, and resolves everything else through
`AppShortcutEventMatcher` (nil on unbound/ambiguous/global-owned/reserved/
text-editing-deferred) into `performAppCommand(_:)`, which re-checks
`isAppCommandEnabled`. Menu items get real key equivalents only for
menu-safe chords (`ShortcutKeyEquivalents.swift`); bare-key chords stay
monitor-owned. `ShortcutCaptureField` (shared by both Keybinds panes) claims
`performKeyEquivalent` while capturing, cancels on Escape/resign-key/hide,
and drives `AppModel.isShortcutCaptureActive`. The Help → Keyboard Shortcuts
window derives every row from live preferences.

## Quick Move

⌥M (or the command) opens a 380-pt sheet listing every folder (Vault Root
first, current parent excluded) with ranked filtering (leaf exact → prefix →
substring → path variants → fuzzy subsequence). ↑/↓ select, ↩ moves, Esc
cancels. Blocked with a reason during: no vault, Recently Deleted view, no
selection, live recording, replacement mode, clip mutation, compression.
Presenting first flushes an in-progress note edit and only opens if the save
succeeds. The move pre-checks the destination, then performs one atomic
refresh that repoints transcription-queue items and recovery artifacts and
follows the selection; name collisions and failures keep the sheet open with
an inline message.

## Durability contract (carried into all future audio work)

`.recording.caf` journals are written by `DurableAudioJournalWriter` (Int16
LE PCM in CAF, data-chunk size −1 until close) with coalesced `F_FULLFSYNC`
barriers every ~5 s of audio on a private queue — never the capture thread.
Power loss costs at most the barrier interval plus one buffer; app crashes
cost ≈ 0. `close()` verifies its size patch and recovery calls
`DurableAudioJournalWriter.repairDataChunkSize(at:)` before reading any
journal, so a patch torn at any byte reads as exactly the frames on disk.
The Mac-audio sidecar shares the cadence; crash recovery re-renders it with
`SparseSidecarTailPolicy.tolerateTruncatedTail`, which salvages the torn
final record's whole-frame prefix (finalize stays strict). `AtomicFile`
`.full` falls back to `fsync` where `F_FULLFSYNC` is unsupported, and the
writer's `durabilityDegraded` flag tracks every barrier result live. Do not
reintroduce `AVAudioFile` for live journal writes.

## Deviations and user-approved additions

- The in-app shortcut remapper, Quick Move, universal recording (Mac system
  audio), and the microphone-failure ledger were added to this milestone by
  explicit user-approved addenda inside PRD-8.md.
- A 34-finding pre-flight audit-fix program ran after implementation
  (commits `d1aeb9f`…`0854940`). The ⌥M "types µ in text fields" audit
  finding is expected behavior by design: Quick Move defers to text editing.
- Power-loss durability hardening (the durable journal writer and
  `FileDurability`) was a user-approved standalone addition, followed by an
  adversarial durability audit whose refuted claims (torn size patch,
  capture-callback sync, `AtomicFile` fsync fallback, stale degraded flag,
  discarded torn-tail records) were all remediated in commit `75f6c9a`.
- Zen mode gained spacebar control (start when idle, pause/resume while
  active; Space never stops a take) at user request.
- Settings → Recording gained the explicit two-permission status section at
  user request.
- Quit-and-recover now preserves an active Mac-audio sidecar so recovery can
  mix it, matching crash recovery.

## Known issues

- The app remains ad-hoc signed; no Developer ID identity or notarization
  profile is installed on this machine.
- The system-audio permission row is inherently two-state: macOS provides no
  prompt-free way to distinguish "denied" from "never asked" for the Screen
  Recording TCC, and granting it may require an app relaunch to take effect.
- On volumes that reject `F_FULLFSYNC` entirely (some network shares and
  enclosures), the ≤ 5 s power-loss bound degrades to the volume's strongest
  primitive; `durabilityDegraded` records this and the app logs it at
  recording start, but no UI surfaces it yet. The sidecar has no equivalent
  degraded surface.
- A sidecar record-count field corrupted within its valid range at EOF is
  indistinguishable from a torn tail; lenient recovery bounds the damage to
  zero lost frames (every frame physically present is used) rather than
  detecting the corruption, which would require per-record checksums.
- Physical power-cut, USB-yank, and sleep/wake durability runs were reviewed
  analytically and via SIGKILL matrices, not on real hardware cuts.

## Fresh-model assumption

Assume you are a fresh model with zero context beyond this document and the
next milestone's PRD once one exists.
