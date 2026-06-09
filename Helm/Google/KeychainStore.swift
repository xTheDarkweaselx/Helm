//
//  KeychainStore.swift
//  Helm
//
//  Minimal generic-password store for the Google OAuth tokens: one JSON blob
//  per service+account. AfterFirstUnlockThisDeviceOnly so a background refresh
//  can read it post-reboot, but the refresh token never leaves this device
//  (excluded from iCloud/encrypted backups).
//

import Foundation
import Security

nonisolated struct KeychainStore: Sendable {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = baseQuery
            attributes.forEach { add[$0] = $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
