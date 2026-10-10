import CryptoKit
import Foundation
import Security

public enum ClaudeCurrentUsageError: String, Codable, LocalizedError {
    case unsupportedProfile, credentialUnavailable, credentialInteractionRequired, credentialRejected, accessDenied, credentialRenewalUnavailable, credentialRenewalFailed, refreshInProgress, rateLimited, accountChanged, invalidResponse, requestFailed
    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile: return "Automatic usage is available for the existing native Claude account. Isolated accounts can use their native usage bridge."
        case .credentialUnavailable: return "Claude credentials are unavailable to this app. Check the Claude sign-in and macOS Keychain access for Codex Multi Switcher, then refresh."
        case .credentialInteractionRequired: return "Connect Claude in Settings to authorize its usage helper. Background access is paused until a silent read succeeds."
        case .credentialRejected: return "Current Claude usage is unavailable for this sign-in. Usage can appear when the account becomes available; the statusline bridge is also supported."
        case .accessDenied: return "Claude denied quota access for this sign-in. Check this account in Claude Code."
        case .credentialRenewalUnavailable: return "Claude could not renew this sign-in without a Keychain prompt. Open Claude Code to renew it, then refresh."
        case .credentialRenewalFailed: return "Claude sign-in renewal failed. Refresh again in a few minutes; sign in through Claude Code if it continues."
        case .refreshInProgress: return "Another Claude process is updating sign-in. Usage will refresh automatically."
        case .rateLimited: return "Claude temporarily limited quota requests. Usage will refresh automatically."
        case .accountChanged: return "Claude account identity could not be confirmed. Refresh after signing in."
        case .invalidResponse: return "Claude returned an unsupported usage response."
        case .requestFailed: return "Current Claude usage could not be fetched. Try refreshing again in a few minutes."
        }
    }
}

public protocol ClaudeUsageCredentialLoading: Sendable {
    func accessToken() throws -> String
    func renewAccessToken(rejectedToken: String, auth: ClaudeAuthInfo,
                          authAfter: @Sendable () throws -> ClaudeAuthInfo) async throws -> String
}

public extension ClaudeUsageCredentialLoading {
    func renewAccessToken(rejectedToken: String, auth: ClaudeAuthInfo,
                          authAfter: @Sendable () throws -> ClaudeAuthInfo) async throws -> String {
        throw ClaudeCurrentUsageError.credentialRejected
    }
}

/// Reads exactly Claude's native item. Renewal updates only that existing item, without prompts.
public struct ClaudeNativeCredentialLoader: ClaudeUsageCredentialLoading {
    public init() {}
    public func accessToken() throws -> String {
        try ClaudeNativeCredentialAuthorization.requireBackgroundAccess()
        return try ClaudeNativeCredentialReadWorker.shared.accessToken()
    }

    /// Call only after the user explicitly chooses to connect the native account.
    public func authorizeAccess() throws {
        try ClaudeNativeCredentialAuthorization.authorize()
    }

    public func renewAccessToken(rejectedToken: String, auth: ClaudeAuthInfo,
                                 authAfter: @Sendable () throws -> ClaudeAuthInfo) async throws -> String {
        try await ClaudeNativeCredentialRenewal.renew(rejectedToken: rejectedToken, auth: auth, authAfter: authAfter)
    }
}

public protocol ClaudeUsageTransport: Sendable {
    func get(path: String, accessToken: String) async throws -> Data
}

public struct ClaudeHTTPSUsageTransport: ClaudeUsageTransport {
    public init() {}
    public func get(path: String, accessToken: String) async throws -> Data {
        guard ["usage", "profile"].contains(path),
              let url = URL(string: "https://api.anthropic.com/api/oauth/" + path) else {
            throw ClaudeCurrentUsageError.requestFailed
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Codex-Multi-Switcher/0.2.2", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return try await Self.perform(request)
    }

    static func perform(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = BoundedClaudeResponse(continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.urlCredentialStorage = nil
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.dataTask(with: request).resume()
        }
    }
}

/// Session callbacks are serial. A redirect is never followed with the bearer token.
private final class BoundedClaudeResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var session: URLSession?
    private var bytes = Data()
    private var valid = false
    private var failure = ClaudeCurrentUsageError.requestFailed
    private var continuation: CheckedContinuation<Data, Error>?
    init(continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { self.failure = .credentialRejected }
        if status == 403 { self.failure = .accessDenied }
        if status == 429 { self.failure = .rateLimited }
        self.valid = status == 200
            && response.expectedContentLength <= 1_048_576
        completionHandler(self.valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.bytes.count + data.count <= 1_048_576 else {
            self.valid = false
            dataTask.cancel()
            return
        }
        self.bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if error == nil && self.valid { continuation.resume(returning: self.bytes) }
        else { continuation.resume(throwing: self.failure) }
        self.bytes.removeAll()
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

public final class ClaudeCurrentUsageService: @unchecked Sendable {
    private let helper: ClaudeUsageHelperClient?
    private let loader: any ClaudeUsageCredentialLoading
    private let transport: any ClaudeUsageTransport
    private let nativeHome: URL
    private let cacheRoot: URL
    private let attemptLock = NSLock()
    private var retryAfter = Date.distantPast
    private var lastFailure = ClaudeCurrentUsageError.requestFailed
    private var attemptIdentity: String?
    // Keep a successful sample usable across the minute polling boundary.
    public static let cacheFreshness: TimeInterval = 120

    public init(root: URL, nativeHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                credentialLoader: any ClaudeUsageCredentialLoading = ClaudeNativeCredentialLoader(),
                transport: any ClaudeUsageTransport = ClaudeHTTPSUsageTransport(),
                helper: ClaudeUsageHelperClient? = nil) {
        self.helper = helper
        self.cacheRoot = root.appendingPathComponent("usage-observations", isDirectory: true)
        self.nativeHome = nativeHome.standardizedFileURL
        self.loader = credentialLoader
        self.transport = transport
    }

    public func supports(_ profile: ClaudeProfile) -> Bool {
        profile.isDefault && profile.id == ClaudeProfileRegistry.defaultID
            && URL(fileURLWithPath: profile.configDirectory).standardizedFileURL
                == self.nativeHome.appendingPathComponent(".claude").standardizedFileURL
    }

    /// Foreground consent for the existing native item; no network request or
    /// credential write occurs until the following ordinary usage refresh.
    public func authorizeNativeCredentialAccess(profile: ClaudeProfile) throws {
        if let helper {
            guard self.supports(profile) else { throw ClaudeCurrentUsageError.unsupportedProfile }
            try helper.authorize()
            self.finishAttempt()
            return
        }
        guard self.supports(profile), let native = self.loader as? ClaudeNativeCredentialLoader else {
            throw ClaudeCurrentUsageError.unsupportedProfile
        }
        try native.authorizeAccess()
        self.finishAttempt()
    }

    /// Only observations bound to the same current CLI identity are reusable.
    public func cached(profile: ClaudeProfile, auth: ClaudeAuthInfo?, now: Date = Date()) -> ClaudeUsageSnapshot? {
        if let helper {
            guard self.supports(profile), let identity = ClaudeUsageReader.accountFingerprint(auth) else { return nil }
            return helper.cached(identity: identity, now: now)
        }
        guard self.supports(profile), let identity = ClaudeUsageReader.accountFingerprint(auth),
              let values = try? self.cacheURL(profile).resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: self.cacheURL(profile)), data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1,
              json["profileID"] as? String == profile.id,
              json["configDirectory"] as? String == profile.configDirectory,
              json["authIdentityDigest"] as? String == identity,
              let timestamp = json["fetchedAt"] as? Double,
              timestamp.isFinite, timestamp <= now.timeIntervalSince1970 + 60,
              let usage = json["usage"] as? [String: Any],
              let credentialDigest = json["credentialDigest"] as? String,
              let currentToken = try? self.loader.accessToken(),
              Self.credentialDigest(currentToken) == credentialDigest else { return nil }
        return try? Self.parseUsage(usage, observedAt: Date(timeIntervalSince1970: timestamp), now: now)
    }

    public func fetch(profile: ClaudeProfile, authBefore: ClaudeAuthInfo,
                      authAfter: @Sendable () throws -> ClaudeAuthInfo,
                      now: Date = Date()) async throws -> ClaudeUsageSnapshot {
        guard self.supports(profile) else { throw ClaudeCurrentUsageError.unsupportedProfile }
        if let helper {
            guard let identity = ClaudeUsageReader.accountFingerprint(authBefore) else { throw ClaudeCurrentUsageError.accountChanged }
            try self.beginAttempt(now: now, identity: identity)
            do {
                let snapshot = try await Task.detached(priority: .utility) { try helper.read(identity: identity) }.value
                guard ClaudeUsageReader.accountFingerprint(try authAfter()) == identity else {
                    throw ClaudeCurrentUsageError.accountChanged
                }
                self.finishAttempt()
                return snapshot
            } catch {
                let safe = error as? ClaudeCurrentUsageError ?? .requestFailed
                self.recordFailure(safe)
                throw safe
            }
        }
        if let cached = self.cached(profile: profile, auth: authBefore, now: now),
           !cached.isStale, now.timeIntervalSince(cached.observedAt) < 60 {
            let after = try authAfter()
            guard ClaudeUsageReader.accountFingerprint(after) == ClaudeUsageReader.accountFingerprint(authBefore),
                  self.cached(profile: profile, auth: after, now: now) != nil else {
                throw ClaudeCurrentUsageError.accountChanged
            }
            return cached
        }
        guard let identity = ClaudeUsageReader.accountFingerprint(authBefore) else {
            throw ClaudeCurrentUsageError.accountChanged
        }
        let token = try self.loader.accessToken()
        try self.beginAttempt(now: now, identity: identity + Self.credentialDigest(token))
        do {
            let result: ClaudeUsageSnapshot
            do {
                result = try await self.fetchUncached(profile: profile, authBefore: authBefore,
                    authAfter: authAfter, token: token, now: now)
            } catch ClaudeCurrentUsageError.credentialRejected {
                let renewed = try await self.loader.renewAccessToken(rejectedToken: token, auth: authBefore, authAfter: authAfter)
                result = try await self.fetchUncached(profile: profile, authBefore: authBefore,
                    authAfter: authAfter, token: renewed, now: Date())
            }
            self.finishAttempt()
            return result
        } catch {
            let safe = error as? ClaudeCurrentUsageError ?? .requestFailed
            self.recordFailure(safe)
            throw safe
        }
    }

    private func beginAttempt(now: Date, identity: String) throws {
        self.attemptLock.lock()
        defer { self.attemptLock.unlock() }
        guard identity != self.attemptIdentity || now >= self.retryAfter else { throw self.lastFailure }
        self.attemptIdentity = identity
        // Errors retain this backoff, including HTTP429. Success clears it.
        self.retryAfter = now.addingTimeInterval(300)
        self.lastFailure = .requestFailed
    }

    private func recordFailure(_ failure: ClaudeCurrentUsageError) {
        self.attemptLock.lock()
        defer { self.attemptLock.unlock() }
        self.lastFailure = failure
        if case .refreshInProgress = failure {
            self.retryAfter = min(self.retryAfter, Date().addingTimeInterval(30))
        }
    }

    private func finishAttempt() {
        self.attemptLock.lock()
        defer { self.attemptLock.unlock() }
        self.retryAfter = .distantPast
    }

    private func fetchUncached(profile: ClaudeProfile, authBefore: ClaudeAuthInfo,
                               authAfter: @Sendable () throws -> ClaudeAuthInfo,
                               token: String, now: Date) async throws -> ClaudeUsageSnapshot {
        guard let identity = ClaudeUsageReader.accountFingerprint(authBefore) else {
            throw ClaudeCurrentUsageError.accountChanged
        }
        let profileData = try await self.transport.get(path: "profile", accessToken: token)
        guard let linked = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              Self.matches(linked, auth: authBefore) else { throw ClaudeCurrentUsageError.accountChanged }
        let usageData = try await self.transport.get(path: "usage", accessToken: token)
        guard usageData.count <= 1_048_576,
              let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            throw ClaudeCurrentUsageError.invalidResponse
        }
        let snapshot = try Self.parseUsage(usage, observedAt: now, now: now)
        let after = try authAfter()
        guard ClaudeUsageReader.accountFingerprint(after) == identity,
              Self.matches(linked, auth: after),
              SHA256.hash(data: Data(try self.loader.accessToken().utf8)) == SHA256.hash(data: Data(token.utf8)) else {
            throw ClaudeCurrentUsageError.accountChanged
        }
        // Serialize only numeric observations and identity digest, never the raw HTTP response/token.
        var normalized: [String: Any] = [:]
        for (key, window) in [("five_hour", snapshot.fiveHour), ("seven_day", snapshot.sevenDay),
                              ("seven_day_sonnet", snapshot.modelWeekly)] {
            if let window {
                var value: [String: Any] = ["utilization": window.usedPercentage]
                if let reset = window.resetsAt { value["resets_at"] = ISO8601DateFormatter().string(from: reset) }
                normalized[key] = value
            }
        }
        let payload: [String: Any] = ["schemaVersion": 1, "profileID": profile.id,
                                     "configDirectory": profile.configDirectory,
                                     "authIdentityDigest": identity, "fetchedAt": now.timeIntervalSince1970,
                                     "credentialDigest": Self.credentialDigest(token),
                                     "usage": normalized]
        try AtomicFileWriter.ensurePrivateDirectory(self.cacheRoot)
        try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                                   to: self.cacheURL(profile))
        return snapshot
    }

    private func cacheURL(_ profile: ClaudeProfile) -> URL {
        // Only the constant default ID is supported, preventing path traversal from registry data.
        self.cacheRoot.appendingPathComponent("claude-default.json")
    }

    private static func credentialDigest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ linked: [String: Any], auth: ClaudeAuthInfo) -> Bool {
        guard auth.loggedIn == true || auth.authenticationMethod == "account_metadata",
              let account = linked["account"] as? [String: Any],
              let uuid = account["uuid"] as? String, !uuid.isEmpty,
              let email = account["email"] as? String, !email.isEmpty,
              let organization = linked["organization"] as? [String: Any],
              let orgID = organization["uuid"] as? String, !orgID.isEmpty,
              auth.accountID != nil || auth.email != nil else { return false }
        if let expected = auth.accountID, expected != uuid { return false }
        if let expected = auth.email, expected.caseInsensitiveCompare(email) != .orderedSame { return false }
        if let expected = auth.organizationID, expected != orgID { return false }
        return true
    }

    private static func parseUsage(_ usage: [String: Any], observedAt: Date, now: Date) throws -> ClaudeUsageSnapshot {
        func window(_ key: String) -> ClaudeUsageWindow? {
            guard let fields = usage[key] as? [String: Any], let used = fields["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                  (0...100).contains(used.doubleValue) else { return nil }
            var reset: Date?
            if let text = fields["resets_at"] as? String {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            return ClaudeUsageWindow(usedPercentage: used.doubleValue, resetsAt: reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { throw ClaudeCurrentUsageError.invalidResponse }
        return ClaudeUsageSnapshot(fiveHour: five, sevenDay: seven, modelWeekly: window("seven_day_sonnet"),
                                   observedAt: observedAt, source: .oauthUsage,
                                   isStale: now.timeIntervalSince(observedAt) > Self.cacheFreshness, accountVerified: true)
    }
}
