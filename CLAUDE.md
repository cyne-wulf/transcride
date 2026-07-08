# Transcride

Native macOS (Swift + SwiftUI, macOS 15+, Apple Silicon) voice recorder + transcription workbench: a Voice Memos superset where audio becomes searchable, editable markdown notes in a plain-file vault. Product spec: [master-prd-backup.md](master-prd-backup.md). Original idea: [vision.md](vision.md).

## Milestone workflow — hard rules

- **Current milestone: 1 (not started).** Update this line only when the human confirms a milestone's full checklist.
- Work follows the milestone docs PRD-1.md … PRD-5.md, in order. Before any work, read the current milestone doc; for milestones 2+, also read its `PRD-<N>-start-here.md` handoff (written at the end of the previous milestone).
- **Never begin milestone N+1 until the human has confirmed every checklist item of milestone N.**
- Stay inside the current milestone's In/Out scope. Every Out item names the milestone where it belongs — defer it there.
- **Verification is interactive:** when the milestone's implementation is done, walk the human through the verification checklist as a step-by-step quiz — one item at a time, exact steps to perform, wait for pass/fail, fix and re-verify failures (plus any affected already-passed items). Only after all items pass, write the handoff document specified in the milestone's Handoff section.
- Do not relitigate anything under "Decisions already made" in the milestone docs.
- Commit when checklist items turn green; tag `milestone-<N>` at each verified gate.

## Build

- Xcode project does not exist yet — Milestone 1 sets up scaffolding. Prefer XcodeGen (project defined in `project.yml`) so the project file stays agent-editable. Build and test via `xcodebuild` CLI. Record the exact commands here once they exist.
