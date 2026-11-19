import Foundation
import Security

// The user's own GG.deals API key, in the Keychain. It syncs with iCloud Keychain to
// their other devices; it's never in CloudKit or the library.
enum GGDealsKeyStore {
    private static let service = "com.tinykings.void.gg-deals"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    static func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap(GGDealsAPI.cleanKey)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var item = query
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
