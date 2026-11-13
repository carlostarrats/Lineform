import Foundation
import Security

/// Storage for API keys. Production uses the Keychain; tests use an in-memory double.
protocol AIKeychain: AnyObject {
    func readKey(for provider: AIProvider) -> String?
    /// Whether an item exists, without reading the secret. Used by Connect Your AI to show a
    /// provider whose key went missing as needing to reconnect.
    func hasKey(for provider: AIProvider) -> Bool
    @discardableResult func writeKey(_ key: String, for provider: AIProvider) -> Bool
    func deleteKey(for provider: AIProvider)
}

/// Generic-password items in the legacy file keychain (no data-protection keychain, no new
/// entitlement). Service is "<bundle id>.ai"; account is the provider's raw value.
final class SystemAIKeychain: AIKeychain {
    private let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.lineform.app") + ".ai") {
        self.service = service
    }

    private func baseQuery(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }

    func readKey(for provider: AIProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasKey(for provider: AIProvider) -> Bool {
        // No kSecReturnData / kSecReturnAttributes: the query asks only whether the item
        // exists, so the key never leaves the Keychain and no access prompt is raised.
        var query = baseQuery(for: provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func writeKey(_ key: String, for provider: AIProvider) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(
            baseQuery(for: provider) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery(for: provider)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func deleteKey(for provider: AIProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }
}
