# local-docky — Build & Verify + macOS Swift/AppKit Patterns

Moved here from Antigravity's global rules (2026-07-10) — they apply to this repo's menu-bar/AppKit code, not to every session. Same copy lives in focus-flow and docky-personal-widgets/local-docky; filesystem rules stay global (`~/.gemini/config/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).

## Build & verify

Default Verification block for any brief here (`_briefs/YYYY-MM-DD-<slug>.md`, per `~/GitHub & Coding Projects/BRIEF-TEMPLATE.md`):

```bash
xcodebuild -project Docky.xcodeproj -scheme Docky \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The build must succeed (exit 0); for UI changes also run the built app and describe the observed before/after behavior in the execution report (per `CONTRIBUTING.md`).

## Swift 6 Strict Concurrency Rules

When writing Swift code targeting macOS 14+ with strict concurrency checks enabled, apply the following patterns to resolve common actor-isolation and sendability warnings:

1. **Non-Sendable Callback Observers (e.g., `NSObjectProtocol`)**:
   Observing system-wide notifications (e.g., `DistributedNotificationCenter.default().addObserver`) returns an `any NSObjectProtocol` object, which is non-Sendable. Accessing or removing this observer in a class `deinit` will cause a compiler error because `deinit` is nonisolated.
   
   **Pattern**: Wrap it in a file-private `@unchecked Sendable` helper struct:
   
   ```swift
   private struct SendableObserver: @unchecked Sendable {
       let value: any NSObjectProtocol
   }
   ```
   
   Store this wrapper as a class property and clean it up inside `deinit`:
   
   ```swift
   private var observer: SendableObserver?
   
   deinit {
       if let observer = observer {
           DistributedNotificationCenter.default().removeObserver(observer.value)
       }
   }
   ```

2. **Main Actor Isolation in Closures**:
   If an observer callback closure is run in a non-isolated or background context, do not call `@MainActor` isolated methods or update `@Published` variables synchronously.
   
   **Pattern**: Wrap the call inside a `@MainActor` Task block:
   
   ```swift
   Task { @MainActor in
       self.updateMainActorState()
   }
   ```

## SwiftUI and AppKit Integration Patterns

When developing hybrid SwiftUI and AppKit macOS applications, follow these established design patterns to coordinate window life cycle, environment access, and status item event handling:

1. **Accessing the App Delegate under the SwiftUI Lifecycle**:
   SwiftUI installs its own internal forwarding delegate under the `@main` lifecycle, meaning direct casts like `NSApp.delegate as? AppDelegate` will always return `nil` even when using `@NSApplicationDelegateAdaptor`.
   
   **Pattern**: Maintain a static weak reference to the active delegate during initialization:
   ```swift
   @MainActor
   final class AppDelegate: NSObject, NSApplicationDelegate {
       private(set) static weak var shared: AppDelegate?

       override init() {
           super.init()
           AppDelegate.shared = self
       }
   }
   ```

2. **Accessing SwiftUI Environment Actions in AppKit/Non-SwiftUI Code**:
   SwiftUI window-opening closures (e.g., `@Environment(\.openWindow)`) are environment-driven and cannot be directly resolved in AppKit classes (like `NSStatusItem` delegates or controllers).
   
   **Pattern**: Host an off-screen, invisible (e.g., 1x1, borderless) `NSWindow` containing an `NSHostingView` wrapping a minimal bridge view. This view captures the environment closures in a `.task` and binds them to a shared model:
   ```swift
   let win = NSWindow(
       contentRect: NSRect(x: -100, y: -100, width: 1, height: 1),
       styleMask: [.borderless],
       backing: .buffered,
       defer: false
   )
   win.isReleasedWhenClosed = false
   win.isExcludedFromWindowsMenu = true
   win.contentView = NSHostingView(rootView: EnvironmentBridgeView(app: app))
   
   // CRITICAL: Force layout calculation so the hosting view is rendered and its .task fires
   win.contentView?.layoutSubtreeIfNeeded()
   ```
   Inside the bridge view:
   ```swift
   private struct EnvironmentBridgeView: View {
       let app: AppModel
       @Environment(\.openWindow) private var openWindow

       var body: some View {
           Color.clear
               .frame(width: 0, height: 0)
               .task {
                   app.openTimerWindow = { openWindow(id: "timer") }
               }
       }
   }
   ```

3. **Custom NSStatusItem Left/Right Click Interception**:
   When replacing SwiftUI's `MenuBarExtra` with AppKit's `NSStatusItem` to allow custom click logic (e.g. right-click to fast-path resume, left-click to show a dropdown):
   - **Dual Action Configuration**: Enable both mouse up events on the status button:
     ```swift
     button.sendAction(on: [.leftMouseUp, .rightMouseUp])
     ```
   - **Event Filtering**: Check `NSApp.currentEvent?.type == .rightMouseUp` to branch.
   - **Accessibility & VoiceOver Fallback**: Programmatic and assistive clicks arrive with no mouse event (e.g., `NSApp.currentEvent` is `nil` or has another type). Always fall back to the default left-click (showing the menu) so the status item remains accessible:
     ```swift
     @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
         if NSApp.currentEvent?.type == .rightMouseUp, app.performSecondaryAction() {
             return
         }
         // Default menu display path
     }
     ```
   - **Programmatic Menu Display**: When triggering the AppKit menu under the status item button programmatically, assign it temporarily to the status item's `menu` property, trigger it, and immediately clear it so subsequent clicks still route to the click action:
     ```swift
     let menu = buildMenu()
     statusItem.menu = menu
     sender.performClick(nil) // Opens the menu natively aligned with the item
     statusItem.menu = nil    // Clears the property to keep action forwarding active
     ```

4. **Launch Ordering with Environment Bridges**:
   If window-opening closures are captured via an environment bridge, do not execute startup actions that depend on those closures (e.g. "show window at launch" preferences) in your initial app code. At that point, the environment task has not run yet. Instead, trigger startup window-opening checks inside the bridge view's `.task` block *after* the environment closures are successfully assigned.


## SwiftUI Performance Guidelines

When developing high-frequency interactive features (e.g., hover magnification, drag-and-drop, sliders) in SwiftUI:

1. **Leaf-Level State Resolution for High-Frequency Events**:
   Avoid reading high-frequency state (such as cursor coordinates, magnification scales, or animation values) in parent container views (e.g., `TileContainerView`). Doing so invalidates the container's body and forces SwiftUI to walk/re-layout the entire child tree at up to 120 Hz.

   **Pattern**: Push the read of the high-frequency state provider (e.g., `DockMagnificationService`) down to leaf views (e.g., `TileView`). Ensure leaf views have a constant layout frame (rest size) and apply visual updates via render-only modifiers like `.scaleEffect` and `.offset`. This allows SwiftUI to skip layout passes and perform compositor-only transform updates.

2. **Lazy Context Menu Construction**:
   Do not generate right-click/context menu items, action arrays, or trigger Finder navigation queries during regular render or hover cycles (such as in `updateNSView` or body properties).

   **Pattern**: Build the context menu and fetch dynamic items lazily, on demand only when a user actually performs a right-click, Control-click, or clicks a menu button. Keep regular view updates decoupled from menu action providers to prevent garbage collection churn and unnecessary invalidations.
