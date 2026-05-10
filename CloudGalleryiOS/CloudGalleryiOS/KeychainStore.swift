import Foundation
import Security

enum KeychainStore {
    private static let service = "com.akslabs.cloudgallery.ios"
    private static let simulatorFallbackPrefix = "keychain_fallback_"

    static func string(for key: String) -> String {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            return UserDefaults.standard.string(forKey: fallbackKey(key)) ?? ""
        }

        guard status == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for key: String) throws {
        let encoded = Data(value.utf8)
        var query = baseQuery(key)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: encoded] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecMissingEntitlement {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        query[kSecValueData as String] = encoded
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
            return
        }

        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private static func fallbackKey(_ key: String) -> String {
        simulatorFallbackPrefix + key
    }
}

enum KeychainError: LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            "Keychain failed with status \(status)."
        }
    }
}
