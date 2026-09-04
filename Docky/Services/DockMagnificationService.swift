//
//  DockMagnificationService.swift
//  Docky
//
//  Drives the live "scale icons under the cursor" effect. Pointer state is
//  pushed from a SwiftUI `.onContinuousHover` on the tile container; the
//  enter/exit ramp is interpolated here so neither the cursor stream nor
//  the magnification factor ever pop.
//

import Combine
import CoreGraphics
import Foundation
import Observation
import QuartzCore

@Observable
@MainActor
final class TileMagnificationState {
    var scale: CGFloat = 1.0
    var offset: CGFloat = 0.0
}

@Observable
@MainActor
final class DockMagnificationService {
    static let shared = DockMagnificationService()

    /// Animated factor in [0, 1]. Multiplied into the per-icon falloff so the
    /// effect ramps in/out without a jarring snap when the cursor crosses
    /// the dock boundary.
    private(set) var strength: CGFloat = 0

    /// Pointer location in the tile container's local coordinate space, or
    /// nil when the magnification is suppressed or pointer is outside.
    private(set) var pointerLocation: CGPoint? = nil

    /// Maps the cosine half-bell so that t=0 → 1 and t=1 → 0.
    /// Apple Dock's curve has been studied this way; not a perfect match
    /// but visually very close.
    private static let rampDuration: CFTimeInterval = 0.15

    @ObservationIgnored private var rampSource: CGFloat = 0
    @ObservationIgnored private var rampTarget: CGFloat = 0
    @ObservationIgnored private var rampStart: CFTimeInterval = 0
    @ObservationIgnored private var rampTimer: Timer?

    // Individual tile states, observed by the leaves
    var tileStates: [String: TileMagnificationState] = [:]

    // Anchor offset, observed by the leaves
    var anchorOffset: CGFloat = 0

    // Cached layout parameters
    @ObservationIgnored private var cachedTiles: [Tile] = []
    @ObservationIgnored private var cachedTileSize: CGFloat = 0
    @ObservationIgnored private var cachedTileHeight: CGFloat = 0
    @ObservationIgnored private var cachedSpacing: CGFloat = 0
    @ObservationIgnored private var cachedPosition: ResolvedDockWindowPosition = .bottom
    @ObservationIgnored private var cachedCompactWidgets: Bool = false
    @ObservationIgnored private var cachedRestCenters: [String: CGFloat] = [:]
    @ObservationIgnored private var cachedCanvasFrame: CGRect = .zero

    private init() {}

    /// Pointer has entered the dock hit region and we now have a live axis
    /// coordinate to track.
    func updatePointer(at location: CGPoint) {
        // Sub-pixel pointer jitter would publish identical-looking values
        // and re-render the dock for nothing. Round-trip suppression keeps
        // mouseMoved spam from spiking CPU.
        if let current = pointerLocation,
           abs(current.x - location.x) < 0.25,
           abs(current.y - location.y) < 0.25 {
            // Skip publishing, but still nudge the ramp in case strength
            // was driving back toward zero.
        } else {
            pointerLocation = location
            recomputeGeometry()
        }
        beginRamp(to: 1)
    }

    /// Pointer has left the dock hit region.
    func clearPointer() {
        beginRamp(to: 0)
    }

    func updateLayoutParameters(
        tiles: [Tile],
        tileSize: CGFloat,
        tileHeight: CGFloat,
        spacing: CGFloat,
        position: ResolvedDockWindowPosition,
        compactWidgets: Bool,
        restCenters: [String: CGFloat],
        canvasFrame: CGRect
    ) {
        self.cachedTiles = tiles
        self.cachedTileSize = tileSize
        self.cachedTileHeight = tileHeight
        self.cachedSpacing = spacing
        self.cachedPosition = position
        self.cachedCompactWidgets = compactWidgets
        self.cachedRestCenters = restCenters
        self.cachedCanvasFrame = canvasFrame

        // Ensure tileStates has an entry for each active tile
        for tile in tiles {
            if tileStates[tile.id] == nil {
                tileStates[tile.id] = TileMagnificationState()
            }
        }

        // Run walk once to update geometry
        recomputeGeometry()
    }

    private func beginRamp(to target: CGFloat) {
        if rampTarget == target { return }
        rampSource = strength
        rampTarget = target
        rampStart = CACurrentMediaTime()
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard rampTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - rampStart
        let t = min(1, max(0, elapsed / Self.rampDuration))
        let eased = 1 - pow(1 - t, 2)
        let next = rampSource + (rampTarget - rampSource) * CGFloat(eased)
        if abs(next - strength) > 0.0001 {
            strength = next
        }
        if t >= 1 {
            if abs(strength - rampTarget) > 0.0001 {
                strength = rampTarget
            }
            if rampTarget == 0 {
                pointerLocation = nil
            }
            rampTimer?.invalidate()
            rampTimer = nil
        }
        recomputeGeometry()
    }

    private func recomputeGeometry() {
        let cursorOpt: CGFloat? = {
            guard let pointer = pointerLocation else { return nil }
            let canvasOrigin = cachedCanvasFrame.origin
            let local = CGPoint(x: pointer.x - canvasOrigin.x, y: pointer.y - canvasOrigin.y)
            let cursorInCanvas = cachedPosition.isVertical ? local.y : local.x

            let canvasAxisLength = cachedPosition.isVertical ? cachedCanvasFrame.size.height : cachedCanvasFrame.size.width
            let contentAxisLength = totalAxisLength()
            guard contentAxisLength <= canvasAxisLength + 0.5 else {
                return cursorInCanvas
            }
            let leadingOffset = max(0, (canvasAxisLength - contentAxisLength) / 2)
            return cursorInCanvas - leadingOffset
        }()

        guard let cursor = cursorOpt, strength > 0 else {
            for state in tileStates.values {
                state.scale = 1.0
                state.offset = 0.0
            }
            anchorOffset = 0
            publishChromeGrowth(0)
            return
        }

        let centers = cachedRestCenters
        let restSize = cachedTileSize
        let largeSize = DockSettingsService.shared.largeSize

        let tiles = cachedTiles
        let spacing = cachedSpacing
        var restCursor: CGFloat = 8.0
        var magCursor: CGFloat = 8.0
        var totalGrowth: CGFloat = 0
        var anchoredMag: CGFloat? = nil

        if cursor < 8.0 {
            anchoredMag = cursor
        }

        for (index, tile) in tiles.enumerated() {
            if index > 0 {
                let restGapStart = restCursor
                restCursor += spacing
                magCursor += spacing
                if anchoredMag == nil, cursor < restCursor {
                    let denom = spacing > 0 ? spacing : 1
                    let fraction = (cursor - restGapStart) / denom
                    anchoredMag = magCursor - spacing + fraction * spacing
                }
            }

            let tileRestSize = projected(restSizeForTile(tile))

            let iconSize: CGFloat
            if shouldMagnify(tile), let center = centers[tile.id] {
                let distance = abs(cursor - center)
                let influenceRadius = restSize * 2.5
                let t = min(1, distance / influenceRadius)
                let falloff = 0.5 * (1 + cos(.pi * t)) * strength
                iconSize = restSize + (largeSize - restSize) * falloff
            } else {
                iconSize = restSize
            }

            let magSize: CGFloat
            if iconSize > restSize {
                let magHeight = iconSize + (cachedTileHeight - restSize)
                magSize = projected(restSizeForTile(tile, customTileSize: iconSize, customTileHeight: magHeight))
            } else {
                magSize = tileRestSize
            }

            let restTileStart = restCursor
            let magTileStart = magCursor
            restCursor += tileRestSize
            magCursor += magSize

            if anchoredMag == nil, cursor < restCursor {
                let denom = tileRestSize > 0 ? tileRestSize : 1
                let fraction = (cursor - restTileStart) / denom
                anchoredMag = magTileStart + fraction * magSize
            }

            totalGrowth += magSize - tileRestSize

            let scale = largeSize > 0 ? iconSize / largeSize : 1.0
            let offset = magTileStart - restTileStart + (magSize - tileRestSize) / 2

            if let state = tileStates[tile.id] {
                state.scale = scale
                state.offset = offset
            }
        }

        let resolvedAnchoredMag = anchoredMag ?? (cursor + totalGrowth)

        let canvasAxisLength = cachedPosition.isVertical ? cachedCanvasFrame.size.height : cachedCanvasFrame.size.width
        let contentAxisLength = totalAxisLength()
        if contentAxisLength <= canvasAxisLength + 0.5 {
            anchorOffset = 0
        } else {
            anchorOffset = cursor - resolvedAnchoredMag
        }

        publishChromeGrowth(totalGrowth)
    }

    private func totalAxisLength() -> CGFloat {
        let tiles = cachedTiles
        let spacing = cachedSpacing
        var length: CGFloat = 8.0 * 2
        for (index, tile) in tiles.enumerated() {
            let size = restSizeForTile(tile)
            length += projected(size)
            if index < tiles.count - 1 {
                length += spacing
            }
        }
        return length
    }

    private func restSizeForTile(_ tile: Tile, customTileSize: CGFloat? = nil, customTileHeight: CGFloat? = nil) -> CGSize {
        let size = customTileSize ?? cachedTileSize
        let height = customTileHeight ?? cachedTileHeight
        return TileContainerView.size(
            for: tile,
            tileSize: size,
            tileHeight: height,
            tileSpacing: cachedSpacing,
            position: cachedPosition,
            compactWidgets: cachedCompactWidgets
        )
    }

    private func projected(_ size: CGSize) -> CGFloat {
        cachedPosition.isVertical ? size.height : size.width
    }

    private func shouldMagnify(_ tile: Tile) -> Bool {
        switch tile.content {
        case .app(let app):
            if let widget = app.displayedWidget {
                return effectiveWidgetSpan(widget.span) == .one
            }
            return true
        case .folder, .trash, .appFolder, .minimizedWindow, .launchpad, .startMenu, .spacer, .flexibleSpacer:
            return true
        case .widget(let widget):
            return effectiveWidgetSpan(widget.span) == .one
        case .smartStack(let stack):
            return effectiveWidgetSpan(stack.span) == .one
        case .divider:
            return false
        }
    }

    private func effectiveWidgetSpan(_ span: TileSpan) -> TileSpan {
        if cachedCompactWidgets || cachedPosition.isVertical {
            return .one
        }
        return span
    }

    private func publishChromeGrowth(_ value: CGFloat) {
        DispatchQueue.main.async {
            DockChromeMetricsService.shared.setAlongAxisGrowth(value)
        }
    }
}
