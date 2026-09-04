# Antigravity prompts — Docky perf, remaining phases (2026-07-16)

Paste-able prompts for the phases whose cost is **reading large files**, offloaded from Claude.
Each is self-contained: it carries the measured facts so the executor never re-derives them.

**Shared facts — true for every prompt below. Do not re-measure these.**

- Baseline (Release, real dock, full Daily profile, 5 s synthesised hover sweep at 120 Hz):
  **~48–54% CPU during sweep**, **~2–3% idle**, main thread 4634 samples.
- The hover sweep's dominant cost is a **per-frame AppKit/SwiftUI layout pass**
  (~1498 samples, ~32% of the window, under `CA::Transaction::flush_as_runloop_observer`).
  That is being fixed separately — see `_briefs/2026-07-16-transform-driven-magnification.md`.
  **Do not touch magnification in any prompt except #1.**
- Already cleared by profile — do **not** re-investigate: `DockyGlass`/glass (zero samples);
  `LiveGlassBackdrop` (dead code, zero references); `DockMagnificationService`'s ramp timer;
  `DockChromeMetricsService` (equality-guarded, no feedback loop); `MainWindowView` re-rendering
  per mouse move (~7 of 4798 samples — real but negligible, leave it alone).
- `DockyPreferences` is `@Observable` (per-property tracking), **not** `ObservableObject` — a
  single property change does **not** invalidate every view. Any analysis assuming otherwise is
  wrong.
- Full context: `_briefs/2026-07-16-perf-deep-review-findings.md`.

**Standing rules for every prompt**

- Build/verify per `AGENTS.md`:
  ```bash
  xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
  xcodebuild test -project Docky.xcodeproj -scheme Docky -configuration Debug \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  ```
  Tests are currently 14/14. Follow `AGENTS.md`'s Swift 6 concurrency + AppKit/SwiftUI patterns.
- **No behaviour or visual changes.** Gabriel Glass must look and act identical.
- **No refactor without a measurement justifying it.** A change with no measured benefit is out
  of scope by definition.
- Never call `TileStore.loadDemoDebugLayout()` against real preferences — it overwrites
  `preferences.pinnedItems` and destroys the Daily profile. (Under XCTest `DockyUserDefaults`
  returns a volatile suite, so tests are safe.)
- Don't commit `default.profraw`. Don't touch `docky-personal` / `docky-personal-widgets`.
- **Report failures, don't work around them.** If a measurement doesn't improve, say so plainly.

**Profiling environment — read before any prompt that measures**

TCC is **path-keyed**: only `/Applications/Docky.app` has Full Disk Access. A build run from
`/tmp` falls into the onboarding wizard and **never presents a dock**. Profile like this:

```bash
xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/docky-perf-dd build
pkill -x Docky; sleep 2
ditto /tmp/docky-perf-dd/Build/Products/Release/Docky.app /Applications/Docky.app
open -a /Applications/Docky.app; sleep 8     # "Move to Applications?" prompt -> Not Now
cd _briefs/tools && swiftc -O sweep.swift -o /tmp/sweep
PID=$(pgrep -x Docky)
(sample $PID 6 -file /tmp/s.txt >/dev/null 2>&1 &); sleep 0.3
(top -pid $PID -l 6 -s 1 -stats cpu > /tmp/c.txt 2>&1 &)
/tmp/sweep 5; sleep 2; grep -E "^[0-9]+\.[0-9]" /tmp/c.txt
```

The dock is **autohidden** — `_briefs/tools/sweep.swift` reveals it first, then sweeps. Without
the reveal it never magnifies and you measure nothing. `/Applications/Docky.app` currently holds
the `f3004c6` perf build, not Gabriel's own; pre-fix baseline is `/tmp/docky-baseline-backup.app`.

---

## Prompt 1 — Transform-driven magnification (the real fix)

> Execute the brief at `_briefs/2026-07-16-transform-driven-magnification.md` in
> `~/GitHub & Coding Projects/local-docky`. It is complete and self-contained: read it in full,
> including its Out of scope and Verification sections, and append your `## Execution report —
> <date>` to that same file.
>
> The gate is acceptance criterion 4: **sweep CPU must drop materially below the ~48–54%
> baseline.** A previous session shipped a correct, measured optimisation that did not move this
> number and reported that honestly — the same standard applies. If criterion 6 (Gabriel Glass
> looks pixel-identical, especially icon crispness at 56 pt under `scaleEffect`) cannot be met by
> any transform approach, **stop and report** rather than shipping a softer dock. A slower dock
> beats a blurry one.

*Token-heavy: `TileContainerView.swift` (2,317 lines) + `TileView.swift` (3,319).*

---

## Prompt 2 — AX audit: is synchronous Accessibility IPC stalling the main thread?

> In `~/GitHub & Coding Projects/local-docky`, audit the Accessibility (AX) API usage in
> `Docky/Services/WindowRegistry.swift` (1,236 lines), `Docky/Services/WorkspaceService.swift`
> (1,385) and `Docky/Services/DockBadgeService.swift`. This was suspect #4 of the perf review and
> is the one significant path never investigated — read
> `_briefs/2026-07-16-perf-deep-review-findings.md` first for the measured baseline and the
> already-cleared suspects (don't re-derive them).
>
> The hypothesis to test: `AXUIElement` calls are **synchronous IPC** to other processes. If any
> run on the main thread, a slow or unresponsive target app blocks the dock. `WindowRegistry`
> registers 5 AX observers; `DockBadgeService` polls every 2 s. A timer firing heavy AX work
> would show as a **periodic hitch** rather than uniform slowness.
>
> Deliver, in this order:
> 1. **Evidence first.** Find every AX call on the main thread (`AXUIElementCopyAttributeValue`,
>    `AXUIElementCreateApplication`, `AXObserverAddNotification`, …). For each: is it main-thread,
>    is it in a hot/periodic path, and does it have a timeout? Note per-event full rescans and
>    observer churn (add/remove on every event).
> 2. **Measure, don't guess.** Profile using the "Profiling environment" block above. Capture a
>    `sample` while the dock is idle for 10 s with several apps open, and look for periodic
>    main-thread stacks in AX/`mach_msg` to other processes. Report the sample counts.
> 3. **Only then fix**, one issue per commit, each with before/after numbers in the message.
>    Prefer moving AX work off the main thread or adding timeouts (`AXUIElementSetMessagingTimeout`)
>    over restructuring. Do not rewrite either service wholesale.
>
> Out of scope: magnification/rendering (separate brief), the other deferred items, any change
> without a measurement. Report honestly if AX turns out **not** to be a problem — "suspect
> cleared" is a valid and useful result.

*Token-heavy: ~2,600 lines across three services.*

---

## Prompt 3 — Context menus rebuilt during hover (measured: ~3.5% of main thread)

> In `~/GitHub & Coding Projects/local-docky`, stop the dock from building right-click menu
> actions while the user is merely hovering. This is a **measured** finding from
> `_briefs/2026-07-16-perf-deep-review-findings.md` — read it first.
>
> During a 5 s hover sweep, `sample` attributed ~170 main-thread samples (~3.5%) to:
> ```
> 52  closure #1 in ContextActionMenuPresenter.updateNSView(_:context:)
> 50  ContextActionMenuPresenter.Coordinator.installIfNeeded(for:)
> 29  TileView.contextActions(modifierFlags:)
> 23  TileView.injectingFinderHomeNavigation(into:for:)
> ```
> `TileView` rebuilds its context-action list on every render pass and the presenter re-installs
> it into the NSView. Nothing about a hover should touch menus — they're only needed on
> right-click.
>
> Build the menu lazily (on demand at right-click) or cache it and invalidate only when its real
> inputs change. `TileView.swift` is 3,319 lines — work only in the context-action/presenter area.
>
> Verify: right-click menus on every tile type (app, folder, app folder, Trash, widget, divider,
> Launchpad, Start menu) still show the same items in the same order, including modifier-key
> variants (hold Option) and the Finder-home injection. Then re-measure the sweep per the
> "Profiling environment" block and report the new sample count for those symbols.
>
> Out of scope: magnification, the rest of `TileView`, `TileView` `Equatable` conformance.

*Moderate token cost, self-contained, measured payoff — good standalone task.*

---

## Prompt 4 — DockyPreferences: 127 `didSet` observers and persistence cadence

> In `~/GitHub & Coding Projects/local-docky`, audit `Docky/Services/DockyPreferences.swift`
> (4,525 lines, 127 `didSet` observers starting ~line 1131). Read
> `_briefs/2026-07-16-perf-deep-review-findings.md` first.
>
> **Correct two likely misconceptions before you start.** (a) This class is `@Observable`, **not**
> `ObservableObject` — Swift Observation tracks per-property, so one property change does **not**
> invalidate every view body. Any plan premised on "one giant observable invalidates everything"
> is wrong. (b) It is **not** on the hover-sweep path — nothing in the mouse-move → magnify →
> render path writes to it, and the sweep's cost is a per-frame layout pass, already briefed
> separately. So this is **not** where the felt lag lives; treat it as hygiene, not a lag fix.
>
> The real question: do the `didSet` observers write to `UserDefaults` **synchronously** on every
> mutation? If so, any interactive path that mutates preferences in a loop (drag-reorder, live
> slider drags in Settings, profile switching) does synchronous disk I/O per change.
>
> Deliver:
> 1. Map which `didSet`s persist, and whether persistence is synchronous, debounced, or batched.
> 2. Identify paths that mutate preferences repeatedly during one interaction. **Measure one**:
>    profile a live drag-reorder and a profile switch (see "Profiling environment" above; note the
>    dock is autohidden and `_briefs/tools/sweep.swift` reveals it).
> 3. If and only if a measurement shows a cost: debounce/coalesce persistence. Do **not** split
>    the class into slices — that's a large structural change with no measured justification yet.
>    If nothing measurable is found, report "cleared" and stop.
>
> Out of scope: magnification, splitting the type, changing any preference's semantics or defaults.

*Token-heavy: 4,525 lines. Low expected payoff — schedule after 1–3.*

---

## Prompt 5 — Widget tiles and overlay controllers: idle and per-render cost

> In `~/GitHub & Coding Projects/local-docky`, investigate suspects #6 and #7 of the perf review
> (read `_briefs/2026-07-16-perf-deep-review-findings.md` first for the baseline and cleared
> suspects). Measured context: **idle CPU is ~2–3%** with the dock visible and untouched; the
> target is 0–1%. That gap is this task's target — the hover sweep is briefed separately, so
> **don't touch magnification**.
>
> Two questions:
> 1. **Widget tiles** — `NowPlayingWidgetTileView.swift` (756), `CalendarWidgetTileView.swift`
>    (750), `MediaPlaybackService.swift` (723), `SystemStatusWidgetTileView`,
>    `ContextHubWidgetTileView`, plus the five external widgets loaded from
>    `docky-personal-widgets` (CFACountdown, Clipboard, MarketsWatchlist, Pomodoro, Scratchpad).
>    Are their `body`s expensive to re-evaluate — date formatting, image decoding, or attributed
>    strings built per body call rather than cached? What is each one's refresh cadence, and does
>    anything refresh while nothing has changed?
> 2. **Overlay controllers** — `LaunchpadOverlayWindowController.swift` (2,220), plus DockEditor,
>    StartMenu, WindowSwitcher, WindowPreview. Do any stay live — rendering, observing, or running
>    timers — while invisible?
>
> Method: profile idle first (`sample $(pgrep -x Docky) 10 -file /tmp/idle.txt` with the dock
> visible and untouched), and attribute the ~2–3%. Report what actually consumes it before
> changing anything.
>
> You may **read** `docky-personal-widgets` to attribute cost, but do **not** modify it — if an
> external widget is a top offender, note it for a separate pass.
>
> Out of scope: magnification/rendering, widget features or visuals, the importer contract.

*Token-heavy: ~5,000+ lines across widgets and overlays, plus 5 external widget repos.*

---

## Not worth an Antigravity prompt

- **Delete `LiveGlassBackdrop.swift`** — dead code, zero references, zero samples. A two-minute
  local change; just do it.
- **`TileView` `Equatable` / splitting the 8 observed services** — genuinely structural, but
  currently has **no measurement** justifying it. Revisit only if the transform work (Prompt 1)
  lands and the sweep is still slow. Briefing it now would violate "no refactor without a
  measurement".
