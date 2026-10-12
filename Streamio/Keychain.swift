import Foundation
import Security

enum Keychain {
    static let authKeyKey = "streamio.authKey"
    static let emailKey = "streamio.email"
    static func addonConfigKey(_ manifestId: String) -> String { "streamio.addon.\(manifestId).config" }

    private static let service = "com.barkleesanders.streamio"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var q = baseQuery(key)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let s = SecItemDelete(baseQuery(key) as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
