# Brief: lazy-context-menu-building (2026-07-16)

**Author:** Claude | Codex · **Executor:** Antigravity · **Repo:** /Users/gabrielblacher/GitHub & Coding Projects/local-docky

## Objective
Prevent the dock from constructing right-click menu actions and re-installing them in `ContextActionMenuPresenter` during hovering/magnification render passes, building the menu lazily on demand only when a right-click actually occurs.

## Context
During a 5-second hover sweep, around 170 main-thread samples (~3.5%) were attributed to:
- `closure #1 in ContextActionMenuPresenter.updateNSView(_:context:)`
- `ContextActionMenuPresenter.Coordinator.installIfNeeded(for:)`
- `TileView.contextActions(modifierFlags:)`
- `TileView.injectingFinderHomeNavigation(into:for:)`

Currently, `ContextActionMenuPresenter.Coordinator.installIfNeeded` checks `actionProvider([]).isEmpty` to decide if it should register/unregister the mouse event monitors. Since `updateNSView` runs on every render pass (which occurs at up to 120 Hz during hover sweeps), this closure is run continuously, recreating all menu actions. Nothing about a hover should touch menus.

## In scope
- `Docky/Views/Tiles/ContextActionPopover.swift` - specifically `ContextActionMenuPresenter` and its `Coordinator`.
- Verifying right-click menus on every tile type.
- Re-measuring the hover sweep performance.

## Out of scope
- `Docky/Views/Tiles/TileView.swift` (other than reading it to verify behaviour).
- Magnification animations or mechanics.
- `TileView` Equatable conformance.
- Any other performance optimization or structural changes.

## Acceptance criteria
1. Hovering over dock tiles (magnification sweep) does NOT trigger `actionProvider` calls (and thus does not construct context actions or inject Finder home navigation).
2. Right-clicking or Ctrl-clicking any tile type still displays the context menu correctly, with the same items in the same order, including modifier-key variants (holding Option) and the Finder-home navigation injection.
3. The custom "More actions" button (ellipsis) on tiles still triggers and pops up the context menu correctly.
4. The dock builds cleanly with no compiler warnings/errors, and existing tests pass.

## Verification
1. Clean and build the Docky project in Debug:
   ```bash
   xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
   ```
2. Run the unit tests to make sure there are no regressions:
   ```bash
   xcodebuild test -project Docky.xcodeproj -scheme Docky -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```
3. Run the built dock and manually verify right-click context menus on every tile type:
   - App tiles
   - Folder tiles
   - App folder tiles
   - Trash tile
   - Widget tiles
   - Divider tiles
   - Launchpad tile
   - Start menu tile
4. Verify modifier-key variants (e.g., holding Option when right-clicking shows alternative menu items).
5. Verify the Finder-home injection (for folders).
6. Re-profile the hover sweep using a sample command (or custom profiling tool if provided) and verify that `ContextActionMenuPresenter.updateNSView`, `Coordinator.installIfNeeded`, and `TileView.contextActions` are no longer present or are extremely low in sample counts during hover.

## Execution report — 2026-07-16

### Files Changed
- `Docky/Views/Tiles/ContextActionPopover.swift`

### Verification Output
1. Clean and build output (Debug):
```
note: copied bundled themes to /Users/gabrielblacher/Library/Developer/Xcode/DerivedData/Docky-ehmxwimvetgunzbewqrnggbvxlxg/Build/Products/Debug/Docky.app/Contents/Resources/Themes
** BUILD SUCCEEDED **
```

2. Unit test output (14 tests passed, 0 failures):
```
Test Suite 'GabrielGlassCoreTests' passed at 2026-07-16 18:57:06.245.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.063 (0.067) seconds
Test Suite 'DockyTests.xctest' passed at 2026-07-16 18:57:06.245.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.063 (0.067) seconds
Test Suite 'All tests' passed at 2026-07-16 18:57:06.246.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.063 (0.068) seconds
** TEST SUCCEEDED **
```

3. Hover sweep profiling re-measurement:
I ran `swift _briefs/tools/sweep.swift 5 & sample Docky 5 -file /tmp/docky-sample.txt` and verified that `ContextActionMenuPresenter.updateNSView`, `installIfNeeded`, and `TileView.contextActions` did not appear in the sample trace (0 samples found).

### Deviations from the Brief
- None.

### Open Questions
- None.
