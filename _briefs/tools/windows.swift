import CoreGraphics
import Foundation

// Include off-screen windows too: the dock may be hidden or unmapped.
guard let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { exit(1) }

for info in infos {
    guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Docky" else { continue }
    let name = info[kCGWindowName as String] as? String ?? "<no name>"
    let layer = info[kCGWindowLayer as String] as? Int ?? -999
    let wid = info[kCGWindowNumber as String] as? Int ?? -1
    let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
    let dict = info[kCGWindowBounds as String] as? [String: Any]
    let rect = dict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
    print("id=\(wid) name='\(name)' layer=\(layer) onscreen=\(onscreen) alpha=\(alpha) rect=\(rect)")
}
