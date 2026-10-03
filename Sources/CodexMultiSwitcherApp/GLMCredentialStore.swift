import Foundation
import LocalAuthentication
import Security

/// A user-supplied Coding Plan key lives in this app's own Keychain item.
/// ZCode's encrypted credentials are never copied or decrypted.
enum GLMCredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.codexmultiswitcher.local") + ".usage.glm" }
    private static let account = "personal-coding-plan"

    enum Failure: LocalizedError {
        case invalidKey, unavailable
        var errorDescription: String? {
            self == .invalidKey ? "Enter a Z.ai Coding Plan API key without spaces or line breaks." : "The app could not access its GLM Keychain item."
        }
    }

    static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), valid(value) else { throw Failure.unavailable }
        return value
    }

    static func save(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(value) else { throw Failure.invalidKey }
        let data = Data(value.utf8)
        let query = baseQuery()
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.unavailable }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
