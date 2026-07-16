//
//  ExternalWidgetLoader.swift
//  Docky
//
//  Discovers third-party widget bundles in
//  ~/Library/Application Support/Docky/Widgets/ and pushes their
//  principal classes into ExternalWidgetRegistry at app launch.
//
//  Bundle layout the loader expects:
//      MyWidget.dockywidget/
//          Contents/
//              Info.plist      (NSPrincipalClass = "MyWidget.MyWidget")
//              MacOS/MyWidget  (the compiled binary)
//
//  Failures are logged and skipped — a single malformed plugin must
//  never block the app from launching.
//

import AppKit
import Foundation
import ObjectiveC.runtime
import os.log

@MainActor
final class ExternalWidgetLoader {
    static let shared = ExternalWidgetLoader()

    private let log = Logger(subsystem: "gt.quintero.Docky", category: "ExternalWidgetLoader")
    private(set) var hasDiscovered = false

    /// Reason the loader couldn't bring a bundle into the registry. Used
    /// by the settings pane to distinguish "we haven't tried yet" (the
    /// user just installed it) from "we tried at launch and bounced."
    enum LoadFailure: String {
        case bundleNotOpenable
        case missingExecutable
        case loadCallFailed
        case missingPrincipalClass
        case notConformingToProtocol

        var localizedReason: String {
            switch self {
            case .bundleNotOpenable: "Bundle could not be opened."
            case .missingExecutable: "Bundle has no compiled binary in Contents/MacOS/."
            case .loadCallFailed: "Bundle.load() failed. Check code signing."
            case .missingPrincipalClass: "Info.plist is missing NSPrincipalClass."
            case .notConformingToProtocol: "Principal class does not conform to DockyWidgetPlugin."
            }
        }
    }

    /// Per-bundle outcome from the most recent discovery pass. The
    /// settings pane reads this so failed bundles surface a meaningful
    /// badge instead of staying on "Needs Restart" forever.
    private(set) var loadFailures: [URL: LoadFailure] = [:]

    /// File extension Docky recognizes as a widget bundle. Distinct from
    /// `.bundle` so users can keep arbitrary loadable bundles in the
    /// directory without Docky trying to instantiate them.
    static let bundleExtension = "dockywidget"

    private init() {}

    /// Idempotent. Safe to call multiple times; only the first call
    /// actually scans the directory. External widgets are a Pro feature;
    /// when the user isn't on Pro the discovery pass is skipped so
    /// nothing in the dock layout silently uses a third-party widget.
    func discoverAndLoad(createDirectoryIfNeeded: Bool = true) {
        guard !hasDiscovered else { return }
        hasDiscovered = true

        let directory = widgetsDirectory
        if createDirectoryIfNeeded {
            ensureDirectoryExists(directory)
        } else if !FileManager.default.fileExists(atPath: directory.path) {
            return
        }

        let urls = bundleURLs(in: directory)
        log.info("Scanning \(directory.path, privacy: .public) found \(urls.count) bundle(s)")

        for url in urls {
            loadBundle(at: url)
        }
    }

    /// Public for the settings pane: lists every `*.dockywidget` file on
    /// disk, whether or not Docky has loaded it yet. Lets the UI surface
    /// bundles dropped in after launch (visible, marked as needing a
    /// restart).
    func installedBundleURLs() -> [URL] {
        let directory = widgetsDirectory
        ensureDirectoryExists(directory)
        return bundleURLs(in: directory)
    }

    /// Copies a `*.dockywidget` bundle into the Widgets directory. The
    /// caller is responsible for prompting the user to restart Docky;
    /// Bundle.load() can only run once per launch.
    func installBundle(from sourceURL: URL) throws -> URL {
        let directory = widgetsDirectory
        ensureDirectoryExists(directory)

        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        // Defensive: clear quarantine xattrs that may have followed the
        // bundle through Finder drag-from-Safari or other download paths.
        Self.clearExtendedAttributes(at: destination)
        log.info("Installed widget bundle to \(destination.path, privacy: .public)")
        return destination
    }

    private static func clearExtendedAttributes(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// Removes a `*.dockywidget` bundle from disk. The in-memory plugin
    /// stays registered until the next launch (Bundle.load() is
    /// one-way); the UI surfaces this with a restart-required notice.
    func uninstallBundle(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
        log.info("Removed widget bundle at \(url.path, privacy: .public)")
    }

    /// `~/Library/Application Support/Docky/Widgets/`. Public so the
    /// settings pane can offer "Reveal in Finder" and the loader can
    /// share one source of truth for the directory location.
    var widgetsDirectory: URL {
        Self.widgetsDirectoryURL()
    }

    static func widgetsDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")

        return appSupport
            .appendingPathComponent("Docky", isDirectory: true)
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    private func ensureDirectoryExists(_ directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func bundleURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.filter { $0.pathExtension == Self.bundleExtension }
    }

    private func loadBundle(at url: URL) {
        let standardized = url.standardizedFileURL

        guard let bundle = Bundle(url: url) else {
            log.error("Could not open bundle at \(url.path, privacy: .public)")
            loadFailures[standardized] = .bundleNotOpenable
            return
        }

        if let executableURL = bundle.executableURL,
           !FileManager.default.fileExists(atPath: executableURL.path) {
            log.error("\(url.lastPathComponent, privacy: .public) has no executable at \(executableURL.path, privacy: .public). The Bundle target likely produced no binary; check that the principal class's source file is in Compile Sources.")
            loadFailures[standardized] = .missingExecutable
            return
        }

        guard bundle.load() else {
            log.error("Bundle.load() failed for \(url.lastPathComponent, privacy: .public). Check codesigning and library validation.")
            loadFailures[standardized] = .loadCallFailed
            return
        }

        guard let principalClass = bundle.principalClass else {
            log.error("\(url.lastPathComponent, privacy: .public) has no NSPrincipalClass in Info.plist")
            loadFailures[standardized] = .missingPrincipalClass
            return
        }

        guard let pluginType = principalClass as? DockyWidgetPlugin.Type else {
            let adopted = Self.adoptedProtocolNames(of: principalClass)
            let adoptedDescription = adopted.isEmpty ? "(none)" : adopted.joined(separator: ", ")
            log.error("\(url.lastPathComponent, privacy: .public) principal class \(NSStringFromClass(principalClass), privacy: .public) does not conform to DockyWidgetPlugin. Adopts: \(adoptedDescription, privacy: .public). If you see a Swift-mangled name like _TtP...DockyWidgetPlugin_, the protocol declaration in the bundle is missing @objc.")
            loadFailures[standardized] = .notConformingToProtocol
            return
        }

        let plugin = pluginType.init()
        let settingsSchema = ExternalWidgetSettingsManifest.load(from: bundle)
        let registration = ExternalWidgetRegistration(
            plugin: plugin,
            bundleURL: url,
            settingsSchema: settingsSchema
        )
        ExternalWidgetRegistry.shared.register(registration)
        loadFailures.removeValue(forKey: standardized)

        log.info("Registered external widget '\(registration.metadata.identifier, privacy: .public)' from \(url.lastPathComponent, privacy: .public)")
    }

    private static func adoptedProtocolNames(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyProtocolList(cls, &count) else { return [] }
        return (0..<Int(count)).map { String(cString: protocol_getName(list[$0])) }
    }
}
