import Darwin
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A stalled Security.framework read cannot be cancelled. Keep at most one normal
/// read outstanding, bound its caller's wait, and discard any completion after timeout.
/// Renewal and writes deliberately use the synchronous item path under their CLI locks.
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
    let data: Data
    let reference: SecKeychainItem?
    let json: [String: Any]
    let oauth: [String: Any]
    let accessToken: String

    static func read(captureReference: Bool = false, reference: SecKeychainItem? = nil,
                     allowInteraction: Bool = false) throws -> Self {
        try ClaudeNativeKeychainInteraction.withPolicy(allowInteraction: allowInteraction) {
            try Self.readItem(captureReference: captureReference, reference: reference,
                              allowInteraction: allowInteraction)
        }
    }

    private static func readItem(captureReference: Bool, reference: SecKeychainItem?,
                                 allowInteraction: Bool = false) throws -> Self {
        var matchedReference = reference
        if captureReference {
            // Metadata lookup only. Never combine returning secret data and item references.
            var lookup = Self.query(allowInteraction: allowInteraction)
            lookup[kSecReturnRef as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            ClaudeNativeKeychainDiagnostics.begin(stage: "reference_lookup")
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            guard status == errSecSuccess else {
                ClaudeNativeKeychainDiagnostics.failure(stage: "reference_lookup", status: status)
                throw ClaudeCurrentUsageError.credentialRenewalUnavailable
            }
            guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
                ClaudeNativeKeychainDiagnostics.invalid(stage: "reference_type")
                throw ClaudeCurrentUsageError.credentialRenewalUnavailable
            }
            matchedReference = (result as! SecKeychainItem)
        }
        var query = Self.query(reference: matchedReference, allowInteraction: allowInteraction)
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
        return Self(data: data, reference: matchedReference, json: json, oauth: oauth, accessToken: token)
    }

    private static func query(reference: SecKeychainItem? = nil, allowInteraction: Bool = false) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecUseAuthenticationContext as String: context,
        ]
        if let reference { query[kSecMatchItemList as String] = [reference] }
        return query
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Call only while holding Claude's own storage-write lock. Update the captured item
    /// reference only; do not recreate, delete, or overwrite a newer sign-in.
    func updateIfUnchanged(_ updated: [String: Any]) throws {
        guard let reference = self.reference else { throw ClaudeCurrentUsageError.credentialRenewalUnavailable }
        try ClaudeNativeKeychainInteraction.withPolicy(allowInteraction: false) {
            let current = try Self.readItem(captureReference: false, reference: reference)
            guard current.data == self.data else { throw ClaudeCurrentUsageError.accountChanged }
            let bytes = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
            guard bytes.count <= 1_048_576 else { throw ClaudeCurrentUsageError.invalidResponse }
            let status = bytes.withUnsafeBytes { buffer in
                SecKeychainItemModifyAttributesAndData(reference, nil, UInt32(buffer.count), buffer.baseAddress)
            }
            guard status == errSecSuccess else {
                ClaudeNativeKeychainDiagnostics.failure(stage: "credential_update", status: status)
                throw ClaudeCurrentUsageError.credentialRenewalUnavailable
            }
            let after = try Self.readItem(captureReference: false, reference: reference)
            guard after.data == bytes else { throw ClaudeCurrentUsageError.accountChanged }
        }
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

enum ClaudeNativeCredentialRenewal {
    // Confirmed against the installed official Claude Code 2.1.260 OAuth constants.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func renew(rejectedToken: String, auth: ClaudeAuthInfo,
                      authAfter: @Sendable () throws -> ClaudeAuthInfo) async throws -> String {
        guard let identity = ClaudeUsageReader.accountFingerprint(auth),
              ClaudeUsageReader.accountFingerprint(try authAfter()) == identity else {
            throw ClaudeCurrentUsageError.accountChanged
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        // Claude's proper-lockfile uses mkdir, not flock. Respect both its current and legacy
        // OAuth lock paths. Recover only empty, owner-owned directories older than twice
        // the CLI's stale threshold, so a crash cannot permanently block idle refresh.
        let refreshLock = try ClaudeNativeDirectoryLock(directory.appendingPathComponent(".oauth_refresh.lock"))
        defer { refreshLock.release() }
        let legacyLock = try ClaudeNativeDirectoryLock(directory.resolvingSymlinksInPath().appendingPathExtension("lock"))
        defer { legacyLock.release() }
        let original = try ClaudeNativeCredentialItem.read(captureReference: true)
        if original.accessToken != rejectedToken { return original.accessToken }
        guard let refresh = original.oauth["refreshToken"] as? String,
              ClaudeNativeCredentialItem.validToken(refresh),
              let scopes = original.oauth["scopes"] as? [String], !scopes.isEmpty, scopes.count <= 32,
              scopes.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil }),
              original.oauth["clientId"] == nil || original.oauth["clientId"] is NSNull || original.oauth["clientId"] as? String == self.clientID else {
            throw ClaudeCurrentUsageError.credentialRenewalUnavailable
        }
        if let expiry = original.oauth["refreshTokenExpiresAt"] as? NSNumber,
           expiry.doubleValue > 0, expiry.doubleValue <= Date().timeIntervalSince1970 * 1000 {
            throw ClaudeCurrentUsageError.credentialRenewalFailed
        }
        let expired = (original.oauth["expiresAt"] as? NSNumber).map {
            $0.doubleValue <= Date().timeIntervalSince1970 * 1000
        } ?? false
        CoreLogger.info("Claude background credential renewal", metadata: ["stage": "begin", "credential_expired": String(expired)])
        do {
            var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": self.clientID, "scope": scopes.joined(separator: " "),
            ])
            let response = try await ClaudeHTTPSUsageTransport.perform(request)
            guard let fields = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let access = fields["access_token"] as? String, ClaudeNativeCredentialItem.validToken(access),
                  let duration = fields["expires_in"] as? NSNumber, CFGetTypeID(duration) != CFBooleanGetTypeID(),
                  duration.doubleValue.isFinite, duration.doubleValue > 0, duration.doubleValue <= 2_592_000 else {
                throw ClaudeCurrentUsageError.invalidResponse
            }
            let replacementRefresh: String
            if fields["refresh_token"] == nil { replacementRefresh = refresh }
            else if let value = fields["refresh_token"] as? String, ClaudeNativeCredentialItem.validToken(value) {
                replacementRefresh = value
            } else { throw ClaudeCurrentUsageError.invalidResponse }
            var replacementScopes = scopes
            if let value = fields["scope"] {
                guard let text = value as? String, text.count <= 4096 else { throw ClaudeCurrentUsageError.invalidResponse }
                replacementScopes = text.split(separator: " ").map(String.init)
                guard !replacementScopes.isEmpty, Set(replacementScopes).isSubset(of: Set(scopes)) else {
                    throw ClaudeCurrentUsageError.invalidResponse
                }
            }
            // Confirm the refreshed bearer still resolves to this CLI account before saving it.
            let profile = try await ClaudeHTTPSUsageTransport().get(path: "profile", accessToken: access)
            guard let linked = try? JSONSerialization.jsonObject(with: profile) as? [String: Any],
                  ClaudeCurrentUsageService.matches(linked, auth: auth),
                  ClaudeUsageReader.accountFingerprint(try authAfter()) == identity else {
                throw ClaudeCurrentUsageError.accountChanged
            }
            try refreshLock.verifyOwnership()
            try legacyLock.verifyOwnership()
            var oauth = original.oauth
            oauth["accessToken"] = access
            oauth["refreshToken"] = replacementRefresh
            oauth["expiresAt"] = (Date().timeIntervalSince1970 + duration.doubleValue) * 1000
            oauth["scopes"] = replacementScopes
            if let value = fields["refresh_token_expires_in"] {
                guard let seconds = value as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(),
                      seconds.doubleValue.isFinite, seconds.doubleValue > 0 else {
                    throw ClaudeCurrentUsageError.invalidResponse
                }
                oauth["refreshTokenExpiresAt"] = (Date().timeIntervalSince1970 + seconds.doubleValue) * 1000
            }
            var json = original.json
            json["claudeAiOauth"] = oauth
            // All native CLI storage mutations use this lock. Keep its critical section
            // synchronous and short, well below the CLI's 15-second stale threshold.
            let writeLock = try ClaudeNativeDirectoryLock(directory.appendingPathComponent(".storage-write.lock"), staleAfter: 30)
            defer { writeLock.release() }
            try original.updateIfUnchanged(json)
            CoreLogger.info("Claude background credential renewal", metadata: ["stage": "complete", "outcome": "same_account"])
            return access
        } catch {
            let safe = error as? ClaudeCurrentUsageError ?? .credentialRenewalFailed
            CoreLogger.warning("Claude background credential renewal", metadata: ["stage": "failed", "category": String(describing: safe)])
            switch safe {
            case .credentialRejected, .requestFailed: throw ClaudeCurrentUsageError.credentialRenewalFailed
            default: throw safe
            }
        }
    }
}

/// Compatible with Claude's proper-lockfile mkdir locks. Releasing checks inode ownership;
/// conservative stale recovery rechecks owner, inode, and mtime and only uses empty rmdir.
private final class ClaudeNativeDirectoryLock {
    private let url: URL
    private let inode: UInt64
    private let device: UInt64
    private var released = false

    init(_ url: URL, staleAfter: TimeInterval = 120) throws {
        self.url = url
        if Darwin.mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST, Self.recoverStale(url, staleAfter: staleAfter),
                  Darwin.mkdir(url.path, 0o700) == 0 else { throw ClaudeCurrentUsageError.refreshInProgress }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            _ = Darwin.rmdir(url.path)
            throw ClaudeCurrentUsageError.refreshInProgress
        }
        self.inode = UInt64(info.st_ino)
        self.device = UInt64(info.st_dev)
    }

    private static func recoverStale(_ url: URL, staleAfter: TimeInterval) -> Bool {
        var before = stat()
        guard lstat(url.path, &before) == 0, before.st_uid == getuid(),
              before.st_mode & S_IFMT == S_IFDIR else { return false }
        let modified = Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000
        guard Date().timeIntervalSince1970 - modified >= staleAfter else { return false }
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_uid == before.st_uid,
              after.st_ino == before.st_ino, after.st_dev == before.st_dev,
              after.st_mode & S_IFMT == S_IFDIR,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { return false }
        // rmdir refuses files, symlinks, and nonempty directories; never recurse or unlink.
        return Darwin.rmdir(url.path) == 0
    }

    func verifyOwnership() throws {
        var info = stat()
        guard !self.released, lstat(self.url.path, &info) == 0,
              UInt64(info.st_ino) == self.inode, UInt64(info.st_dev) == self.device,
              info.st_mode & S_IFMT == S_IFDIR else { throw ClaudeCurrentUsageError.refreshInProgress }
    }

    func release() {
        guard (try? self.verifyOwnership()) != nil else { return }
        self.released = true
        _ = Darwin.rmdir(self.url.path)
    }
}
