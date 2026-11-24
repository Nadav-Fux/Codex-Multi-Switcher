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
    private static var file: GLMKeyFileStore { self.fileStoreProvider() }
    /// Test seams; production uses the switcher-home file and the real Keychain.
    nonisolated(unsafe) static var fileStoreProvider: () -> GLMKeyFileStore = { GLMKeyFileStore() }
    // The interaction policy lives inside the default seam so an injected
    // reader never reaches a Security.framework call.
    nonisolated(unsafe) static var legacyItemReader: (Bool) throws -> String? = { allowed in
        try KeychainInteractionPolicy.withInteraction(allowed: allowed) {
            try GLMCredentialStore.read(allowInteraction: allowed)
        }
    }
    nonisolated(unsafe) static var legacyItemDeleter: () -> OSStatus = {
        SecItemDelete(GLMCredentialStore.silentQuery() as CFDictionary)
    }
    /// Serializes load-migration, save and remove: a `remove` landing while a
    /// `load` still holds a legacy item must never let that item be saved back.
    private static let migrationLock = NSLock()
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
        let file = self.file
        self.migrationLock.lock()
        let stored: String?
        do {
            stored = try file.load()
        } catch {
            self.migrationLock.unlock()
            throw Failure.unavailable
        }
        // An earlier save/remove already decided the key's state: a leftover
        // legacy Keychain item must never be migrated back.
        let decided = file.hasNoLegacyMigrationMarker
        self.migrationLock.unlock()
        if let stored { return stored }
        guard !decided else { return nil }
        // The legacy Keychain read can wait on a user prompt, so it runs
        // outside the lock: a main-thread save/remove must never block on it.
        let legacy: String?
        do {
            legacy = try self.legacyItemReader(allowInteraction)
        } catch { throw Failure.unavailable }
        guard let legacy else { return nil }
        self.migrationLock.lock()
        defer { self.migrationLock.unlock() }
        // Re-check under the lock: a save/remove that landed while the legacy
        // read ran already decided the key's state and wins over the item.
        do {
            if let stored = try file.load() { return stored }
        } catch { throw Failure.unavailable }
        guard !file.hasNoLegacyMigrationMarker else { return nil }
        do {
            try file.save(legacy)
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
        self.migrationLock.lock()
        defer { self.migrationLock.unlock() }
        let file = self.file
        do {
            try file.save(input)
            // Record the decision so a leftover legacy item cannot return.
            try? file.markNoLegacyMigration()
        }
        catch GLMKeyFileStore.Failure.invalidKey { throw Failure.invalidKey }
        catch { throw Failure.unavailable }
        // The file is now authoritative; a leftover legacy item is harmless and
        // is removed without prompting when this build is allowed to.
        _ = self.legacyItemDeleter()
    }

    static func remove() throws {
        self.migrationLock.lock()
        defer { self.migrationLock.unlock() }
        let file = self.file
        // Record the decision first: even when the legacy Keychain delete fails
        // or is deferred, the marker keeps `load` from resurrecting that item.
        do {
            try file.markNoLegacyMigration()
            try file.remove()
        } catch { throw Failure.unavailable }
        let status = self.legacyItemDeleter()
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
