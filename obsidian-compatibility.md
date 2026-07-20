# Obsidian Compatibility

What it means for a Transcride vault to be compatible with Obsidian, in increasing depth. The master PRD's v1 bar is "the vault opens in Obsidian and every note renders correctly" (§11) — that is Tier 1. Tiers 2 and 4 are cheap extensions that mostly land in milestones 4–5. Two-way coexistence includes round-tripping unknown frontmatter, external-edit watching, and loose audio-less notes; Transcride preserves wikilinks but intentionally does not rewrite inbound links when a target is renamed.

## Tier 1 — Obsidian can read the vault (v1, already planned)

- Valid CommonMark that Obsidian renders — PRD-4's EDT-1 already requires this.
- YAML frontmatter that Obsidian's Properties panel parses cleanly, which means **typed** values: `created` as an ISO date, `favorite` as a real boolean, duration as a number. Obsidian shows unparseable frontmatter as a red "invalid properties" block, so this is where "renders correctly" actually gets decided.
- Human filenames: a titled entry's transcript is `<Title>.md` (see `TranscriptFile.swift`; decided during milestone 1 verification, recorded in `PRD-2-start-here.md`).
- Ignore `.obsidian/` and `.trash` — the vault scanner already skips dot-items, so a vault that has been opened in Obsidian doesn't confuse Transcride.

## Tier 2 — the vault feels native in Obsidian

- **Use Obsidian's reserved frontmatter keys** instead of inventing parallel ones: `tags` (a YAML list, so Obsidian's tag pane picks them up — folds into LIB-5) and `aliases`. Transcride-specific fields (`engine`, `model`, `audio_deleted`, `source`, `duration`) go under plain custom keys, which Obsidian displays as properties for free.
- **Embed the audio in the note**: Obsidian plays `![[recording.m4a]]` embeds natively. One line at the top of the transcript makes every entry *playable inside Obsidian*, not just readable. Highest value-per-effort item not currently in any PRD.
- **Folder-note convention**: entry folder `<Title>/` containing `<Title>.md` is exactly the community "folder note" pattern — keep folder and file names in sync on rename so it stays true.
- **Don't mangle Obsidian syntax on save**: wikilinks `[[...]]`, `==highlights==`, callouts, `%%comments%%` must survive a round-trip through Transcride's editor. Milestone 9 defines which constructs receive visible-source styling; preservation is mandatory whether styled or not. (Constraint on milestone 4's editor/autosave.)

## Tier 4 — integration niceties

- An **"Open in Obsidian"** menu item via the URI scheme (`obsidian://open?vault=…&file=…`) — trivially cheap.
- Respect the destination vault's `.obsidian` config (attachment folder, new-note location) when exporting into a real Obsidian vault (EXP-2 territory).
- Plugin-ecosystem friendliness: Dataview-queryable frontmatter falls out of Tier 2 for free if the keys are typed consistently.
