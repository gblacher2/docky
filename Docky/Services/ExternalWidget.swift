//
//  ExternalWidget.swift
//  Docky
//
//  Plugin contract + in-process registry for community-supplied widget
//  bundles. The protocol is intentionally @objc and Cocoa-only so third
//  parties don't need to link against Docky's Swift module: they ship a
//  principal class deriving from NSObject and conforming to
//  DockyWidgetPlugin, and Docky finds it via Bundle.principalClass at
//  load time.
//

import AppKit
import Foundation
import SwiftUI

@objc(DockyWidgetPlugin) public protocol DockyWidgetPlugin: AnyObject {
    @objc init()

    var identifier: String { get }
    var displayName: String { get }
    var systemImageName: String { get }

    var defaultSpanValue: Int { get }
    var supportedSpanValues: [Int] { get }
    var expansionWidthTiles: Int { get }
    var expansionHeightTiles: Int { get }
    var isExpandable: Bool { get }
    var includesInPalette: Bool { get }
    var includesInSmartStack: Bool { get }

    /// Author shown in the Widget Store row. Optional for compatibility
    /// with older widgets; defaults to "Unknown".
    @objc optional var author: String { get }

    /// Marketing version string shown in the Widget Store row (e.g. "1.2.0").
    /// Optional; defaults to "1.0".
    @objc optional var version: String { get }

    func makeView(
        cornerRadius: CGFloat,
        renderedSpanValue: Int,
        isWithinStack: Bool,
        isExpanded: Bool,
        isExpandedPreviewOpen: Bool
    ) -> NSView

    /// Configured variant: receives the instance's settings as Cocoa primitives.
    /// Optional; unimplemented plugins fall back to `makeView` above.
    @objc optional func makeView(
        cornerRadius: CGFloat,
        renderedSpanValue: Int,
        isWithinStack: Bool,
        isExpanded: Bool,
        isExpandedPreviewOpen: Bool,
        configuration: [String: Any]
    ) -> NSView
}

/// Metadata extracted from a loaded plugin, normalized into Docky's
/// type system. Captured once at registration so subsequent reads don't
/// re-cross the @objc boundary.
struct ExternalWidgetMetadata: Equatable {
    let identifier: String
    let displayName: String
    let systemImageName: String
    let defaultSpan: TileSpan
    let supportedSpans: [TileSpan]
    let expansionExtent: WidgetExpansionExtent
    let isExpandable: Bool
    let includesInPalette: Bool
    let includesInSmartStack: Bool
    let author: String
    let version: String
    /// From the bundle's settings.json manifest; empty means no settings.
    let settingsSchema: [WidgetSettingsField]
}

/// Live registration backed by a loaded plugin instance. `view(for:)` is
/// what WidgetTileView delegates to for `.external` kinds.
final class ExternalWidgetRegistration {
    let metadata: ExternalWidgetMetadata
    let bundleURL: URL
    private let plugin: DockyWidgetPlugin

    init(plugin: DockyWidgetPlugin, bundleURL: URL, settingsSchema: [WidgetSettingsField] = []) {
        self.bundleURL = bundleURL
        self.plugin = plugin
        self.metadata = ExternalWidgetMetadata(
            identifier: plugin.identifier,
            displayName: plugin.displayName,
            systemImageName: plugin.systemImageName,
            defaultSpan: TileSpan(rawValue: plugin.defaultSpanValue) ?? .three,
            supportedSpans: plugin.supportedSpanValues.compactMap(TileSpan.init(rawValue:)),
            expansionExtent: WidgetExpansionExtent(
                widthTiles: max(plugin.expansionWidthTiles, 1),
                heightTiles: max(plugin.expansionHeightTiles, 1)
            ),
            isExpandable: plugin.isExpandable,
            includesInPalette: plugin.includesInPalette,
            includesInSmartStack: plugin.includesInSmartStack,
            author: plugin.author ?? "Unknown",
            version: plugin.version ?? "1.0",
            settingsSchema: settingsSchema
        )
    }

    func view(
        cornerRadius: CGFloat,
        renderedSpan: TileSpan,
        isWithinStack: Bool,
        isExpanded: Bool,
        isExpandedPreviewOpen: Bool,
        settings: WidgetSettings = [:],
        settingsStorageID: String? = nil
    ) -> NSView {
        let configuration = KeychainWidgetSettingStore.shared.configuration(
            tileID: settingsStorageID,
            settings: settings,
            schema: metadata.settingsSchema
        )
        if let configured = plugin.makeView?(
            cornerRadius: cornerRadius,
            renderedSpanValue: renderedSpan.rawValue,
            isWithinStack: isWithinStack,
            isExpanded: isExpanded,
            isExpandedPreviewOpen: isExpandedPreviewOpen,
            configuration: configuration
        ) {
            return configured
        }

        return plugin.makeView(
            cornerRadius: cornerRadius,
            renderedSpanValue: renderedSpan.rawValue,
            isWithinStack: isWithinStack,
            isExpanded: isExpanded,
            isExpandedPreviewOpen: isExpandedPreviewOpen
        )
    }
}

/// Singleton registry. The discoverer (ExternalWidgetLoader) pushes
/// registrations in once at startup; the rest of the app reads from
/// `byIdentifier` to resolve `.external` kinds.
final class ExternalWidgetRegistry {
    static let shared = ExternalWidgetRegistry()

    private(set) var registrations: [ExternalWidgetRegistration] = []
    private var index: [String: ExternalWidgetRegistration] = [:]

    private init() {}

    func register(_ registration: ExternalWidgetRegistration) {
        let identifier = registration.metadata.identifier
        if index[identifier] != nil {
            return
        }
        registrations.append(registration)
        index[identifier] = registration
    }

    func registration(for identifier: String) -> ExternalWidgetRegistration? {
        index[identifier]
    }

    func metadata(for identifier: String) -> ExternalWidgetMetadata? {
        index[identifier]?.metadata
    }
}
