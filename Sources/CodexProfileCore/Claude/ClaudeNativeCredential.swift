import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A stalled Security.framework read cannot be cancelled. Keep at most one normal
/// read outstanding, bound its caller's wait, and discard any completion after timeout.
/// The native credential is read-only; Claude Code owns renewal and persistence.
final class ClaudeNativeCredentialReadWorker: @unchecked Sendable {
    static let shared = ClaudeNativeCredentialReadWorker()
    private let queue = DispatchQueue(label: "com.codexmultiswitcher.claude-credential-read", qos: .utility)
    private let lock = NSLock()
    private var inFlight: Completion?

    func accessToken() throws -> String {
        self.lock.lock()
        guard self.inFlight == nil else {
            self.lock.unlock()
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        let operation = Completion(timeout: 5)
        self.inFlight = operation
        self.lock.unlock()
        self.queue.async {
            let result: Result<String, ClaudeCurrentUsageError>
            do { result = .success(try ClaudeNativeCredentialItem.read().accessToken) }
            catch { result = .failure(error as? ClaudeCurrentUsageError ?? .credentialUnavailable) }
            self.lock.lock()
            if self.inFlight === operation { self.inFlight = nil }
            self.lock.unlock()
            operation.complete(result)
        }
        guard let result = operation.wait() else {
            CoreLogger.warning("Claude background credential read timed out", metadata: ["category": "keychain_timeout"])
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        return try result.get()
    }

    private final class Completion: @unchecked Sendable {
        private let condition = NSCondition()
        private let deadline: Date
        private var result: Result<String, ClaudeCurrentUsageError>?
        private var expired = false

        init(timeout: TimeInterval) { self.deadline = Date().addingTimeInterval(timeout) }

        func complete(_ result: Result<String, ClaudeCurrentUsageError>) {
            self.condition.lock()
            defer { self.condition.unlock() }
            if !self.expired, Date() <= self.deadline { self.result = result }
            else { self.expired = true }
            self.condition.broadcast()
        }

        func wait() -> Result<String, ClaudeCurrentUsageError>? {
            self.condition.lock()
            defer { self.condition.unlock() }
            while self.result == nil && !self.expired {
                if !self.condition.wait(until: self.deadline) { self.expired = true }
            }
            if self.expired { self.result = nil; return nil }
            let result = self.result
            self.result = nil
            return result
        }
    }
}

/// The sole native Claude item; neither enumeration nor a plaintext fallback is used.
struct ClaudeNativeCredentialItem {
    let accessToken: String

    static func read(allowInteraction: Bool = false) throws -> Self {
        try ClaudeNativeKeychainInteraction.withPolicy(allowInteraction: allowInteraction) {
            try Self.readItem(allowInteraction: allowInteraction)
        }
    }

    private static func readItem(allowInteraction: Bool) throws -> Self {
        var query = Self.query(allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        ClaudeNativeKeychainDiagnostics.begin(stage: "data_lookup")
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            ClaudeNativeKeychainDiagnostics.failure(stage: "data_lookup", status: status)
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                throw ClaudeCurrentUsageError.credentialInteractionRequired
            }
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        guard let data = result as? Data, data.count <= 1_048_576 else {
            ClaudeNativeKeychainDiagnostics.invalid(stage: "data_type_or_size")
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ClaudeNativeKeychainDiagnostics.invalid(stage: "credential_json")
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        guard let oauth = json["claudeAiOauth"] as? [String: Any] else {
            ClaudeNativeKeychainDiagnostics.invalid(stage: "oauth_object")
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        guard let token = oauth["accessToken"] as? String, validToken(token) else {
            ClaudeNativeKeychainDiagnostics.invalid(stage: "access_token_shape")
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        return Self(accessToken: token)
    }

    private static func query(allowInteraction: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecUseAuthenticationContext as String: context,
        ]
        return query
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// Legacy macOS Keychain authorization can ignore the modern LAContext policy.
/// Suppress optional interaction only for each synchronous operation, then restore it.
private enum ClaudeNativeKeychainInteraction {
    static func withPolicy<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        do {
            return try KeychainInteractionPolicy.withInteraction(allowed: allowInteraction, operation)
        } catch is KeychainInteractionPolicy.Failure {
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
    }
}

/// Remembers the user's explicit connection intent. macOS still enforces access
/// to the exact Keychain item for every silent read; a build hash is not an ACL.
enum ClaudeNativeCredentialAuthorization {
    private static let preferenceKey = "claudeNativeCredentialAuthorizedExecutableSHA256"
    // CLI helpers need an explicit persistent domain shared by separate invocations.
    private static var preferences: UserDefaults {
        if Bundle.main.executableURL?.lastPathComponent == "claude-usage-helper" {
            return UserDefaults(suiteName: "com.codexmultiswitcher.claude-usage-helper") ?? .standard
        }
        return .standard
    }
    private static let executableDigest: String? = {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0, size <= 268_435_456,
              let bytes = try? Data(contentsOf: executable, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }()

    static func requireBackgroundAccess() throws {
        guard self.preferences.string(forKey: self.preferenceKey)?.isEmpty == false else {
            throw ClaudeCurrentUsageError.credentialInteractionRequired
        }
    }

    static func authorize() throws {
        guard let digest = self.executableDigest else { throw ClaudeCurrentUsageError.credentialUnavailable }
        // Read only the existing native Claude item. macOS controls any grant;
        // no ACL, access group, item, or sign-in is created or altered here.
        _ = try ClaudeNativeCredentialItem.read(allowInteraction: true)
        _ = try ClaudeNativeCredentialItem.read(allowInteraction: false)
        self.preferences.set(digest, forKey: self.preferenceKey)
        self.preferences.synchronize()
    }
}

/// Diagnostics contain only fixed operation names and Security.framework status codes.
/// Never pass query dictionaries, Keychain result objects, or credential JSON here.
private enum ClaudeNativeKeychainDiagnostics {
    static func begin(stage: String) {
        CoreLogger.info("Claude native Keychain operation", metadata: ["stage": stage])
    }

    static func failure(stage: String, status: OSStatus) {
        CoreLogger.warning("Claude native Keychain operation failed", metadata: [
            "stage": stage, "osstatus": String(status),
        ])
    }

    static func invalid(stage: String) {
        CoreLogger.warning("Claude native credential format unsupported", metadata: ["stage": stage])
    }
}
