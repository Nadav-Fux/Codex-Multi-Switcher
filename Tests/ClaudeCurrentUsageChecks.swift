import CodexProfileCore
import Foundation

enum ClaudeCurrentUsageChecks {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    final class FakeLoader: ClaudeUsageCredentialLoading, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var replacement: String?
        let rotate: Bool
        init(rotate: Bool = false) { self.rotate = rotate }
        func accessToken() throws -> String {
            self.lock.lock(); defer { self.lock.unlock() }
            self.calls += 1
            return self.replacement ?? (self.rotate && self.calls > 1 ? "fake-rotated-token" : "fake-access-secret-never-cache")
        }
        func replaceToken() { self.lock.lock(); defer { self.lock.unlock() }; self.replacement = "fake-new-account-token" }
    }
    final class FakeTransport: ClaudeUsageTransport, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        let mismatch: Bool
        let fail: Bool
        let invalid: Bool
        let rejected: Bool
        init(mismatch: Bool = false, fail: Bool = false, invalid: Bool = false, rejected: Bool = false) {
            self.mismatch = mismatch; self.fail = fail; self.invalid = invalid
            self.rejected = rejected
        }
        func get(path: String, accessToken: String) async throws -> Data {
            self.record()
            try check(accessToken.hasPrefix("fake-"), "Only fake credentials reach fake transport")
            if self.fail { throw ClaudeCurrentUsageError.requestFailed }
            if self.rejected { throw ClaudeCurrentUsageError.credentialRejected }
            if path == "profile" {
                return try JSONSerialization.data(withJSONObject: [
                    "account": ["uuid": "acct-fixture", "email": self.mismatch ? "other@example.test" : "fixture@example.test"],
                    "organization": ["uuid": "org-fixture"]])
            }
            let invalidUsage: [String: Any] = ["five_hour": ["utilization": true], "seven_day": ["utilization": 101]]
            let validUsage: [String: Any] = [
                "five_hour": ["utilization": 21.5, "resets_at": "2027-01-01T12:00:00.000Z"],
                "seven_day": ["utilization": 43, "resets_at": "2027-01-03T12:00:00Z"],
                "seven_day_sonnet": NSNull(), "unknown_secret": "fake-access-secret-never-cache"]
            return try JSONSerialization.data(withJSONObject: self.invalid ? invalidUsage : validUsage)
        }
        private func record() { self.lock.lock(); defer { self.lock.unlock() }; self.calls += 1 }
    }

    @MainActor
    static func run(root: URL, home: URL, environment: [String: String], bridge: URL) async throws {
        let profile = ClaudeProfile(id: ClaudeProfileRegistry.defaultID, label: "Fixture",
                                    configDirectory: home.appendingPathComponent(".claude").path, isDefault: true)
        let auth = ClaudeAuthInfo(loggedIn: true, email: "fixture@example.test", organizationID: "org-fixture")
        let fixed = Date()
        func service(_ suffix: String, _ loader: FakeLoader = FakeLoader(), _ transport: FakeTransport = FakeTransport()) -> ClaudeCurrentUsageService {
            ClaudeCurrentUsageService(root: root.appendingPathComponent(suffix), nativeHome: home,
                                      credentialLoader: loader, transport: transport)
        }
        let loader = FakeLoader(), transport = FakeTransport()
        let current = service("oauth-success", loader, transport)
        let observation = try await current.fetch(profile: profile, authBefore: auth, authAfter: { auth }, now: fixed)
        try check(observation.source == .oauthUsage && observation.accountMatched && !observation.isStale,
                  "Fresh response binds API account to CLI")
        try check(observation.fiveHour?.usedPercentage == 21.5 && observation.sevenDay?.resetsAt != nil
                  && observation.modelWeekly == nil, "Fractional/ordinary dates and null optional window")
        let cache = root.appendingPathComponent("oauth-success/usage-observations/claude-default.json")
        let bytes = try Data(contentsOf: cache)
        try check(!String(decoding: bytes, as: UTF8.self).contains("fake-access-secret"), "Cache contains no credentials or extra server fields")
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
        try check(permissions.intValue & 0o777 == 0o600, "Observation cache created privately")
        _ = try await current.fetch(profile: profile, authBefore: auth, authAfter: { auth }, now: fixed.addingTimeInterval(20))
        try check(transport.calls == 2 && loader.calls == 4, "Fresh cache verifies credential before/after CLI without repeated network reads")
        try check(current.cached(profile: profile, auth: auth, now: fixed.addingTimeInterval(61))?.isStale == true,
                  "Cache becomes historical after60 seconds")
        let other = ClaudeAuthInfo(loggedIn: true, email: "other@example.test", organizationID: "org-fixture")
        try check(current.cached(profile: profile, auth: other) == nil, "No cache reuse for another account")
        do {
            _ = try await current.fetch(profile: profile, authBefore: auth, authAfter: { other }, now: fixed.addingTimeInterval(30))
            throw Failure(message: "Fresh cache must reject a changed CLI account")
        } catch is ClaudeCurrentUsageError {}
        do {
            _ = try await current.fetch(profile: profile, authBefore: auth, authAfter: {
                loader.replaceToken()
                return auth
            }, now: fixed.addingTimeInterval(30))
            throw Failure(message: "Fresh cache must reject token rotation during the final CLI check")
        } catch is ClaudeCurrentUsageError {}
        try check(current.cached(profile: profile, auth: auth, now: fixed.addingTimeInterval(30)) == nil,
                  "A rotated native token invalidates fresh cache despite unchanged CLI metadata")

        for (name, attempted, after) in [
            ("server-account", service("server-account", FakeLoader(), FakeTransport(mismatch: true)), auth),
            ("token-rotation", service("token-rotation", FakeLoader(rotate: true)), auth),
            ("cli-account", service("cli-account"), other),
            ("invalid-windows", service("invalid-windows", FakeLoader(), FakeTransport(invalid: true)), auth)] {
            do { _ = try await attempted.fetch(profile: profile, authBefore: auth, authAfter: { after }, now: fixed)
                throw Failure(message: name + " must fail")
            } catch is ClaudeCurrentUsageError {}
            try check(attempted.cached(profile: profile, auth: auth) == nil, name + " never publishes/caches mismatched data")
        }
        let blockedLoader = FakeLoader(), blockedTransport = FakeTransport()
        let blocked = service("isolated-block", blockedLoader, blockedTransport)
        let managed = ClaudeProfile(id: UUID().uuidString, label: "Managed", configDirectory: profile.configDirectory)
        let preview = ClaudeProfile(id: profile.id, label: "Preview", configDirectory: root.appendingPathComponent("preview/.claude").path, isDefault: true)
        for isolated in [managed, preview] {
            do { _ = try await blocked.fetch(profile: isolated, authBefore: auth, authAfter: { auth })
                throw Failure(message: "Isolated profile must fail before credential read")
            } catch is ClaudeCurrentUsageError {}
        }
        try check(blockedLoader.calls == 0 && blockedTransport.calls == 0, "Managed and preview do not borrow native credentials")
        let productionEligibility = ClaudeCurrentUsageService(root: root.appendingPathComponent("real-loader-never-called"))
        try check(!productionEligibility.supports(profile), "Production loader excludes fake homes before any Keychain access")
        let failureTransport = FakeTransport(fail: true)
        let backedOff = service("backoff", FakeLoader(), failureTransport)
        for delta in [0.0, 1.0, 299.0, 301.0] {
            do { _ = try await backedOff.fetch(profile: profile, authBefore: auth, authAfter: { auth }, now: fixed.addingTimeInterval(delta))
                throw Failure(message: "Fake failure must fail")
            } catch is ClaudeCurrentUsageError {}
        }
        try check(failureTransport.calls == 2, "Failure backoff avoids minute polling for300seconds")
        let rejectedTransport = FakeTransport(rejected: true)
        let rejected = service("rejected-backoff", FakeLoader(), rejectedTransport)
        for delta in [0.0, 60.0] {
            do { _ = try await rejected.fetch(profile: profile, authBefore: auth, authAfter: { auth }, now: fixed.addingTimeInterval(delta))
                throw Failure(message: "Rejected token must fail")
            } catch ClaudeCurrentUsageError.credentialRejected {}
        }
        try check(rejectedTransport.calls == 1, "Backoff preserves actionable rejected-token error without another request")

        // Store integration uses fake CLI+Keychain+HTTPS dependencies only.
        let integrated = service("store-api")
        let nativeURL = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(ClaudeUsageReader.nativeSnapshotName)
        let originalNative = try? Data(contentsOf: nativeURL)
        defer {
            if let originalNative { try? AtomicFileWriter.write(originalNative, to: nativeURL) }
            else { try? FileManager.default.removeItem(at: nativeURL) }
        }
        try? FileManager.default.removeItem(at: nativeURL)
        let store = ClaudeProfileStore(environment: environment, bridgeURL: bridge, currentUsageService: integrated)
        store.refresh()
        let deadline = Date().addingTimeInterval(10)
        while store.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(store.statuses[profile.id]?.usage?.source == .oauthUsage, "Store publishes current account usage automatically")
        let mismatchedStore = ClaudeProfileStore(environment: environment, bridgeURL: bridge,
            currentUsageService: service("store-mismatch", FakeLoader(), FakeTransport(mismatch: true)))
        mismatchedStore.refresh()
        let mismatchDeadline = Date().addingTimeInterval(10)
        while mismatchedStore.isRefreshing && Date() < mismatchDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(mismatchedStore.statuses[profile.id]?.usage == nil && mismatchedStore.statuses[profile.id]?.error != nil,
                  "Identity failure clears usage instead of republishing the pre-request observation")
        let native: [String: Any] = ["schemaVersion": 1, "profileID": profile.id, "configDirectory": profile.configDirectory,
                                   "authIdentityDigest": ClaudeUsageReader.accountFingerprint(auth)!,
                                   "fetchedAt": ISO8601DateFormatter().string(from: Date()),
                                   "fiveHour": ["usedPercent": 7], "sevenDay": NSNull()]
        try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: native), to: nativeURL)
        let untouchedLoader = FakeLoader(), untouchedTransport = FakeTransport()
        let nativeFirst = ClaudeProfileStore(environment: environment, bridgeURL: bridge,
            currentUsageService: service("store-native-priority", untouchedLoader, untouchedTransport))
        nativeFirst.refresh()
        let nativeDeadline = Date().addingTimeInterval(10)
        while nativeFirst.isRefreshing && Date() < nativeDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(nativeFirst.statuses[profile.id]?.usage?.source == .nativeBridge && untouchedLoader.calls == 0,
                  "Fresh matched native snapshot preserves bridge priority without a credential read")
        print("Claude current usage checks passed (fake credentials/HTTPS, identity races, private cache, backoff, isolation, store priority).")
    }
}
