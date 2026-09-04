//
//  PersonalSetupImportService.swift
//  Docky
//

import Foundation

struct PersonalSetupManifest: Codable {
    let schemaVersion: String
    let id: String
    let version: String
    let themeID: String?
    let fallbackProfileID: String
    let focusProfileID: String
    let activeProfileID: String?
    let appearance: SetupAppearance
    let behavior: SetupBehavior
    let profiles: [SetupProfile]
}

struct SetupAppearance: Codable {
    let tileSize: Double
    let largeSize: Double
    let magnification: Bool
}

struct SetupBehavior: Codable {
    let orientation: String
    let autohide: Bool
    let autohideDelay: Double
}

struct SetupProfile: Codable {
    let id: String
    let name: String
    let symbolName: String
    let accent: String
    let triggers: [SetupTrigger]
    let tiles: [SetupTile]
    let hiddenAppBundleIdentifiers: [String]?
}

struct SetupTile: Codable {
    let id: String
    let kind: String
    let bundleIdentifier: String?
    let widgetKind: String?
    let ownerBundleIdentifier: String?
    let span: Int?
    let widgets: [String]?
    let folderName: String?
    let apps: [String]?
    let settings: [String: SetupSettingValue]?
}

struct SetupTrigger: Codable {
    let id: String
    let kind: String
    let bundleIdentifier: String?
    let displayName: String?
    let ssid: String?
    let fallbackNetworkID: String?
    let startMinuteOfDay: Int?
    let endMinuteOfDay: Int?
    let weekdays: [Int]?
}

enum SetupSettingValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case stringList([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String].self) { self = .stringList(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Setup settings support string, number, boolean, or string arrays only.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .stringList(let value): try container.encode(value)
        }
    }

    var widgetValue: WidgetSettingValue {
        switch self {
        case .string(let value): .string(value)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .stringList(let value): .stringList(value)
        }
    }
}

struct PersonalSetupPreview: Codable {
    let schemaVersion: String
    let setupID: String
    let setupVersion: String
    let profileNames: [String]
    let tileCount: Int
    let fallbackProfileID: String
    let focusProfileID: String
    let preservesTrailingItems: Bool
    let preservesHiddenAppsWhenOmitted: Bool
    let warnings: [String]
}

struct LegacySetupMigrationResult: Codable {
    let cfaFieldsMerged: Int
    let marketsTokensStored: Int
}

enum PersonalSetupImportError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

@MainActor
final class PersonalSetupImportService {
    static let shared = PersonalSetupImportService()
    static let schemaVersion = "docky-personal-setup/v1"
    /// Built-in, fail-closed contracts for the personal widgets. These remain
    /// authoritative even when no bundle is installed during setup preview.
    static let knownPersonalWidgetFieldTypes: [String: [String: WidgetSettingsField.FieldType]] = [
        "com.gblacher.cfa-countdown": ["examDate": .text, "focusTopic": .text, "showsFocusTopic": .toggle],
        "com.gblacher.markets-watchlist": ["tickers": .text, "refreshMinutes": .select, "apiToken": .secureText],
        "com.gblacher.pomodoro": ["compactStyle": .select, "showsStatus": .toggle],
        "com.gblacher.scratchpad": ["previewLineCount": .number, "clickToEdit": .toggle],
        "com.gblacher.clipboard": ["historyDepth": .number],
    ]

    private let decoder = JSONDecoder()
    private init() {}

    func load(from url: URL) throws -> PersonalSetupManifest {
        try decoder.decode(PersonalSetupManifest.self, from: Data(contentsOf: url))
    }

    func preview(_ manifest: PersonalSetupManifest) throws -> PersonalSetupPreview {
        let converted = try convert(manifest, preservedTrailing: [], preservedHidden: [])
        var warnings = [String(localized: "Downloads, Trash, and other trailing items will be cloned from the current profile.")]
        if manifest.profiles.contains(where: { $0.hiddenAppBundleIdentifiers == nil }) {
            warnings.append(String(localized: "Omitted hidden-app lists will be cloned from the current profile."))
        }
        return PersonalSetupPreview(
            schemaVersion: manifest.schemaVersion,
            setupID: manifest.id,
            setupVersion: manifest.version,
            profileNames: converted.profiles.map(\.name),
            tileCount: manifest.profiles.reduce(0) { $0 + $1.tiles.count },
            fallbackProfileID: manifest.fallbackProfileID,
            focusProfileID: manifest.focusProfileID,
            preservesTrailingItems: true,
            preservesHiddenAppsWhenOmitted: true,
            warnings: warnings
        )
    }

    func apply(_ manifest: PersonalSetupManifest) throws -> LegacySetupMigrationResult {
        let current = ProfileService.shared.activeProfile
        let converted = try convert(
            manifest,
            preservedTrailing: current?.trailingItems ?? DockyPreferences.shared.trailingItems,
            preservedHidden: current?.hiddenAppBundleIdentifiers ?? DockyPreferences.shared.hiddenAppBundleIdentifiers
        )
        let migrated = try migrateLegacyWidgetConfiguration(in: converted.profiles)
        ProfileService.shared.replaceProfiles(
            migrated.profiles,
            activeProfileID: manifest.activeProfileID,
            fallbackProfileID: manifest.fallbackProfileID,
            focusProfileID: manifest.focusProfileID
        )

        let settings = DockSettingsService.shared
        settings.setTileSize(CGFloat(manifest.appearance.tileSize))
        settings.setLargeSize(CGFloat(manifest.appearance.largeSize))
        settings.setMagnification(manifest.appearance.magnification)
        DockyPreferences.shared.windowPosition = converted.windowPosition
        DockyPreferences.shared.autohidesWindow = manifest.behavior.autohide
        DockyPreferences.shared.autohideWindowDelay = manifest.behavior.autohideDelay

        if let themeID = manifest.themeID, ThemeManager.shared.installedThemes[themeID] != nil {
            ThemeManager.shared.setActive(themeID)
        }
        ProfileAutomationState.shared.resume()
        return migrated.result
    }

    private func migrateLegacyWidgetConfiguration(
        in importedProfiles: [DockProfile]
    ) throws -> (profiles: [DockProfile], result: LegacySetupMigrationResult) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docky", isDirectory: true)
        let cfa = readLegacyObject(directory.appendingPathComponent("cfa-countdown.json"))
        let examDate = (cfa?["examDate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusTopic = (cfa?["focusTopic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let markets = readLegacyObject(directory.appendingPathComponent("markets-watchlist.json"))
        let token = (markets?["brapiToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var profiles = importedProfiles
        var cfaFieldsMerged = 0
        var marketTileIDs: Set<String> = []
        for profileIndex in profiles.indices {
            for itemIndex in profiles[profileIndex].pinnedItems.indices {
                guard let kind = profiles[profileIndex].pinnedItems[itemIndex].widgetKind,
                      case .external(let identifier) = kind else { continue }
                if identifier == "com.gblacher.cfa-countdown" {
                    var settings = profiles[profileIndex].pinnedItems[itemIndex].widgetSettings ?? [:]
                    if let examDate, !examDate.isEmpty, (settings.string("examDate") ?? "").isEmpty {
                        settings["examDate"] = .string(examDate)
                        cfaFieldsMerged += 1
                    }
                    if let focusTopic, !focusTopic.isEmpty, (settings.string("focusTopic") ?? "").isEmpty {
                        settings["focusTopic"] = .string(focusTopic)
                        cfaFieldsMerged += 1
                    }
                    profiles[profileIndex].pinnedItems[itemIndex].widgetSettings = settings.isEmpty ? nil : settings
                } else if identifier == "com.gblacher.markets-watchlist", let token, !token.isEmpty {
                    marketTileIDs.insert("pinned:\(profiles[profileIndex].pinnedItems[itemIndex].id)")
                }
            }
        }

        if let token, !token.isEmpty {
            for tileID in marketTileIDs {
                guard KeychainWidgetSettingStore.shared.setValue(token, tileID: tileID, key: "apiToken") else {
                    throw PersonalSetupImportError.invalid("The legacy Markets credential could not be stored in Keychain.")
                }
            }
        }
        return (
            profiles,
            LegacySetupMigrationResult(
                cfaFieldsMerged: cfaFieldsMerged,
                marketsTokensStored: marketTileIDs.count
            )
        )
    }

    private func readLegacyObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func convert(
        _ manifest: PersonalSetupManifest,
        preservedTrailing: [TrailingTileItem],
        preservedHidden: [String]
    ) throws -> (profiles: [DockProfile], windowPosition: DockWindowPosition) {
        guard manifest.schemaVersion == Self.schemaVersion else {
            throw PersonalSetupImportError.invalid("Unsupported setup schema: \(manifest.schemaVersion)")
        }
        guard !manifest.id.isEmpty, !manifest.version.isEmpty, !manifest.profiles.isEmpty else {
            throw PersonalSetupImportError.invalid("Setup id, version, and at least one profile are required.")
        }
        let profileIDs = manifest.profiles.map(\.id)
        guard Set(profileIDs).count == profileIDs.count,
              profileIDs.allSatisfy({ !$0.isEmpty }) else {
            throw PersonalSetupImportError.invalid("Profile identifiers must be non-empty and unique.")
        }
        guard profileIDs.contains(manifest.fallbackProfileID) else {
            throw PersonalSetupImportError.invalid("fallbackProfileID must reference an imported profile.")
        }
        guard profileIDs.contains(manifest.focusProfileID) else {
            throw PersonalSetupImportError.invalid("focusProfileID must reference an imported profile.")
        }
        if let active = manifest.activeProfileID, !profileIDs.contains(active) {
            throw PersonalSetupImportError.invalid("activeProfileID must reference an imported profile.")
        }
        guard (20...128).contains(manifest.appearance.tileSize),
              manifest.appearance.largeSize >= manifest.appearance.tileSize,
              manifest.appearance.largeSize <= 192,
              (0...10).contains(manifest.behavior.autohideDelay),
              let windowPosition = DockWindowPosition(rawValue: manifest.behavior.orientation),
              windowPosition != .system else {
            throw PersonalSetupImportError.invalid("Appearance or behavior values are outside supported ranges.")
        }
        let allTileIDs = manifest.profiles.flatMap { $0.tiles.map(\.id) }
        guard Set(allTileIDs).count == allTileIDs.count else {
            throw PersonalSetupImportError.invalid("Tile identifiers must be globally unique across the setup.")
        }

        let baseDate = Date()
        let profiles = try manifest.profiles.enumerated().map { index, setup in
            guard !setup.name.isEmpty, !setup.symbolName.isEmpty,
                  let accent = ProfileAccent(rawValue: setup.accent) else {
                throw PersonalSetupImportError.invalid("Profile \(setup.id) has an invalid name, symbol, or accent.")
            }
            let tileIDs = setup.tiles.map(\.id)
            guard Set(tileIDs).count == tileIDs.count, tileIDs.allSatisfy({ !$0.isEmpty }) else {
                throw PersonalSetupImportError.invalid("Tile identifiers in \(setup.name) must be non-empty and unique.")
            }
            return DockProfile(
                id: setup.id,
                name: setup.name,
                symbolName: setup.symbolName,
                accent: accent,
                dateCreated: baseDate.addingTimeInterval(Double(index)),
                pinnedItems: try setup.tiles.map(convertTile),
                trailingItems: preservedTrailing,
                widgetPlacements: [],
                appWidgetDisplays: [],
                hiddenAppBundleIdentifiers: setup.hiddenAppBundleIdentifiers ?? preservedHidden,
                triggers: try setup.triggers.map(convertTrigger)
            )
        }
        return (profiles, windowPosition)
    }

    private func convertTile(_ tile: SetupTile) throws -> PinnedTileItem {
        func item(
            kind: PinnedTileItemKind,
            bundleIdentifier: String? = nil,
            folderName: String? = nil,
            apps: [String] = [],
            widgetKind: WidgetKind? = nil,
            owner: String? = nil,
            span: TileSpan? = nil,
            hiddenOwners: [String] = [],
            settings: WidgetSettings? = nil
        ) -> PinnedTileItem {
            PinnedTileItem(
                id: tile.id,
                kind: kind,
                bundleIdentifier: bundleIdentifier,
                folderDisplayName: folderName,
                folderBundleIdentifiers: apps,
                appFolderDisplayMode: nil,
                folderContentViewMode: nil,
                widgetKind: widgetKind,
                widgetOwnerBundleIdentifier: owner,
                widgetSpan: span,
                hiddenWidgetOwnerBundleIdentifiers: hiddenOwners,
                widgetSettings: settings
            )
        }

        switch tile.kind {
        case "launchpad": return item(kind: .launchpad)
        case "contextHub":
            guard tile.span == nil || tile.span == 2 else { throw PersonalSetupImportError.invalid("Context Hub span must be 2.") }
            return item(kind: .widget, widgetKind: .contextHub, owner: WidgetOwnerBundleIdentifiers.contextHub, span: .two)
        case "app":
            guard let bundle = tile.bundleIdentifier, !bundle.isEmpty else { throw PersonalSetupImportError.invalid("App tile \(tile.id) requires bundleIdentifier.") }
            return item(kind: .app, bundleIdentifier: bundle)
        case "appFolder":
            guard let name = tile.folderName, !name.isEmpty, let apps = tile.apps, !apps.isEmpty else {
                throw PersonalSetupImportError.invalid("App folder \(tile.id) requires folderName and apps.")
            }
            return item(kind: .appFolder, folderName: name, apps: apps)
        case "widget":
            guard let rawKind = tile.widgetKind, let kind = WidgetKind(rawValue: rawKind),
                  let owner = tile.ownerBundleIdentifier, !owner.isEmpty,
                  let rawSpan = tile.span, let span = TileSpan(rawValue: rawSpan) else {
                throw PersonalSetupImportError.invalid("Widget tile \(tile.id) has invalid kind, owner, or span.")
            }
            let settings = try convertSettings(tile.settings ?? [:], widgetKind: kind)
            return item(kind: .widget, widgetKind: kind, owner: owner, span: span, settings: settings.isEmpty ? nil : settings)
        case "smartStack":
            guard tile.span == nil || tile.span == 3 else {
                throw PersonalSetupImportError.invalid("Smart stack \(tile.id) must use span 3; Docky's current persistence format does not store another span.")
            }
            let visible = Set(tile.widgets ?? [])
            let allOwners = Set(WidgetCatalog.smartStackRegistrations.map(\.ownerBundleIdentifier))
            let unknown = visible.subtracting(allOwners)
            guard unknown.isEmpty else {
                throw PersonalSetupImportError.invalid("Smart stack \(tile.id) references unavailable widget owners: \(unknown.sorted().joined(separator: ", ")).")
            }
            return item(kind: .smartStack, hiddenOwners: Array(allOwners.subtracting(visible)).sorted())
        case "divider": return item(kind: .divider)
        case "spacer": return item(kind: .spacer)
        case "flexibleSpacer": return item(kind: .flexibleSpacer)
        default: throw PersonalSetupImportError.invalid("Unknown tile kind: \(tile.kind)")
        }
    }

    private func convertSettings(_ settings: [String: SetupSettingValue], widgetKind: WidgetKind) throws -> WidgetSettings {
        guard case .external(let identifier) = widgetKind else {
            guard settings.isEmpty else {
                throw PersonalSetupImportError.invalid("Built-in widget settings are not supported by this setup schema.")
            }
            return [:]
        }
        let loadedFields = ExternalWidgetRegistry.shared.metadata(for: identifier)?.settingsSchema ?? []
        let fieldsByID = try Self.fieldTypes(
            forExternalWidgetIdentifier: identifier,
            loadedFields: loadedFields
        )
        try Self.validateSettings(settings, fieldsByID: fieldsByID)
        return settings.mapValues(\.widgetValue)
    }

    static func fieldTypes(
        forExternalWidgetIdentifier identifier: String,
        loadedFields: [WidgetSettingsField]
    ) throws -> [String: WidgetSettingsField.FieldType] {
        if let knownFields = Self.knownPersonalWidgetFieldTypes[identifier] {
            return knownFields
        }
        guard !loadedFields.isEmpty else {
            throw PersonalSetupImportError.invalid("Settings metadata is unavailable for external widget \(identifier).")
        }
        return Dictionary(uniqueKeysWithValues: loadedFields.map { ($0.id, $0.type) })
    }

    static func validateSettings(
        _ settings: [String: SetupSettingValue],
        fieldsByID: [String: WidgetSettingsField.FieldType]
    ) throws {
        let unknownKeys = Set(settings.keys).subtracting(fieldsByID.keys)
        guard unknownKeys.isEmpty else {
            throw PersonalSetupImportError.invalid("Unknown widget settings cannot be imported: \(unknownKeys.sorted().joined(separator: ", ")).")
        }
        for (key, value) in settings {
            guard let fieldType = fieldsByID[key], fieldType != .secureText else {
                throw PersonalSetupImportError.invalid("secureText values must be entered through Docky's Keychain-backed settings UI.")
            }
            let validType: Bool = switch (fieldType, value) {
            case (.text, .string), (.text, .stringList), (.select, .string),
                 (.number, .number), (.toggle, .bool): true
            case (.secureText, _): false
            default: false
            }
            guard validType else {
                throw PersonalSetupImportError.invalid("Widget setting \(key) has the wrong value type.")
            }
        }
    }

    private func convertTrigger(_ trigger: SetupTrigger) throws -> ProfileTrigger {
        switch trigger.kind {
        case "timeOfDay":
            guard let start = trigger.startMinuteOfDay, let end = trigger.endMinuteOfDay,
                  (0...1439).contains(start), (0...1439).contains(end),
                  let weekdays = trigger.weekdays, !weekdays.isEmpty,
                  weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw PersonalSetupImportError.invalid("Time trigger \(trigger.id) has invalid minutes or weekdays.")
            }
            return .timeOfDay(TimeOfDayTrigger(id: trigger.id, startMinuteOfDay: start, endMinuteOfDay: end, weekdays: Set(weekdays)))
        case "frontmostApp":
            guard let bundle = trigger.bundleIdentifier, !bundle.isEmpty else { throw PersonalSetupImportError.invalid("Frontmost-app trigger \(trigger.id) needs bundleIdentifier.") }
            return .frontmostApp(FrontmostAppTrigger(id: trigger.id, bundleIdentifier: bundle))
        case "space":
            guard let bundle = trigger.bundleIdentifier, !bundle.isEmpty else { throw PersonalSetupImportError.invalid("Space trigger \(trigger.id) needs bundleIdentifier.") }
            return .space(SpaceTrigger(id: trigger.id, bundleIdentifier: bundle))
        case "display": return .display(DisplayTrigger(id: trigger.id, displayName: trigger.displayName))
        case "wifi":
            guard let ssid = trigger.ssid, !ssid.isEmpty || !(trigger.fallbackNetworkID?.isEmpty ?? true) else {
                throw PersonalSetupImportError.invalid("Wi-Fi trigger \(trigger.id) must identify a network.")
            }
            return .wifi(WiFiTrigger(id: trigger.id, ssid: ssid, fallbackNetworkID: trigger.fallbackNetworkID))
        default: throw PersonalSetupImportError.invalid("Unknown trigger kind: \(trigger.kind)")
        }
    }
}
