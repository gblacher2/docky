# Brief: local-docky-preferences-audit (2026-07-16)

**Author:** Claude | Codex · **Executor:** Antigravity · **Repo:** /Users/gabrielblacher/GitHub & Coding Projects/local-docky

## Objective
Audit the persistence design in `DockyPreferences.swift`, map out the `didSet` observers, check if their persistence writes to UserDefaults synchronously on every mutation, profile live drag-reorder and profile switching interactions, and implement coalesced/debounced saving if a performance cost is measured.

## Context
`DockyPreferences.swift` contains approximately 127 `didSet` observers starting around line 1131. Any interactive path that mutates properties in a loop (like drag-reordering tiles, live slider drags in Settings, or profile switching) might be performing synchronous disk or IPC I/O via UserDefaults. We need to identify if this is happening, profile the performance impact, and conditionally optimize it by debouncing/coalescing writes.

## In scope
- `Docky/Services/DockyPreferences.swift`

## Out of scope
- Magnification
- Splitting `DockyPreferences` into smaller slices/classes
- Changing preference semantics or defaults

## Acceptance criteria
1. Provide a clear mapping of which didSets persist and whether persistence is synchronous, debounced, or batched.
2. Provide profiling measurements of profile switching and live drag-reorder on macOS.
3. If and only if a performance cost is found: optimize `DockyPreferences` to debounce/coalesce writes to UserDefaults, ensuring high-frequency mutations (e.g., in a drag-reorder loop) do not block the main thread with synchronous serialization and disk/IPC I/O.
4. Verify the build and run, ensuring all tests pass.

## Verification
```bash
xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug -destination 'platform=macOS' test
```

## Report
The execution report must contain: files changed, the real output of every verification command, deviations from this brief, and open questions.
