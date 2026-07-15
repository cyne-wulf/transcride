# Transcride

Native macOS (Swift + SwiftUI, macOS 15+, Apple Silicon) voice recorder + transcription workbench: a Voice Memos superset where audio becomes searchable, editable markdown notes in a plain-file vault. Product spec: [master-prd-backup.md](master-prd-backup.md). Original idea: [vision.md](vision.md).

## Milestone workflow — hard rules

- **Current milestone: milestone 7 verified 2026-07-12; milestone 8 is not started.** Update this line only when the human confirms a milestone's full checklist.
- Work follows the milestone docs PRD-1.md … PRD-9.md, in order. Before any work, read the current milestone doc; for milestones 2+, also read its `PRD-<N>-start-here.md` handoff (written at the end of the previous milestone).
- **Never begin milestone N+1 until the human has confirmed every checklist item of milestone N.**
- Stay inside the current milestone's In/Out scope. Every Out item names the milestone where it belongs — defer it there.
- **Verification is interactive:** when the milestone's implementation is done, walk the human through the verification checklist as a step-by-step quiz — one item at a time, exact steps to perform, wait for pass/fail, fix and re-verify failures (plus any affected already-passed items). Only after all items pass, write the handoff document specified in the milestone's Handoff section. (The user may also trigger this with `/make-milestones verify`.)
- Do not relitigate anything under "Decisions already made" in the milestone docs.
- Commit when checklist items turn green; tag `milestone-<N>` at each verified gate.

## Build

- Project is defined in `project.yml` (XcodeGen). `Transcride.xcodeproj` is generated — never edit it by hand; edit `project.yml` and regenerate. New source files under `Transcride/` / `TranscrideTests/` are picked up by regenerating.
- Commands:
  - `xcodegen generate` — regenerate the project (required after adding/removing files)
  - `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' build`
  - `xcodebuild -project Transcride.xcodeproj -scheme Transcride -destination 'platform=macOS,arch=arm64' test`
  - `Scripts/make-fixture-vault.sh [count] [dir]` — generate a fixture vault (default 500 entries into `TestVault-500/`, gitignored)
  - `Scripts/make-long-entry-fixture.sh --source <entry-dir> [--hours 12]` — loop a real entry into a timed long-input fixture (default `TestVault-12h/`, gitignored; requires Python 3 + FFmpeg)
- Test target compiles `Transcride/Core` sources directly (no app host); app-layer/UI code lives in `Transcride/App` and `Transcride/UI` and is not unit-tested.
