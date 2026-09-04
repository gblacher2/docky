//
//  KeychainWidgetSettingStore.swift
//  Docky
//

import Foundation
import Security

final class KeychainWidgetSettingStore {
    static let shared = KeychainWidgetSettingStore()

    private let service = "gt.quintero.Docky.widget-setting"
    private init() {}

    func value(tileID: String, key: String) -> String? {
        var query = baseQuery(tileID: tileID, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setValue(_ value: String?, tileID: String, key: String) -> Bool {
        let query = baseQuery(tileID: tileID, key: key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let updates: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func configuration(
        tileID: String?,
        settings: WidgetSettings,
        schema: [WidgetSettingsField]
    ) -> [String: Any] {
        let secureKeys = Set(schema.filter { $0.type == .secureText }.map(\.id))
        var result = settings
            .filter { !secureKeys.contains($0.key) }
            .mapValues(\.cocoaValue)
        if let tileID {
            for key in secureKeys {
                if let value = value(tileID: tileID, key: key) { result[key] = value }
            }
        }
        return result
    }

    private func baseQuery(tileID: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(tileID):\(key)",
        ]
    }
}
