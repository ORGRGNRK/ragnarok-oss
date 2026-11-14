import Foundation
import Security

/// Secrets live ONLY in the login Keychain. Never printed, logged, or written to disk.
enum Keychain {
    static let service = "com.orgrgnrk.PhoneGrader"
    enum Account: String { case anthropicAPIKey = "anthropic-api-key", gradeLogToken = "grade-log-token", sickwAPIKey = "sickw-api-key" }

    static func get(_ a: Account) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: a.rawValue,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for a: Account) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: a.rawValue]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ a: Account) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: a.rawValue]
        SecItemDelete(q as CFDictionary)
    }

    static func has(_ a: Account) -> Bool { !(get(a) ?? "").isEmpty }
}
