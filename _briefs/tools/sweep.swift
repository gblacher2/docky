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

let screenH: CGFloat = 956
let screenW: CGFloat = 1470
let restore = CGEvent(source: nil)?.location

// The dock is autohidden: nudge the pointer onto the bottom edge and let the
// reveal animation settle before measuring where the chrome actually landed.
move(CGPoint(x: screenW / 2, y: screenH - 1))
Thread.sleep(forTimeInterval: 1.2)

guard let frame = dockyWindowFrame() else {
    FileHandle.standardError.write("No dock window found after reveal\n".data(using: .utf8)!)
    exit(1)
}
// Clamp the sweep line inside the visible screen: a hidden dock reports a
// frame that extends past the bottom edge.
let y = min(frame.midY, screenH - 2)
print("Dock frame after reveal: \(frame) — sweeping at y=\(y)")

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
