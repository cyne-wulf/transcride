# PRD-3 Start Here — Milestone 2 handoff

> Assume you are a fresh model with zero context beyond PRD-3.md and this document.

## Project summary

Transcride is a native macOS (Swift 6 + SwiftUI, macOS 15+, Apple Silicon, App Sandbox) voice recorder + transcription workbench whose entire data layer is a plain-folder **vault**. Milestone 1 (tag `milestone-1`) delivered the vault foundation and app shell. Milestone 2 (verified 2026-07-09, tag `milestone-2`) delivered the Voice Memos core: crash-safe recording with pause/resume and live waveform, mic selection, zen mode, AAC/ALAC quality, multi-file import (drag or ⌘⇧I) with per-file errors, and pitch-preserved playback (0.5×–4×) with a scrubbable waveform. Every recording/import already calls the transcription seam (a logged no-op) — M3 replaces that no-op with a real queue.

## Build / run / test

- `project.yml` (XcodeGen) defines the project; `Transcride.xcodeproj` is generated and **gitignored** — after adding/removing source files run `xcodegen generate`.
- Build: `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build`
- Test: same command with `test` (57 tests, 10 suites; the test target compiles `Transcride/Core` directly, no app host — `App`/`UI` code is not unit-tested and must not be referenced from tests).
- Run: **after every build, deploy to /Applications and launch from there** (user preference — they launch via Spotlight):
  `ditto ~/Library/Developer/Xcode/DerivedData/Transcride-*/Build/Products/Debug/Transcride.app /Applications/Transcride.app && pkill -x Transcride; open /Applications/Transcride.app`
- Fixtures: `Scripts/make-fixture-vault.sh [count] [dir]` (default 500 entries → `TestVault-500/`, gitignored). `TestVault-A/` is the small manual vault. Import-test media (mp3/wav/m4a/flac/mp4/corrupt) lives in `TestVault-materials/import-samples/`.

## File map

**Transcride/Core** (pure, unit-tested, no AppKit/SwiftUI):
- `EntryFolderName.swift` — parse/build `transcride-<timestamp>[-slug]` folder names; timestamp ↔ Date.
- `Slug.swift` — `Slug.make(from:)`: lowercase-hyphen slugs, ≤40 chars.
- `TranscriptFile.swift` — transcript file naming + discovery (see contract below).
- `Frontmatter.swift` — line-preserving YAML frontmatter parser/serializer (`FrontmatterDocument`); unknown keys round-trip byte-exact; typed accessors title/created/duration/favorite/audioDeleted/source/engine.
- `AtomicFile.swift` — `AtomicFile.write(_:to:)`: temp file + `rename(2)`. **All vault writes must go through this** (including `transcript.original.json` in M3).
- `VaultModels.swift` — `RelativePath`, `Entry` (now has `audioFileName: String?`; `hasAudio` is computed from it), `FolderNode`, `VaultSnapshot`, `VaultError`.
- `VaultScanner.swift` — recursive scan → snapshot; mtime cache; **filters hidden files** (in-progress recordings are invisible); `audioFile(in:)` prefers basename `audio`, else alphabetical.
- `VaultOperations.swift` — createFolder/renameFolder/renameEntry/moveItem.
- `TrashStore.swift` — `.trash/` + sidecars; restore, permanent delete, 30-day purge.
- `WaveformData.swift` — `waveform.json` Codable model + `WaveformBuilder` streaming peak accumulator (shared by live recording and offline generation).
- `WaveformGenerator.swift` — offline waveform via AVAssetReader (audio files and video containers' audio tracks); cancellation-aware. (AVFoundation, but no UI — lives in Core and is tested.)
- `AudioImport.swift` — `AudioImportFormat`: supported extensions, filename sanitization, title-from-filename, `probeDuration(of:)` (typed per-file errors).
- `EntryCreator.swift` — entry-folder creation with +1 s timestamp-collision retry; `writeRecordingStub` (recordings); `importFile` (copies source, writes titled stub, cleans up on failure).

**Transcride/App** (app layer, @MainActor unless noted):
- `TranscrideApp.swift` — @main; File-menu commands: Start/Stop Recording (⇧Space), Import Audio… (⌘⇧I).
- `AppModel.swift` — `@Observable` view model; owns `RecorderService`, `PlayerService`, `AudioInputDevices`, selection state; global NSEvent key monitor (see Keyboard section); recording/import/delete intents.
- `VaultService.swift` — `actor` owning all file I/O: scan, operations, trash, `createEntryFolder`, `importAudioFile`, `waveform(forEntryAt:audioFileName:)` (loads cache, else generates + writes).
- `RecorderService.swift` — the recording pipeline (see below) + `RecordingQuality` (aac/alac, UserDefaults key `recordingQuality`).
- `PlayerService.swift` — AVPlayer playback (see below).
- `AudioInputDevices.swift` — CoreAudio input-device enumeration, auto-refreshing on device changes; UserDefaults key `preferredMicUID` ("" = system default).
- `TranscriptionSeam.swift` — **the M3 seam** (see below).
- `VaultBookmark.swift`, `FSEventsWatcher.swift` (IgnoreSelf → explicit refresh after in-app writes), `DebugLog.swift` (always-on dev log).

**Transcride/UI**: `RootView`, `WelcomeView`, `MainView` (3-pane + recorder bar `safeAreaInset` + drag-drop + zen overlay), `SidebarView`, `EntryListView` (no delete confirmation — trash is restorable), `EntryDetailView` (+ `PlaybackSection`: waveform, transport, speed chip; controls scale with window width), `RecorderBar`, `ZenModeView`, `WaveformView` (+ `LiveWaveformView`), `RecentlyDeletedView`, `SettingsView` (Recording section: mic + quality).

**TranscrideTests**: `TestAudio.swift` makes real WAV fixtures; suites cover frontmatter, slugs, folder names, transcript naming, atomic writes, scanner, trash, waveform builder/generator/schema, import formats, entry creation.

## Audio pipeline architecture

### Capture (RecorderService)

`AVAudioEngine` input tap (4096 frames) → `AVAudioConverter` (to the file's processing format: mono 44.1 kHz Float32) → `AVAudioFile` encoding **AAC 64 kbps or ALAC into a hidden `.recording.caf`** in the entry folder. CAF is valid from the first buffer, so a crash mid-recording leaves a playable partial file — this is why recording doesn't write m4a directly (m4a finalizes its moov atom only on close). The tap thread hands buffers to `RecordingSink` (`@unchecked Sendable`, NSLock-guarded), which writes the file, accumulates waveform peaks via `WaveformBuilder`, and posts elapsed/peaks back to the main actor. Mic selection = `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` on the input node **before** reading its format. Device loss (`.AVAudioEngineConfigurationChange`) → auto-pause + alert.

Call path: `AppModel.startRecording()` (permission → `VaultService.createEntryFolder` → `recorder.start(entryURL:relativePath:quality:preferredMicUID:)`), then `recorder.pause()/resume()`, then `AppModel.stopRecording()` → `recorder.stop() async`.

### Finalization (`RecorderService.finalize`, nonisolated static)

On stop: passthrough remux (no re-encode) `.recording.caf` → `audio.m4a` via `AVAssetExportSession(presetName: AVAssetExportPresetPassthrough).export(to:as:)`; on remux failure the CAF is kept as `audio.caf` (the scanner accepts any audio extension). Then `waveform.json` is written from the live-accumulated peaks (free), and the stub transcript is written. Duration = frames written / sample rate — pauses are excluded by construction.

### Playback (PlayerService)

`AVPlayer` + `AVPlayerItem` with `audioTimePitchAlgorithm = .timeDomain` (pitch-preserved 0.5×–4×, speech-tuned; AVPlayer so mp4/mov imports play their audio track). 30 Hz periodic time observer; zero-tolerance seeks. Call path: `player.load(url:knownDuration:)` (no-op if same URL), `play/pause/togglePlayPause`, `seek(toFraction:)`, `skip(±15)`, `speed` property. `AppModel.selectedEntryID.didSet` unloads on entry switch.

### Waveform (`waveform.json`)

```json
{ "version": 1, "peaksPerSecond": 20, "duration": 123.45, "peaks": [0.031, 0.482, …] }
```

`peaks` = max-abs amplitude per 50 ms window, clamped 0…1, rounded to 3 decimals. A rebuildable cache: recordings get it free at stop; imports generate lazily on first open (`VaultService.waveform(forEntryAt:)` → `WaveformGenerator`); deleting it regenerates on next open. There is deliberately no in-memory cache. **M3 note:** transcription must read the audio file, not assume format — use `AVURLAsset`/`AVAudioFile` on whatever `Entry.audioFileName` points to (m4a, caf, mp3, flac, wav, ogg, opus, aiff, or an mp4/mov video).

## The M3 seam — replace this

**File: `Transcride/App/TranscriptionSeam.swift`, function: `TranscriptionSeam.audioEntryReady(entryRelativePath:source:)`.**

It is called exactly once per finalized audio entry, from two places in `AppModel`:
- `stopRecording()` — after refresh + selection, `source: .recorded`
- `importFiles(_:)` — per successful import, `source: .imported`

Today it just logs. M3: replace the body (or swap the call sites) with transcription-queue enqueueing using the default model. Keep the call sites as the single integration point — nothing else in the app knows about transcription.

## Stub transcript format — M3 must replace the body

Recordings (`EntryCreator.writeRecordingStub`) produce `transcript.md`:

```markdown
---
title: "New Recording"
created: 2026-07-08T14:30:00-07:00
duration: 42.5
source: recorded
---
```

(empty body). Imports produce `<Title>.md` (titled from the filename) with `source: imported`, also empty body. M3 rewrites the body with transcript text and adds `engine`; **parse with `FrontmatterDocument`, edit fields, re-serialize — never regenerate frontmatter from scratch** (unknown keys must survive). Auto-title (TRN-7): only replace title "New Recording"; rename the file via `TranscriptFile.fileName(forTitle:)` and update the folder slug via the M1 rename flow (`VaultOperations.renameEntry` does both).

### Transcript naming contract (from M1 — still binding)

- Untitled entry → `transcript.md`; titled → `<Title>.md`. Discovery via `TranscriptFile.find(in:)` — never hard-code the name.
- Frontmatter keys: `title`, `created`, `duration`, `favorite`, `audio_deleted`, `source`, `engine`.

## Keyboard (one global monitor — extend it, don't add SwiftUI shortcuts)

`AppModel.installKeyMonitor()` (NSEvent local monitor) owns app-wide keys, deferring to focused text views first: **Space** = recorder pause/resume while recording, else playback play/pause; **⇧Space** = start/stop recording (File-menu item carries the visible shortcut); **⇧Delete** = move selected entry to trash, no confirmation. Plain-space SwiftUI `.keyboardShortcut`s proved unreliable across focus states — put new global keys in this monitor.

## AVFoundation / Swift 6 gotchas (each cost real debugging time)

1. **Audio-tap closures must be `@Sendable`.** A closure formed inside a `@MainActor` method inherits main-actor isolation and the runtime **traps (dispatch_assert_queue) on the first buffer** from AVFAudio's realtime queue. Mark tap/callback closures `{ @Sendable buffer, _ in … }`. This crashed the app on first record click during verification.
2. **`AVAudioFile` encodes on write** when opened `forWriting` with AAC/ALAC settings + a PCM `commonFormat` — no manual encoder needed. But the input must match `file.processingFormat`; run an `AVAudioConverter` when the device format differs (it usually does — e.g. 48 kHz stereo mic → 44.1 kHz mono file).
3. **`AVAssetExportSession` passthrough CAF→m4a works for AAC and ALAC** (verified both). Modern API: `try await session.export(to:as:)`; the session-property variants are deprecated in macOS 15.
4. **`AVAudioConverter` input blocks are `@Sendable`** — you can't capture a mutable "consumed" flag; use a small `@unchecked Sendable` box with a take-once accessor (`ConverterFeed` in RecorderService).
5. **`AVLinearPCMIsNonInterleaved`** is the Swift constant name — not `AVLinearPCMIsNonInterleavedKey`.
6. **NSEvent isn't Sendable** — in an event monitor, extract primitives (keyCode, modifierFlags) before hopping to the main actor.
7. **Set the input device before `inputNode.outputFormat(forBus:)`** — the format is latched when first read; selecting the device afterward records from the wrong mic.
8. Mic permission: `AVCaptureDevice.requestAccess(for: .audio)`; entitlement `com.apple.security.device.audio-input` + `INFOPLIST_KEY_NSMicrophoneUsageDescription` are already in `project.yml`.

## Known issues / tech debt

- `DebugLog` is always-on; gate before release.
- Entry detail body is read-only `Text` — the editor is M4 (do not build editing in M3; only regenerate `transcript.md` bodies).
- SwiftUI gotcha from M1 still applies: dialog button actions run after `isPresented` clears — keep payloads in separate `@State`.
- `PlaybackSection` reloads `waveform.json` on every entry open (one small file read; fine at current scale).
- The recorder-bar mic menu reads devices at open; a device plugged in while the menu is already open won't appear until reopened (the underlying `AudioInputDevices` list does auto-refresh).
- macOS 26 is the dev machine's OS (`SpeechTranscriber` availability there is real — gate on `#available(macOS 26, *)` and hide below, per PRD-3).
