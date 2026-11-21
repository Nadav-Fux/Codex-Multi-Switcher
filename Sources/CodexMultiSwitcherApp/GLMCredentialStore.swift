import Foundation
import LocalAuthentication
import Security
import CodexProfileCore

/// A user-supplied Coding Plan key lives in a mode-0600 file under the switcher
/// home (`GLMKeyFileStore`), like the Codex profiles, so rebuilding the app never
/// voids access. Older builds kept it in a Keychain item; it is migrated from
/// there once, the first time that item is readable. ZCode's encrypted
/// credentials are never copied or decrypted. The key is never logged.
enum GLMCredentialStore {
    private static var file: GLMKeyFileStore { GLMKeyFileStore() }
    /// Logs a failing silent Keychain read once per process, not every poll.
    private static let warnedLock = NSLock()
    nonisolated(unsafe) private static var warnedKeychain = false

    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.codexmultiswitcher.local") + ".usage.glm" }
    private static let account = "personal-coding-plan"

    enum Failure: LocalizedError {
        case invalidKey, unavailable
        var errorDescription: String? {
            self == .invalidKey ? "Enter a Z.ai Coding Plan API key without spaces or line breaks." : "The app could not read its saved GLM key. Reconnect or save the key again."
        }
    }

    static func load(allowInteraction: Bool = false) throws -> String? {
        do {
            if let stored = try self.file.load() { return stored }
        } catch { throw Failure.unavailable }
        // One-time migration from the legacy Keychain item.
        let legacy: String?
        do {
            legacy = try KeychainInteractionPolicy.withInteraction(allowed: allowInteraction) {
                try self.read(allowInteraction: allowInteraction)
            }
        } catch { throw Failure.unavailable }
        guard let legacy else { return nil }
        do {
            try self.file.save(legacy)
            AppLogger.info("Moved the GLM key from the Keychain to the app's private key file")
        } catch {
            AppLogger.warning("Could not write the GLM key file", metadata: ["error": String(describing: type(of: error))])
        }
        return legacy
    }

    private static func read(allowInteraction: Bool) throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            self.warnedLock.lock()
            let first = !self.warnedKeychain
            self.warnedKeychain = true
            self.warnedLock.unlock()
            if first {
                AppLogger.warning("GLM Keychain read failed; reconnect the saved key in Settings > GLM",
                                  metadata: ["osstatus": String(status)])
            }
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), valid(value) else { throw Failure.unavailable }
        return value
    }

    static func save(_ input: String) throws {
        do { try self.file.save(input) }
        catch GLMKeyFileStore.Failure.invalidKey { throw Failure.invalidKey }
        catch { throw Failure.unavailable }
        // The file is now authoritative; a leftover legacy item is harmless and
        // is removed without prompting when this build is allowed to.
        _ = SecItemDelete(self.silentQuery() as CFDictionary)
    }

    static func remove() throws {
        do { try self.file.remove() } catch { throw Failure.unavailable }
        let status = SecItemDelete(self.silentQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
            || status == errSecInteractionNotAllowed || status == errSecAuthFailed else { throw Failure.unavailable }
    }

    private static func silentQuery() -> [String: Any] {
        var query = baseQuery()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static func valid(_ value: String) -> Bool { GLMKeyFileStore.isValid(value) }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
