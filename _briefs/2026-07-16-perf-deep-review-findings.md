# Docky Performance Deep Review — Findings

**Date:** 2026-07-16
**Branch:** `perf-deep-review` (baseline commit `402cf55`, on top of `57faffb`)
**Scope:** Performance only. Primary target: the hover sweep (44 → 56 pt magnification).

---

## Baseline — measured

Measured against the Release build of baseline commit `402cf55`, running as the real dock
(bottom edge, autohidden, full Daily profile). The sweep is 600 synthesised `mouseMoved`
events at 120 Hz across the revealed chrome (`(0, 894, 1470, 62)`), reproduced with a
`CGEvent` harness so every run is identical.

| Item | Result |
|---|---|
| Debug build (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`) | exit 0 |
| Release build (`-derivedDataPath /tmp/docky-perf-dd`) | exit 0 |
| `DockyTests` (`xcodebuild test`) | 14 tests, 0 failures |
| Idle CPU, dock visible, no interaction | **~2–3%** (target 0–1%) |
| **CPU during a 5 s hover sweep** | **~48–54%** |

The working tree (~22 modified + 10 new files of personal-triggers work) was committed as
`402cf55` rather than stashed, deliberately: it contains `ContextHubWidgetTileView`, which is
part of the full Daily profile the brief wants measured. `default.profraw` (a coverage
artifact) was left untracked.

### Getting a dock on screen

Worth recording for the next session. Docky's permissions are **path-keyed** by TCC, and the
app **self-installs**: it shows a "Move Docky to Applications?" prompt on first launch from a
temporary location. That prompt — not the build system — is what replaced the installed
`/Applications/Docky.app` with the perf build. A build run from `/tmp` has no Full Disk Access
of its own, falls back into the onboarding wizard, and **never presents a dock**, so all
profiling must happen from `/Applications`.

---

## Confirmed issue #1 — the magnification model is rebuilt per tile

**Primary suspect from the brief, confirmed by profile.** `sample` over the main thread
during the sweep (4798 samples, ~6 s) attributes the cost unambiguously:

```
447  closure #1 in TileContainerView.body.getter      TileContainerView.swift:40
 422   TileContainerView.overflowWrappedContent(in:)  :70
  386     TileContainerView.magnificationAnchorOffset :1121
   354       computeMagnificationWalk(cursor:)        :1067
    177         magnifiedIconSize(for:)               :1015
     170           magnificationModel.getter          :943
      101             cursorAxisLocation.getter       :924
```

The dominant term is **`magnificationModel` being rebuilt inside the per-tile loop**. It is
loop-invariant — identical for every tile — yet
[`magnifiedIconSize(for:)`](../Docky/Views/Tiles/TileContainerView.swift#L1015) resolved it on
every call. Each rebuild reads
[`cursorAxisLocation`](../Docky/Views/Tiles/TileContainerView.swift#L924), which calls
`totalAxisLength(for: layoutComponents)` — re-deriving `layoutComponents` **and**
[`displayTiles`](../Docky/Views/Tiles/TileContainerView.swift#L300) from scratch, both O(n),
once per tile. `displayTiles` in turn rebuilds `previewPinnedTiles` and
[`groupedOpenedAppTilesByFolderID`](../Docky/Views/Tiles/TileContainerView.swift#L359) (a
`compactMap` + `Dictionary(grouping:)` over every store tile).

`magnifiedIconSize` is called once per tile from **two** places —
[`tileView(for:)`](../Docky/Views/Tiles/TileContainerView.swift#L211) and
[`computeMagnificationWalk`](../Docky/Views/Tiles/TileContainerView.swift#L1067) — so the whole
display list was re-derived ~2n times per frame, at up to 120 Hz. Cost scales with tile count,
which is exactly why the full Daily profile hurts most.

`computeMagnificationWalk`'s doc comment claimed it "walks every tile once". It did not.

**Correction to the initial static read:** `restAxisCenter(forTileID:)` was the *smaller*
term (~181 samples), not the main one. The static analysis overweighted it; the profile
settled it. This is why the brief says profile data outranks the suspect list.

**Fix (commit `f3004c6`):** resolve the model and every rest center once per render into a
`MagnificationContext`, and thread it down to the per-tile call sites. `restAxisCenter(forTileID:)`
(a full walk per tile) becomes `restAxisCenters()` (one cumulative pass building a
`[String: CGFloat]`). The arithmetic is untouched — the existing walk already accumulated the
same rest positions, and spacing-before-each-tile-except-first is identical to
spacing-after-each-tile-except-last — so the rendering is bit-for-bit the same.

**Measured before → after:**

| main-thread samples | before | after |
|---|---|---|
| `TileContainerView.body` | 447 | **170** |
| `overflowWrappedContent` | 422 | **72** |
| `computeMagnificationWalk` | 354 | **15** |
| `cursorAxisLocation` | 101 | **12** |
| main thread idle | 52.0% | **55.4%** |

### ⚠️ It does not fix the felt lag

**Sweep CPU is unchanged: ~48–54% before, ~46–54% after.** The fix is real — main-thread work
in that path dropped ~62% — but the whole subtree was only **~9% of the main thread**, so
removing it does not move the headline number. Kept anyway: it is a measured reduction with no
behavior change, and it removes an O(n²) that would worsen as tiles are added. But the hover
sweep still does not meet the brief's acceptance gate.

---

## THE ACTUAL BOTTLENECK — full layout pass every frame (next brief)

Main-thread breakdown during the sweep (fixed build, 4634 samples over ~4.6 s):

```
4634  Main Thread
 2568   mach_msg2_trap                        ← idle, waiting for events
 1498   __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__
  1495     CA::Transaction::flush_as_runloop_observer
   1363       CA::Transaction::commit()
    1360         NSDisplayCycleFlush
     1328           __NSWindowGetDisplayCycleObserverForLayout_block_invoke
                      → -[NSView _layoutSubtreeWithOldSize:] → NSHostingView.layout()
```

**~1498 samples (~32% of the window) go into the CoreAnimation display cycle driving an
AppKit/SwiftUI layout pass — every frame.** `TileContainerView.body` (170) is only ~11% of
that; the rest is layout itself.

This is the brief's own suspect #1, second half: magnification assigns each tile a new
`.frame(width:height:)` every frame
([`tileView(for:)`](../Docky/Views/Tiles/TileContainerView.swift#L226)), so the entire
HStack/VStack relayouts on every pointer move instead of the row being composited with a
transform. Apple's Dock scales icons via transforms, which stay on the compositor and never
touch layout.

**Fix direction (needs its own brief — structural, and risky):** drive magnification through
`scaleEffect`/transforms rather than frame assignment. Non-trivial: the current design uses
real frames to size the chrome (`DockChromeMetricsService.alongAxisGrowth`), position the
anchor offset, and hit-test tiles, so all three need rethinking together. Not something to
land at the tail of this session.

All worker threads were verified idle (`__workq_kernreturn`) — the cost is entirely
main-thread.

## Issue #2 — `MainWindowView` re-renders per mouse move — real, but not worth fixing

[`MainWindowView.isTrackingMagnification`](../Docky/Views/MainWindow/MainWindowView.swift#L50)
reads `magnification.pointerLocation != nil`. Because `DockMagnificationService` is
`@Observable` (per-property tracking), reading `pointerLocation` in `body` subscribes the
**root view** to a property that changes on *every* pointer event, when only its nil-ness is
needed — which changes twice per sweep (enter, exit).

**The profile says this costs almost nothing:** `MainWindowView.body` and everything under it
totals **~7 samples** out of 4798. The mechanism is real, the cost is not. Recorded here so a
future session doesn't "fix" it expecting a win. Left alone — a change with no measured
benefit is exactly what the brief rules out.

## Issue #3 — context menus are rebuilt during the hover sweep (~3.5% of main thread)

Not on the brief's suspect list; found in the profile:

```
52  closure #1 in ContextActionMenuPresenter.updateNSView(_:context:)
50  ContextActionMenuPresenter.Coordinator.installIfNeeded(for:)
29  TileView.contextActions(modifierFlags:)
23  TileView.injectingFinderHomeNavigation(into:for:)
```

~170 samples (~3.5%) spent **constructing right-click menu actions while merely hovering**.
`TileView` rebuilds its context-action list on every render pass and the presenter re-installs
it into the NSView. Nothing about a hover should touch menus.

Deferred: it is a second, independent fix, and issue #1 dominates. Worth its own brief.

## Contributing factor — `TileView` is not `Equatable` and observes 8 services *(static)*

[`TileView`](../Docky/Views/Tiles/TileView.swift#L15) is re-evaluated per tile per frame and
carries `@ObservedObject` references to `DockLayoutService`, `WorkspaceService`,
`MediaPlaybackService`, `DockEditModeService`, `WidgetExpansionWindowController`,
`DockDragService`, `WindowPreviewWindowController` plus `@Bindable DockyPreferences`. Several
are `ObservableObject`, whose `@Published` changes invalidate **every** `TileView` regardless of
which property changed. No `Equatable` conformance, so SwiftUI cannot skip unchanged tiles.

Deferred — structural, and should be justified by a profile first.

---

## Suspects investigated and cleared

| Suspect (brief rank) | Verdict |
|---|---|
| **2. `LiveGlassBackdrop`** | **Dead code** — zero references anywhere in the app. Not on any path. Candidate for deletion in a separate pass. |
| **2. `DockyGlass`** | **Cleared by profile: zero samples** across the entire sweep. Statically consistent — the fallback is a single **window-level** blur (`CGSSetWindowBackgroundBlurRadius`) shared by all surfaces in the window, not per-tile live sampling — so cost does **not** multiply by tile count. The "live glass re-samples per tile as tiles scale" hypothesis is wrong. |
| **3. `DockyPreferences` (4,525 lines)** | Largely cleared for the sweep. It is `@Observable`, not `ObservableObject` — Swift Observation tracks per-property, so one property change does **not** invalidate every view body. Nothing on the hover path writes to it. The 127 `didSet` observers and their persistence cadence remain worth a look for *other* scenarios, but they are not on the mouse-move path. |
| **5. Timers** | Cleared as a sweep cause. `ProfileTriggerEngine` uses `NWPathMonitor` (event-driven, not polling) plus a 60 s minute tick; `FocusFlowBridge` 10 s; `DockBadgeService` 2 s (AX — could cause a *periodic* hitch, not uniform lag); `DockDragService` 0.1 s only during drags. |
| **`DockChromeMetricsService` feedback loop** | Cleared. `setAlongAxisGrowth` guards on equality (`> 0.0001`), so the per-frame `publishChromeGrowth` cannot cause an infinite re-render loop. The writer is deliberately not an observer. |
| **`DockMagnificationService` ramp timer** | Cleared. `beginRamp` no-ops when already at the target, so the 60 Hz timer does not run for the lifetime of a hover (a previously-fixed bug, per its comment). |

## Not yet investigated

- **4. `WindowRegistry` / `WorkspaceService` / `DockBadgeService` (AX API).** Synchronous AX IPC on
  the main thread could stall mid-sweep. Needs a profile to catch — deferred with the blocker.
- **6. Widget tiles** (`NowPlayingWidgetTileView`, `CalendarWidgetTileView`, the five external
  widgets) — body cost per re-evaluation.
- **7. Overlay controllers** staying live while invisible.

---

## Acceptance criteria — status

| Criterion | Status |
|---|---|
| Debug build exit 0 | ✅ |
| `DockyTests` pass | ✅ 14/14 |
| Idle CPU ≈ 0–1% | ❌ ~2–3% |
| **Hover sweep: no main-thread stall > 16 ms** | ❌ **not met — see "actual bottleneck"** |

**The session's gate is not met.** The committed fix is a genuine, measured improvement but
does not resolve the reported lag. The next brief (frame-driven → transform-driven
magnification) is where the win is.

## Deferred (own brief later), ranked by measured impact

1. **Transform-driven magnification** — ~32% of the sweep window is a per-frame layout pass.
   This is the felt lag. Everything else is noise next to it.
2. **Context menus rebuilt on hover** — ~3.5% of main thread (`ContextActionMenuPresenter`
   + `TileView.contextActions`). Self-contained and much lower risk than #1.
3. `TileView` is not `Equatable` and observes 8 services, several of them `ObservableObject`
   (whose `@Published` changes invalidate every tile regardless of relevance).
4. Deleting `LiveGlassBackdrop` (dead private-API code, zero references, zero samples).
5. `DockyPreferences`' 127 `didSet` observers and their persistence cadence — not on the
   hover path; relevant to other scenarios only.
6. Idle CPU at 2–3% vs the 0–1% target — not the sweep complaint, but above target.

## Environment notes for the next session

- `/Applications/Docky.app` currently holds the **fixed** perf build (commit `f3004c6`), not
  Gabriel's own build — rebuild and reinstall from the `personal` branch when done. The
  baseline bundle is backed up at `/tmp/docky-baseline-backup.app`.
- Docky **self-installs** via a "Move Docky to Applications?" prompt; that is what replaced the
  original installed 0.8.0, not the build system.
- TCC is **path-keyed**: only `/Applications/Docky.app` has Full Disk Access. A build run from
  `/tmp` drops into the onboarding wizard and never shows a dock. Replacing the bundle in place
  with `ditto` preserves the grant.
- Repro harness (sweep + window enumeration, `CGEvent`-based) lives in this session's
  scratchpad; it reveals the autohidden dock first, then sweeps at the chrome's midline.
