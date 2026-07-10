# PRD-9 — Milestone 9: Motion, Insight & Release Polish (the lively soul)

> **Before starting:** read `PRD-9-start-here.md` (written at the end of Milestone 8) and [master-prd-backup.md](master-prd-backup.md) §4, §7, §11. **Do not start until the human confirms Milestone 8's checklist is verified.** Sized for a single ~200K-token session; orchestrate with full-context forks (PRD-5 procedure) if context runs low. This is the program's final milestone: it ends with the "IDE feel" acceptance scenario and leaves the app distribution-ready.

## Goal

Everything works; now make it *feel alive and finished*. A consistent motion language, an appearance layer with real taste, a view that shows the user their own thinking practice accumulating, a first-run that teaches the good parts, accessibility that holds up, and a build you could hand to a stranger. At the end of this milestone Transcride doesn't demo like a capable tool — it demos like a product someone loves.

## Scope

**In:** motion system + micro-interactions (MOT-1), appearance & empty-state personality (MOT-2), insights dashboard (INS-1) + per-entry stats (INS-2), onboarding tour & What's New (ONB-1), accessibility pass (ACC-1), release readiness (REL-1).
**Out (post-program, tracked in PROJECT-STATE.md):** cloud engines, vault sync, AI summarization/chapters, iOS, plugin system, localization.

## Requirements

### Motion system & micro-interactions (MOT-1)
- One `Motion` definition file (durations, spring parameters, easing) — every animation in the app references it; no ad-hoc `.animation(.default)` scattered in views. Honors Reduce Motion (crossfades replace movement) — audited, not assumed.
- The pass, applied everywhere but *calm* (this is a zen tool; nothing bounces for attention): entry-switch content transition; layer-toggle crossfade; waveform draw-in on entry open; record button idle "breathing" + press feedback; pause/resume icon morphs; tab open/close/reorder; palette/switcher appear+dismiss; panel (outline/backlinks/queue) slide; karaoke word-glow easing so highlight motion feels continuous rather than steppy; search-hit landing flash; favorite star pop; toast/notice enter/exit.
- Nothing animates during scrubbing or while the window is resizing (performance guard); 120 Hz-clean on ProMotion, no dropped frames while playing + highlighting (verify with Instruments once).

### Appearance & personality (MOT-2)
- Refined light/dark passes: one accent system derived from the user's macOS accent color, consistent secondary/tertiary hierarchies, vibrancy materials on sidebar/palette/popovers, and a Settings appearance pane (accent follow/custom, app font-size, always-dark option).
- Every empty state (empty vault, empty folder, no search results, empty trash, no favorites, no tags, empty queue) gets a designed treatment: a quiet illustration/glyph, one warm sentence, and the one action that makes sense there (e.g. empty vault → big Record button). Same voice throughout — the app's personality lives in this micro-copy; write it deliberately.
- App icon final pass (the M5 icon reviewed at all sizes) + a matching menu-bar glyph set; About window credits the engines (FluidAudio, WhisperKit) properly.

### Insights (INS-1, INS-2)
- **INS-1:** an Insights view (sidebar item): all-time and this-month totals (recordings, hours captured, words transcribed, notes hand-edited), a GitHub-style calendar heatmap of capture activity (click a day → that day's entries), current/longest daily streak. Computed from the vault snapshot + transcript metadata only — local, instant (<200 ms on 1,000 entries, cached and invalidated by vault revision), and honest (no gamification pop-ups; the view is *available*, never nagging).
- **INS-2:** the entry Info popover grows: words, words/minute, silence percentage (from the M4 gap model), and for diarized entries a per-speaker talk-time split bar.

### Onboarding & What's New (ONB-1)
- First-run (new users): a 4-card tour — vault concept ("plain files, yours"), record-everything flow, the transcript workbench (layers + click-to-seek demo on a bundled sample entry), power surface (⌘K/⌘O/shortcuts). Skippable, re-openable from Help. Folds in the permission asks at the moment each matters (mic on the record card, notifications on the queue card, hotkey on the power card).
- Existing users after update: a one-time "What's New" sheet generated from a bundled release-notes file.
- The bundled sample entry is created in-vault on first run (clearly titled "Welcome to Transcride", deletable like anything else).

### Accessibility (ACC-1)
- VoiceOver: every control labeled (audit the custom views: waveform, trim handles, tab bar, palette rows, heatmap cells); the transcript view reads as continuous text; playback state changes announced.
- Full-keyboard operability audit: every checklist-verifiable flow in milestones 1–8 completable with keyboard alone (tab order, focus rings on custom controls).
- Contrast: all text/interactive elements pass at 4.5:1 in both appearances including over vibrancy; karaoke highlight distinguishable without color (weight/underline component).

### Release readiness (REL-1)
- Real `CFBundleShortVersionString`/build numbers (fixes the `engine.app_version: "0 (0)"` debt); Archive → Developer-ID-signed, notarized, stapled `.dmg` produced by a repeatable `Scripts/release.sh`; the app launches clean from a fresh user account (no dev-machine assumptions).
- Update check: **opt-in** ("Check for updates automatically" off by default, honoring the no-network principle), simple version-manifest check against a static URL with a "download" link-out — no auto-installing framework in this milestone. Manual "Check for Updates…" always available.
- Crash-resilience audit: the §8 guarantees re-verified on the release build (queue survives relaunch, no entry-folder corruption on kill during write — spot-test, they're covered by design).

## Decisions already made (do not relitigate)
- Calm motion doctrine: durations ≤ 350 ms, no bounce/overshoot on content, playful energy allowed only on the record button and favorite star. When in doubt, less.
- Insights carry **no goals/badges/notifications** — a mirror, not a coach. Streaks display only once ≥ 2 days exist.
- Sparkle (or any auto-update framework) is deliberately excluded; the static-manifest check is the v1.x ceiling. Revisit post-program only with the human.
- Words/minute uses spoken-time denominator (duration minus silence gaps), labeled as such.
- No telemetry/crash reporting of any kind — the privacy principle is absolute.
- Localization stays out (English-only), but no new user-facing string may be constructed by concatenation (keeps the door open).

## Definition of done
- All requirements implemented; unit tests for: insights aggregation (totals, heatmap bucketing, streaks incl. gap/timezone edges), talk-time split math, release-notes parsing, version-manifest comparison. `xcodebuild test` passes, no regressions.
- Instruments pass on ProMotion showing no dropped frames during playback + karaoke + one panel animation.
- `Scripts/release.sh` produces a notarized dmg from a clean checkout.

## Verification checklist (human-run — completes the polish program)

**Interactive, one item at a time, human confirms each** (same protocol). *Preparation: a second (clean) macOS user account; System Settings → Accessibility handy for Reduce Motion/VoiceOver; a ProMotion display if available.*

- [ ] Flip through the app for five minutes with the motion pass on: entry switches, layer toggle, tabs, palette, panels all move with one consistent character; nothing bounces; nothing animates while scrubbing.
- [ ] Enable Reduce Motion: every animated transition above becomes a crossfade/instant equivalent — spot-check six surfaces.
- [ ] Karaoke glow during playback feels continuous (no per-word stutter) at 1× and 2×.
- [ ] Change macOS accent color: the app follows; set a custom accent in Settings: it overrides; both appearances (light/dark) look deliberate on the six main surfaces.
- [ ] Visit all seven empty states (vault/folder/search/trash/favorites/tags/queue): each shows its designed treatment and its one sensible action works.
- [ ] Insights: totals match a hand-count on a small scratch vault; heatmap day-click filters correctly; streak math correct across a known gap; the view renders instantly on TestVault-1000.
- [ ] Info popover on a diarized entry: words/minute plausible, silence %, and a speaker split that matches the conversation's reality.
- [ ] Create a fresh vault in the clean user account: the tour runs, permissions are asked in context, the Welcome sample entry plays + click-to-seek works, tour is re-openable from Help; second launch shows no tour; a bumped bundled release-notes file shows What's New once.
- [ ] VoiceOver-only: record a memo, stop, play it back, and favorite it — completable and comprehensible by announcement alone.
- [ ] Keyboard-only: full flow — record (⌘N), stop, wait for transcript, open (⌘O), edit, save, search (⌘⇧F), jump to hit — without touching the pointer.
- [ ] About window: correct version/build (not "0 (0)"), engine credits; new transcriptions record the real app version in `engine.app_version`.
- [ ] Run `Scripts/release.sh`: dmg builds, is notarized (`spctl -a` accepts), installs and launches in the clean account; opt-in update check correctly reports up-to-date vs a staged newer manifest.
- [ ] Regression sweep: one item each from M6 (palette), M7 (wikilink follow), M8 (menu-bar capture) still passes on the release build.
- [ ] `xcodebuild test` passes.
- [ ] **Program acceptance ("tool → IDE"):** in one continuous sitting on the release build — global-hotkey capture a thought from another app → notification when it lands → ⌘O to it → clean it up with live-styled markdown, link it `[[...]]` to a related note → ⌘K "Compare Layers" to review your changes → tag it → find it via a filtered fuzzy search → export it to Obsidian — every step keyboard-first, visually coherent, and pleasant enough that you'd show someone. The human's verdict on that last clause is the gate.

## Handoff (required, after the checklist is verified)

Update **`PROJECT-STATE.md`** to cover the full program (Milestones 1–9): final architecture and file map; all deviations by milestone; ranked tech debt; the deferred list (cloud engines, sync, AI features, iOS, plugins, localization, auto-update framework) with hook-in points; build/test/release instructions including `Scripts/release.sh` and notarization credentials setup. This document plus [master-prd-backup.md](master-prd-backup.md) is the starting context for whatever comes next.
