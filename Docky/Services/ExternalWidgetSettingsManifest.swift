//
//  ExternalWidgetSettingsManifest.swift
//  Docky
//

import Foundation

enum ExternalWidgetSettingsManifest {
    static let resourceName = "settings"
    static let resourceExtension = "json"

    static func load(from bundle: Bundle) -> [WidgetSettingsField] {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [WidgetSettingsField] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFields = root["fields"] as? [[String: Any]] else {
            return []
        }
        var fields: [WidgetSettingsField] = []
        for rawField in rawFields {
            if let field = parseField(rawField) {
                fields.append(field)
            }
        }
        return fields
    }

    private static func parseField(_ dict: [String: Any]) -> WidgetSettingsField? {
        guard let id = (dict["id"] as? String), !id.isEmpty,
              let typeRaw = dict["type"] as? String,
              let type = WidgetSettingsField.FieldType(rawValue: typeRaw) else {
            return nil
        }

        let label = (dict["label"] as? String) ?? id
        let defaultValue = parseDefault(dict["default"], type: type)

        let options: [WidgetSettingsField.Option]?
        if type == .select, let rawOptions = dict["options"] as? [[String: Any]] {
            options = rawOptions.compactMap { option in
                guard let value = option["value"] as? String else { return nil }
                return WidgetSettingsField.Option(
                    value: value,
                    label: (option["label"] as? String) ?? value
                )
            }
        } else {
            options = nil
        }

        return WidgetSettingsField(
            id: id,
            label: label,
            type: type,
            defaultValue: defaultValue,
            options: options
        )
    }

    private static func parseDefault(_ raw: Any?, type: WidgetSettingsField.FieldType) -> WidgetSettingValue? {
        guard let raw else { return nil }
        switch type {
        case .text, .select:
            return (raw as? String).map(WidgetSettingValue.string)
        case .secureText:
            return nil
        case .number:
            return (raw as? NSNumber).map { .number($0.doubleValue) }
        case .toggle:
            if let bool = raw as? Bool {
                return .bool(bool)
            }
            return (raw as? NSNumber).map { .bool($0.boolValue) }
        }
    }
}
