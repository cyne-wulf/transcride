# Transcride

Transcride is a native, local-first macOS voice recorder and transcription
workbench. Record or import audio, transcribe it on-device, edit the result as
Markdown, search the whole vault, and delete the audio when the text is all you
want to keep.

Version 1.0 is built for Apple silicon and macOS 15 or later.

## What it does

- Records compressed AAC or lossless ALAC audio and imports common audio/video formats.
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

See [PROJECT-STATE.md](PROJECT-STATE.md) for the architecture, known limitations,
and contributor handoff. Product intent and requirement history live in
[master-prd-backup.md](master-prd-backup.md) and the milestone PRDs.

## Release status

Milestones 1–5 and the v1.0 acceptance workflow were human-verified on
2026-07-11. The repository declares version `1.0.0` build `1`.

Binary distribution still requires a Developer ID Application certificate and
Apple notarization credentials; local builds are ad-hoc signed for development.
