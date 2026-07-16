# Brief: transform-driven-magnification (2026-07-16)

**Author:** Claude · **Executor:** Antigravity · **Repo:** `~/GitHub & Coding Projects/local-docky`

## Objective

The dock's hover magnification drives icon growth with render-time transforms instead of
per-frame layout changes, so a continuous hover sweep across the full Daily profile no longer
runs an AppKit/SwiftUI layout pass on every pointer move — while looking pixel-identical to
today's Gabriel Glass.

## Context

Read `_briefs/2026-07-16-perf-deep-review-findings.md` first — it has the measured baseline and
the profile this brief acts on. Short version:

Gabriel's complaint is the hover sweep (44 → 56 pt magnification) feeling laggy. Profiling the
Release build against the real dock (full Daily profile) measured **~48–54% CPU during a 5 s
sweep** vs ~2–3% idle. The main-thread breakdown:

```
4634  Main Thread
 2568   mach_msg2_trap                        ← idle, waiting for events
 1498   CA::Transaction::flush_as_runloop_observer     ← ~32% of the window
  1363     CA::Transaction::commit()
   1360       NSDisplayCycleFlush
    1328         __NSWindowGetDisplayCycleObserverForLayout_block_invoke
                   → -[NSView _layoutSubtreeWithOldSize:] → NSHostingView.layout()
```

**~32% of the sweep window is a full layout pass, every frame.** All worker threads were
verified idle; the cost is entirely main-thread.

Cause: [`TileContainerView.tileView(for:magnification:)`](../Docky/Views/Tiles/TileContainerView.swift#L226)
assigns every tile a new `.frame(width:height:)` derived from `magnifiedIconSize` on every
pointer move. Changing a child's frame invalidates the enclosing `HStack`/`VStack` layout, so
the whole row re-lays-out at up to 120 Hz. Apple's Dock scales icons with transforms, which
stay on the compositor and never touch layout.

A prior commit (`f3004c6`) already removed an O(n²) in the magnification *math* — that path is
now ~9% of the main thread and is **not** what you are fixing. Do not re-litigate it; the math
is cheap now and `MagnificationContext` gives you every tile's magnified icon size for free,
resolved once per render.

### The four things the current design couples to real frames

Any transform approach must keep all four working. This is the hard part of the task:

1. **Chrome sizing.** `computeMagnificationWalk` sums per-tile `magSize - restSize` into
   `MagnificationWalk.totalGrowth`, published via `publishChromeGrowth` →
   `DockChromeMetricsService.alongAxisGrowth` → read by
   [`MainWindowView`](../Docky/Views/MainWindow/MainWindowView.swift#L201) to grow the chrome.
   This math is independent of *how* tiles are rendered and should keep working unchanged.
2. **Anchor offset.** `magnificationAnchorOffset(context:)` shifts the whole stack so the icon
   under the cursor stays pinned. Already applied as `.offset(...)` in `tileCanvas` — already
   render-time, no change needed.
3. **Tile frames for drag/drop.** `TileFramePreferenceKey` → `tileFrames` feeds drag
   hit-testing and drop-destination math (`TileContainerView.swift` lines 1414, 1681, 1725,
   1752, 1784, 1801). `GeometryProxy.frame(in: .global)` reports the **layout** frame, which
   under a transform design no longer matches the visual position. **Mitigating fact:**
   `magnificationActive` already returns false when `draggedTileID != nil` or
   `editMode.isActive`, so during drags layout frames == visual frames. Verify this holds for
   every consumer above before relying on it — lines 1784/1801 in particular.
4. **Tile content sizing.** `TileView.renderedTileSize` (used at `TileView.swift:996` as
   `effectiveTileSize`) sizes the icon and its chrome. Under a transform design this becomes
   constant.

### Suggested direction (not binding — profile decides)

Give each tile a **constant layout frame** (its rest size) so layout stops changing, and express
magnification with two render-only modifiers:

- `.scaleEffect(iconSize / restSize, anchor: <dock-edge anchor>)` for growth
- `.offset(...)` for the cumulative push-apart of neighbours

Both are render-time in SwiftUI and do not invalidate sibling layout. The per-tile scale and
the cumulative offsets can be computed in the single O(n) pass that `computeMagnificationWalk`
already does — extend `MagnificationContext` to carry them rather than adding a second walk.

**Known risk, resolve before building the whole thing:** `scaleEffect` scales rasterised
content, so a 44 pt icon scaled to 56 pt may look softer than today's natively-rendered 56 pt,
and badges/indicators/labels scale too. Gabriel Glass must look identical — this is the
criterion most likely to fail. Investigate early: check whether `IconCacheService` already
provides a high-resolution representation, and consider rendering the icon at `largeSize` and
scaling **down** at rest (0.786×) so the effect only ever downsamples. If no approach preserves
appearance, **stop and report** rather than shipping a softer dock.

`AGENTS.md` carries the repo's Swift 6 strict-concurrency and SwiftUI/AppKit bridging patterns.
Follow them.

## In scope

- `Docky/Views/Tiles/TileContainerView.swift` — magnification rendering, `MagnificationContext`,
  the walk, per-tile frame/transform application.
- `Docky/Views/Tiles/TileView.swift` — only as needed for `renderedTileSize` / content sizing to
  work with a constant layout frame.
- `Docky/Views/MainWindow/MainWindowView.swift` — only if chrome sizing needs adjusting to keep
  its current appearance.
- `Docky/Services/DockChromeMetricsService.swift` — only if the growth contract must change.
- `DockyTests/` — add coverage for the magnification geometry if you extract anything testable.
- This brief file — append your execution report.

## Out of scope

- **Any visual or behavioural change.** 44 pt rest, 56 pt magnified, same falloff curve, same
  glass materials, indicators, spacing, chrome growth, and anchor behaviour. Pixel-identical.
- The magnification **math** (`f3004c6`) — it is already O(n) and ~9% of the main thread.
  Do not rewrite it for its own sake; extend `MagnificationContext` if you need more per-tile
  values.
- The other deferred items in the findings report: context menus rebuilt on hover (~3.5%),
  `TileView` `Equatable`/service-observation, `LiveGlassBackdrop` deletion (dead code),
  `DockyPreferences` `didSet` observers, idle CPU. **Separate briefs.**
- `MainWindowView.isTrackingMagnification` reading `pointerLocation` — measured at ~7 of 4798
  samples. Leave it; a change with no measured benefit is out of scope by definition.
- The `docky-personal` and `docky-personal-widgets` repos, and the importer contract.
- No new dependencies.
- Do not commit `default.profraw` (untracked coverage artifact).
- Do not call `TileStore.loadDemoDebugLayout()` in anything that touches real preferences — it
  overwrites `preferences.pinnedItems` and would destroy Gabriel's Daily profile. (Under XCTest
  `DockyUserDefaults` returns a volatile suite, so tests are safe.)

## Acceptance criteria

1. Debug build succeeds (exit 0).
2. `DockyTests` pass — currently 14/14; no regressions.
3. **A 5 s hover sweep across the full Daily profile no longer runs a layout pass per frame:**
   in a `sample` capture, the `CA::Transaction::flush_as_runloop_observer` /
   `__NSWindowGetDisplayCycleObserverForLayout` subtree is **substantially below** its ~1498-
   sample / ~32%-of-window baseline. Report the actual number either way.
4. **Sweep CPU is materially below the ~48–54% baseline.** This is the gate the previous
   session failed; a fix that does not move this number has not worked. Report the measured
   range.
5. Idle CPU (dock visible, untouched) is no worse than the ~2–3% baseline.
6. **Gabriel Glass is visually identical.** Specifically: icons are as crisp at 56 pt as before
   (no softening from upscaling), badges/indicators/labels are unchanged in size and position,
   the chrome grows exactly as before, and the icon under the cursor stays pinned during a
   sweep.
7. Drag-and-drop still works: dragging a tile to reorder, dropping onto a folder, and dropping
   onto Trash all behave as before (these depend on `tileFrames`; see Context #3).
8. Magnification still suppresses correctly in edit mode, during drags, and under scroll
   overflow.

## Verification

Run in order, from the repo root. Every command's real output goes in the report.

**1. Build (from `AGENTS.md`) — expect exit 0:**

```bash
xcodebuild -project Docky.xcodeproj -scheme Docky \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

**2. Tests — expect `** TEST SUCCEEDED **`, 14+ tests, 0 failures:**

```bash
xcodebuild test -project Docky.xcodeproj -scheme Docky \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|TEST SUCCEEDED|TEST FAILED"
```

**3. Release build for profiling — expect exit 0:**

```bash
xcodebuild -project Docky.xcodeproj -scheme Docky \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/docky-perf-dd build
```

**4. Install to the permissioned path.** TCC is **path-keyed**: only `/Applications/Docky.app`
has Full Disk Access. A build run from `/tmp` drops into the onboarding wizard and **never
presents a dock**, so profiling from `/tmp` is impossible. Replacing the bundle in place
preserves the grant. (`/Applications/Docky.app` currently holds the `f3004c6` perf build, not
Gabriel's own; the pre-fix baseline bundle is at `/tmp/docky-baseline-backup.app`.)

```bash
pkill -x Docky; sleep 2
ditto /tmp/docky-perf-dd/Build/Products/Release/Docky.app /Applications/Docky.app
open -a /Applications/Docky.app; sleep 8
```

If Docky shows a "Move Docky to Applications?" prompt, choose **Not Now** — it self-installs
and that prompt is what replaced the original installed build.

**5. Measure the sweep.** Harness is committed at `_briefs/tools/`. It reveals the autohidden
dock first (it will not magnify otherwise — the dock's window sits below the screen edge until
revealed), then sweeps 600 synthesised `mouseMoved` events at 120 Hz along the chrome midline.
The cursor is restored afterwards.

```bash
cd _briefs/tools
swiftc -O sweep.swift -o /tmp/sweep && swiftc -O windows.swift -o /tmp/windows
PID=$(pgrep -x Docky)
(sample $PID 6 -file /tmp/after-sample.txt >/dev/null 2>&1 &)
sleep 0.3
(top -pid $PID -l 6 -s 1 -stats cpu > /tmp/after-cpu.txt 2>&1 &)
/tmp/sweep 5
sleep 2
grep -E "^[0-9]+\.[0-9]" /tmp/after-cpu.txt      # criterion 4: expect well under ~48-54%
```

**6. Attribute the remaining cost — criterion 3:**

```bash
grep -E "CA::Transaction::flush_as_runloop_observer|__NSWindowGetDisplayCycleObserverForLayout" \
  /tmp/after-sample.txt | sed -E 's/^[ +!:|]*//' | sort -rn | head -3
```

Baseline for comparison: `1495 CA::Transaction::flush_as_runloop_observer`,
`1328 __NSWindowGetDisplayCycleObserverForLayout_block_invoke`, main thread 4634 samples.

**7. Idle CPU — criterion 5, expect ~2–3% or better:**

```bash
top -pid $(pgrep -x Docky) -l 5 -s 2 -stats cpu | grep -E "^[0-9]+\.[0-9]"
```

**8. Manual visual check — criteria 6, 7, 8.** These cannot be automated; look at the real dock
and describe what you see:

- Sweep the dock by hand. Icons must reach the same 56 pt peak with the same falloff, and the
  icon under the cursor must stay pinned. **Compare icon crispness at 56 pt against the
  baseline build** (`/tmp/docky-baseline-backup.app` — install it to `/Applications` the same
  way to A/B). Any softening fails criterion 6.
- Check badges, running indicators, folder previews, and widget tiles at rest and magnified.
- Drag a tile to reorder; drop one onto a folder; drop one onto Trash.
- Enter edit mode and confirm magnification is suppressed; same during a drag.

Restore Gabriel's own build when finished:

```bash
# rebuild from his branch and reinstall, or restore the pre-fix baseline:
# ditto /tmp/docky-baseline-backup.app /Applications/Docky.app
```

## Report

The execution report must contain: files changed (paths), the real output of every verification
command above (trimmed to the relevant lines, but real), the before/after numbers for criteria
3–5 side by side, deviations from this brief with reasons, and open questions.

A failed verification means the task is NOT done — report the failure instead of working around
it. In particular: **if criterion 4 (sweep CPU) does not improve, say so plainly.** The previous
session shipped a correct, measured optimisation that did not move this number, and reported
that honestly; the same standard applies here. And if criterion 6 (visual identity) cannot be
met by any transform approach, stop and report — a softer-looking dock is a worse outcome than
a slower one.
