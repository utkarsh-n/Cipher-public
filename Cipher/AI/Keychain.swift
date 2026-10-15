import Foundation
import Security

/// The Anthropic API key lives in the keychain, never in UserDefaults or the SwiftData store.
enum Keychain {
    private static let service = "com.utkarsh.cipher.anthropic"
    private static let account = "api-key"

    static var apiKey: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var item = baseQuery
            item[kSecValueData as String] = Data(newValue.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
