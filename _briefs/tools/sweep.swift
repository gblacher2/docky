// Reveals the (autohidden) dock, then synthesises a horizontal hover sweep
// across it and restores the cursor. Used to reproduce the magnification
// gesture deterministically while `sample` runs against the app.
import CoreGraphics
import Foundation

func dockyWindowFrame() -> CGRect? {
    guard let infos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    var best: CGRect?
    for info in infos {
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              owner == "Docky",
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01,
              let dict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
              rect.width > 600, rect.height > 20, rect.height < 250
        else { continue }
        if best == nil || rect.width > best!.width { best = rect }
    }
    return best
}

func move(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

let duration = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "4") ?? 4
let hz = 120.0

/// Bounds of every active display, in the same top-left global space CGEvent
/// uses. Hardcoding these was a real bug: when the dock moved to an external
/// display the sweep clamped to the built-in screen, hovered empty space, and
/// reported 0% CPU as though magnification had become free.
func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.map { CGDisplayBounds($0) }
}

let displays = displayBounds()
guard !displays.isEmpty else {
    FileHandle.standardError.write("No active displays\n".data(using: .utf8)!)
    exit(1)
}
let desktop = displays.dropFirst().reduce(displays[0]) { $0.union($1) }
let restore = CGEvent(source: nil)?.location

// The dock is autohidden: nudge the pointer onto the bottom edge of each
// display in turn and let the reveal animation settle. We don't know up front
// which display hosts the dock.
var found: CGRect? = nil
for screen in displays {
    move(CGPoint(x: screen.midX, y: screen.maxY - 1))
    Thread.sleep(forTimeInterval: 1.2)
    if let f = dockyWindowFrame() { found = f; break }
}

guard let frame = found else {
    FileHandle.standardError.write("No dock window found after reveal on any of \(displays.count) display(s)\n".data(using: .utf8)!)
    exit(1)
}

// Clamp the sweep line inside the display that actually hosts the dock: an
// autohidden dock reports a frame extending past that display's bottom edge.
let host = displays.first { $0.intersects(frame) } ?? desktop
let y = min(frame.midY, host.maxY - 2)
guard y >= host.minY, frame.midX >= host.minX, frame.midX <= host.maxX else {
    FileHandle.standardError.write("Dock frame \(frame) not on any display \(displays)\n".data(using: .utf8)!)
    exit(1)
}
print("Displays: \(displays)")
print("Dock frame after reveal: \(frame) on host \(host) — sweeping at y=\(y)")

let x0 = frame.minX + frame.width * 0.08
let x1 = frame.maxX - frame.width * 0.08

let steps = Int(duration * hz)
let start = Date()
for i in 0...steps {
    let t = Double(i) / Double(steps)
    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    move(CGPoint(x: x0 + (x1 - x0) * eased, y: y))
    Thread.sleep(forTimeInterval: 1.0 / hz)
}
print("Swept \(steps) events in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

if let restore { move(restore) }
