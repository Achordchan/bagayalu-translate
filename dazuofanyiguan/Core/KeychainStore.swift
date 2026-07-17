import Foundation
import Security

/// 仅把“同 account、且 service 缺失/空”的条目当作历史数据。
enum LegacyKeychainItemPolicy {
    static func isLegacyService(_ service: String?) -> Bool {
        guard let service else { return true }
        return service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum KeychainStore {
    private static let service = "com.achord.dazuofanyiguan"

    static func setString(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            if insertStatus != errSecSuccess {
                throw NSError(domain: "KeychainStore", code: Int(insertStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }

        try deleteLegacyItems(account: key)
    }

    static func getString(for key: String) throws -> String? {
        if let value = try copyString(query: baseQuery(account: key)) {
            return value
        }

        // 兼容旧版未写 service 的条目，读到后迁移到固定 service。
        guard let legacy = try copyLegacyString(account: key) else {
            return nil
        }
        try setString(legacy, for: key)
        return legacy
    }

    static func delete(for key: String) throws {
        try deleteMatching(query: baseQuery(account: key))
        try deleteLegacyItems(account: key)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func copyString(query: [String: Any]) throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func copyLegacyString(account: String) throws -> String? {
        let rows = try matchingRows(account: account)
        for row in rows {
            let rowService = row[kSecAttrService as String] as? String
            guard LegacyKeychainItemPolicy.isLegacyService(rowService) else {
                continue
            }
            if let data = row[kSecValueData as String] as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }

    private static func deleteMatching(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw NSError(domain: "KeychainStore", code: Int(status))
    }

    private static func deleteLegacyItems(account: String) throws {
        let rows = try matchingRows(account: account)
        var firstFailure: OSStatus?

        for row in rows {
            let rowService = row[kSecAttrService as String] as? String
            guard LegacyKeychainItemPolicy.isLegacyService(rowService) else {
                continue
            }
            guard let persistentRef = row[kSecValuePersistentRef as String] else {
                continue
            }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: persistentRef
            ]
            let status = SecItemDelete(deleteQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                firstFailure = firstFailure ?? status
            }
        }

        if let firstFailure {
            throw NSError(domain: "KeychainStore", code: Int(firstFailure))
        }
    }

    private static func matchingRows(account: String) throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }

        if let many = item as? [[String: Any]] {
            return many
        }
        if let one = item as? [String: Any] {
            return [one]
        }
        return []
    }
}
