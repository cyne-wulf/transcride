# Purpose
- This app is designed to be a browser and creator for transcriptions
- It should also be a zen space to monologue into as an audio journal creator.
- The name, transcride, is a combination of transcribe + IDE which is a sort of workbench for software engineers. This should feel like a workbench/IDE experience but for browsing through your transcriptions to cultivate knowledge for exporting to a proper knowledge system.


# Capabilities
- The user should be able to upload audio files of most common types and have them transcribed using the model of their choice, with Parakeet as the default. We should have a drop down selector with some suggested models as well, do research to determine the top 5 options
- The audio file should remain attached to the transcription, when the audio is playing, the current word in the transcription should be highlighted and the viewport should automatically scroll to show it.
- I can edit the transcription in place, and it would save the original transcription copy statically and overlay the edited version on top of it with the ability to toggle between them using a badge next to the copy as markdown button on the top right. (This is note taking functionality.)
- Retranscribe should also be an option, and allow the user to select if they want the transcription to feature speaker detection or not.
- If storage becomes a concern, I can delete the associated audio file and just keep the transcriptions, ideally this would be a button on the voice note when it's pulled up in the interface. This would free a massive amount of storage and keep one hundred percent of the information. Add a warning dialogue before deletion and after it's done, grey out options related to the audio like "retranscribe" and convert into essentially a note. (That's why this app should essentially be like a note editor)
- Easy file management, button to reveal file in explorer and a logical storage scheme that allows the user to select their own "transcride folder" similar to how obsidian uses vaults.
- Full text search across all transcriptions, with results that jump to the matched position in the transcript (and to the audio moment if the audio still exists).
- Search has a big switch to toggle fuzzy finding on or off. Exact text match is the default.
- A custom vocabulary list: many speech-to-text models support "vocabulary boosting" (also called contextual biasing or keyword boosting), where a list of custom words is fed to the model before transcription so it biases recognition toward them. Users can add words (names, jargon, product terms) that models have trouble with out of the box, and the list is passed to the selected model using whatever mechanism that model supports. Support varies by engine, so this needs research per model during requirements.


## Voice Memos parity (superset)
Transcride is a superset of the macOS Voice Memos app: every Voice Memos feature has an equivalent here, plus the transcription workbench on top.

- Recording: one-click record, pause/resume mid-recording, live scrolling waveform while recording, and microphone input selection.
- The waveform is a first-class playback surface: drag to scrub/seek, shown alongside the synced transcript. Clicking a word seeks the audio; scrubbing the waveform scrolls the text.
- Playback controls: skip back/forward 15 seconds, playback speed (0.5x-2x), and Skip Silence (word timings from transcription give us the silence map).
- Audio editing: trim/crop and replace (re-record over a section). Note: audio edits invalidate word timestamps, so edits trigger retranscription of the affected region (or the whole file).
- Enhance Recording: noise and reverb reduction.
- Organization: favorites, folders, duplicate recording, inline rename, and auto-titling from the first line of the transcript.
- Recently Deleted: deleted recordings and deleted audio are held for 30 days before permanent purge. This is extra important given the delete-audio-keep-transcript flow.
- Recording quality settings (compressed vs lossless).
- Sync across devices: Voice Memos has iCloud sync; the local vault model makes this nontrivial. In scope for the product vision, but likely a later phase (vault-in-iCloud-Drive may get most of the way for free).


# Proposed architecture
- Files on disk are the source of truth, exactly the way Obsidian handles files. The app renders the file system; it does not hide it behind a database.
- The user selects a "transcride vault" root folder. Any subfolder inside the vault is treated as a folder and rendered as such in the UI. Folders created in the UI appear on disk, and folders created on disk appear in the UI.
- Each note/transcription pair is a folder with a prefixed name like `transcride-<timestamp>` (e.g. `transcride-2026-07-08T14-32-05`). Moving an entry between folders in the UI moves its folder on disk.
- Inside each entry folder:
  - The audio file (kept in its original/recorded format, e.g. `audio.m4a`).
  - The original transcription, stored statically and never modified after creation.
  - The editable copy of the transcription, a markdown file — this is what the user edits in the app and what other tools (like Obsidian) can read directly.
- All file names inside the entry folder follow a sensible, self-describing scheme that makes perfect sense to a technologically literate person browsing the vault in Finder — everything should be intuitive without the app.
- Refinements to work out during requirements (the structure can change if it has glaring problems):
  - The original transcription needs word-level timestamps to power highlight-sync, click-to-seek, and Skip Silence — plain text can't hold those. Likely shape: a machine-readable original (e.g. `transcript.original.json` with word timings) plus the human-readable editable copy (e.g. `transcript.md`).
  - Per-entry metadata (title, favorite, model used, duration, audio-deleted state) needs a home: either frontmatter in the editable markdown (Obsidian-style) or a small `meta.json` in the entry folder.
  - Recently Deleted maps naturally to a `.trash/` folder inside the vault, purged on the 30-day schedule.
  - Entry folder naming vs. renaming: whether the user's title lives only in metadata or is also appended to the folder name (e.g. `transcride-<timestamp>-<slug>`) needs a decision — folder-name titles are more browsable in Finder but make renames a file-system operation.


# UX
- HEAVY inspiration from the voice memos app on MacOs, that should be the starting point for everything, coded in Swift
- Blend in Obsidian Note taking app elements and patterns where voice memos doesn't have an analogous component



