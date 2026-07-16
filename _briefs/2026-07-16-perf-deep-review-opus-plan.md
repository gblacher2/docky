# Docky Performance Deep Review — Opus Session Plan

**Date:** 2026-07-16
**Run this session in:** `~/GitHub & Coding Projects/local-docky` (NOT docky-personal — that repo is only the config/release hub and contains no app code)
**Goal:** Diagnose and fix the lag Gabriel feels in his personal Docky build. Performance only — no new features, no visual changes to the Gabriel Glass theme.

**Primary complaint (confirmed by Gabriel, 2026-07-16): the hover sweep.** Moving the mouse across the dock — the 44 → 56 pt magnification gesture — is where the lag is felt most. Treat the mouse-move → re-render path as the primary target; everything else is secondary.

---

## Before anything else

1. The working tree has ~10 modified files (personal-triggers work on top of commit `57faffb`). Commit or stash them first so every measurement runs against a known, clean baseline. Do not discard them.
2. Confirm the build works before touching code:
   ```bash
   xcodebuild -project Docky.xcodeproj -scheme Docky \
     -configuration Debug -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO build
   ```
3. Read `AGENTS.md` — it carries the Swift 6 strict-concurrency and SwiftUI/AppKit bridging patterns this repo uses. Fixes must follow them.

## Phase 0 — Measure before guessing (do not skip)

"Feels laggish" is not a bug report yet. Turn it into reproducible scenarios and baseline numbers:

1. **Define the lag scenarios.** Gabriel has already answered: the hover sweep is the one that hurts. Measure it first and most thoroughly; keep the others as a cheap baseline sweep to catch anything that compounds it:
   - **PRIMARY: mouse sweep across the dock (magnification 44→56 pt)** — frame pacing, hitching, main-thread stalls, and CPU% during a continuous 3–5 s left-to-right sweep. Measure with a mostly-empty dock vs. the full Daily profile (with Context Hub and widgets) to see whether cost scales with tile count — that distinguishes O(n) body re-evaluation from a fixed per-frame cost like live blur.
   - Idle CPU % with dock visible but untouched (target: ~0%)
   - App launch / bounce animation
   - Profile switch (Daily ↔ CFA Study ↔ Build/Code ↔ Desk)
   - Launchpad overlay open/close
   - With vs. without the five external widgets loaded
2. **Baseline with real tools**, not eyeballing:
   - `sample Docky 5 -file /tmp/docky-sample.txt` while reproducing each scenario; look for main-thread stacks
   - Activity Monitor / `top -pid` for idle CPU and energy
   - Instruments if available: Time Profiler, SwiftUI (view body counts), Core Animation FPS
   - Add `os_signpost` intervals around suspect paths if needed to attribute cost
3. Record baseline numbers in the findings report. Every fix later must show a before/after against these.

## Phase 1 — Investigate the ranked suspects

A preliminary static scan (2026-07-16) found these. The list is ordered for the hover-sweep complaint: items 1–3 sit directly on the mouse-move → magnify → render path and are the primary suspects. Verify each against the Phase 0 profiles before fixing — profile data outranks this list.

1. **`Docky/Views/Tiles/TileView.swift` (3,319 lines, SwiftUI) + `TileContainerView.swift` (2,317). Primary suspect.** Trace the full event path: who receives mouse-move (NSTrackingArea? SwiftUI `onContinuousHover`?), where the cursor position/hover state lives, and which views observe it. The classic failure: cursor position stored in a shared observed object → every tile's `body` re-evaluates on every mouse event at 60–120 Hz → O(n) view diffing per frame. Also check: missing `Equatable`/`EquatableView` on tiles, non-lazy stacks, magnification animating layout-affecting properties (frame/size, which relayouts the whole row) instead of `scaleEffect`/transforms, and shadow/glass effects re-rendering per frame during scale.
2. **`Docky/Views/Modifiers/LiveGlassBackdrop.swift` + `DockyGlass.swift`. Primary suspect.** "Live glass" sampling/blur behind the dock is a per-frame GPU/CPU cost, and Gabriel Glass uses it everywhere. During a sweep, if each tile's glass backdrop re-samples as tiles scale, cost multiplies by tile count. Check sampling cadence, whether it re-renders during magnification, and whether it runs while idle.
3. **`Docky/Services/DockyPreferences.swift` (4,525 lines). Primary suspect if hover state touches it.** Dozens of `didSet` observers starting ~line 1131. Two questions: (a) is this one giant `ObservableObject` that every SwiftUI view observes, so *any* change invalidates *every* view body — and does anything on the hover path (hover scale, magnification progress, last-hovered tile) write into it? (b) do the `didSet`s write to UserDefaults/disk synchronously? Likely structural fix: split into focused observable slices and/or debounce persistence.
4. **`Docky/Services/WindowRegistry.swift` (1,236) and `WorkspaceService.swift` (1,385).** Both use the AX API (`AXUIElement`) — synchronous IPC that can block the main thread mid-sweep if an AX event lands during the gesture. WindowRegistry registers 5 observers. Check for AX calls on the main thread, per-event full rescans, and observer churn. `DockBadgeService.swift` also touches AX.
5. **Timers.** `ProfileTriggerEngine` (×2), `SystemStatusService`, `FocusFlowBridge`, `DockDragService`, `BatteriesService`. A timer firing heavy work mid-sweep shows up as a periodic hitch rather than uniform slowness — if Gabriel's lag is intermittent stutter, look here. Wi-Fi/display trigger polling in ProfileTriggerEngine is new (personal-triggers work) — verify it isn't polling aggressively.
6. **Widget tiles.** `NowPlayingWidgetTileView` (756), `CalendarWidgetTileView` (750), `MediaPlaybackService` (723), plus the five external widgets from `docky-personal-widgets` (CFACountdown, Clipboard, MarketsWatchlist, Pomodoro, Scratchpad). Widget tiles magnify too — check whether their bodies are heavy to re-evaluate (date formatting, image decoding, attributed strings built per body call) and their refresh cadence.
7. **Overlay window controllers** (`LaunchpadOverlayWindowController` 2,220 lines, DockEditor, StartMenu, WindowSwitcher, WindowPreview). Check whether any stay live (rendering/observing) while invisible, contributing background cost during the sweep.

## Phase 2 — Fix, in measured-impact order

- Fix the top offenders from profiling, **one fix per commit**, each with a before/after measurement in the commit message.
- Prefer quick wins first (timer intervals, debounced writes, gating idle work) and take structural changes (splitting `DockyPreferences`, tile-render architecture) only when profiling proves they're the cost.
- Constraints:
  - No behavior or visual changes — Gabriel Glass must look and act identical (44 pt tiles, 56 pt magnification, glass materials, indicators).
  - Follow the Swift 6 concurrency and AppKit/SwiftUI patterns in `AGENTS.md`.
  - Don't touch `docky-personal` (config hub) or the importer contract.
  - No dependency additions.

## Verification / acceptance criteria

1. Debug build succeeds (command above, exit 0).
2. Existing tests pass: run the `DockyTests` target via `xcodebuild test` (same flags).
3. Re-run every Phase 0 scenario and report before/after numbers. Targets (hover sweep is the gate — the session isn't done until it passes):
   - **Hover sweep: steady frame pacing at the display's refresh rate with no main-thread stall > 16 ms during a continuous 3–5 s sweep across the full Daily profile.** Subjective check too: run the built app and sweep — it should feel like the native macOS Dock.
   - Idle CPU ≈ 0–1% with dock visible, no interaction
   - Profile switch and Launchpad open feel instant (< 100 ms to first frame)
4. Run the built app and describe observed behavior (per `CONTRIBUTING.md`).

## Deliverables

1. **Findings report** (`_briefs/2026-07-16-perf-deep-review-findings.md`): each confirmed issue with evidence (profile excerpt or measurement), ranked by measured impact; suspects investigated and cleared; anything found-but-deferred.
2. **Fix commits**, one per issue, on a dedicated branch (e.g. `perf-deep-review`), each with before/after numbers.
3. **Deferred list** — structural work judged too risky to mix into this pass, so it can become its own brief later.

## Out of scope

- New features of any kind (that's the point — perf first)
- Visual/theme changes, widget feature changes
- Refactors not justified by a measurement
- The `docky-personal` and `docky-personal-widgets` repos (except reading widget code to attribute cost; if a widget is a top offender, note it in the findings for a separate pass)
