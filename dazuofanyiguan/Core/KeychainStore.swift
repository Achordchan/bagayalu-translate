import Foundation
import Security

enum KeychainStore {
    static func setString(_ value: String, for key: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

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
            return
        }

        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }
    }

    static func getString(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }

        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            return
        }
        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }
    }
}
