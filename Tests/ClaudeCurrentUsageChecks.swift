import CodexProfileCore
import Foundation

enum ClaudeCurrentUsageChecks {
    struct Failure: Error { let message: String }
    actor PollCalls {
        var count = 0
        func record() { self.count += 1 }
    }
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
        // A rejected token must never send the native loader down an OAuth,
        // Keychain, or CLI lock path. Only the official Claude client renews it.
        // This entry point rejects before touching any real credential store.
        do {
            _ = try await ClaudeNativeCredentialLoader().renewAccessToken(
                rejectedToken: "fake-rejected-token", auth: auth, authAfter: {
                    throw Failure(message: "Native renewal must not inspect or mutate sign-in")
                })
            throw Failure(message: "Native Claude credential must remain read-only")
        } catch ClaudeCurrentUsageError.credentialRenewalUnavailable {}
        let fixed = Date()
        let policyRoot = root.appendingPathComponent("persistent-polling")
        let rateCalls = PollCalls()
        let lastKnown = ClaudeUsageSnapshot(fiveHour: ClaudeUsageWindow(usedPercentage: 22),
            sevenDay: ClaudeUsageWindow(usedPercentage: 32), observedAt: fixed,
            source: .oauthUsage, isStale: false, accountVerified: true)
        let ratePolicy = ClaudeQuotaRefreshPolicy(root: policyRoot)
        let first429 = await ratePolicy.read(identity: "account-a", seed: lastKnown, now: fixed) {
            await rateCalls.record(); throw ClaudeCurrentUsageError.rateLimited
        }
        try check(first429.failure == .rateLimited && first429.snapshot?.isStale == true
            && first429.nextRefreshAt.timeIntervalSince(fixed) == 600,
            "429 keeps historical quota and starts a ten-minute wait")
        let restartedPolicy = ClaudeQuotaRefreshPolicy(root: policyRoot)
        let beforeRetry = await restartedPolicy.read(identity: "account-a", now: fixed.addingTimeInterval(60)) {
            await rateCalls.record(); return lastKnown
        }
        try check(await rateCalls.count == 1 && beforeRetry.failure == .rateLimited,
            "Restarting or clicking Refresh cannot bypass a persisted rate-limit wait")
        let second429 = await restartedPolicy.read(identity: "account-a", now: fixed.addingTimeInterval(601)) {
            await rateCalls.record(); throw ClaudeCurrentUsageError.rateLimited
        }
        try check(await rateCalls.count == 2 && second429.nextRefreshAt.timeIntervalSince(fixed) == 1801,
            "A repeated 429 doubles the next wait")
        let anotherAccount = await restartedPolicy.read(identity: "account-b", now: fixed.addingTimeInterval(602)) {
            throw ClaudeCurrentUsageError.credentialRejected
        }
        try check(anotherAccount.snapshot == nil, "Historical quota cannot leak to another account")
        let normalRoot = root.appendingPathComponent("normal-polling")
        let normalCalls = PollCalls()
        let normalPolicy = ClaudeQuotaRefreshPolicy(root: normalRoot)
        _ = await normalPolicy.read(identity: "account-a", now: fixed) {
            await normalCalls.record(); return lastKnown
        }
        let normalRestarted = ClaudeQuotaRefreshPolicy(root: normalRoot)
        _ = await normalRestarted.read(identity: "account-a", now: fixed.addingTimeInterval(240)) {
            await normalCalls.record(); return lastKnown
        }
        try check(await normalCalls.count == 1, "Normal API polling is at most once in five minutes across relaunches")
        let sharedRoot = root.appendingPathComponent("shared-polling")
        let sharedA = ClaudeQuotaRefreshPolicy(root: sharedRoot), sharedB = ClaudeQuotaRefreshPolicy(root: sharedRoot)
        let sharedCalls = PollCalls()
        async let firstShared = sharedA.read(identity: "account-a", now: fixed) {
            await sharedCalls.record(); try await Task.sleep(nanoseconds: 50_000_000); return lastKnown
        }
        async let secondShared = sharedB.read(identity: "account-a", now: fixed) {
            await sharedCalls.record(); try await Task.sleep(nanoseconds: 50_000_000); return lastKnown
        }
        _ = await (firstShared, secondShared)
        try check(await sharedCalls.count == 1, "Two app instances share one persisted request reservation")
        let historicalURL = root.appendingPathComponent("historical-helper-observation.json")
        let historical: [String: Any] = ["schemaVersion": 1, "profileID": profile.id,
            "configDirectory": profile.configDirectory, "authIdentityDigest": "account-a",
            "fetchedAt": fixed.timeIntervalSince1970, "usage": ["seven_day": ["utilization": 32]]]
        try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: historical), to: historicalURL)
        let imported = ClaudeQuotaRefreshPolicy.priorObservation(at: historicalURL, profile: profile, identity: "account-a", now: fixed)
        try check(imported?.isStale == true && imported?.sevenDay?.usedPercentage == 32,
            "Private prior observations survive app restarts only as explicitly historical quota")
        try check(ClaudeQuotaRefreshPolicy.priorObservation(at: historicalURL, profile: profile, identity: "account-b", now: fixed) == nil,
            "A prior observation cannot be imported for another account")
        let corruptRoot = root.appendingPathComponent("corrupt-polling")
        let corruptURL = corruptRoot.appendingPathComponent("quota-refresh-state.json")
        let corruptBytes = Data("not-json".utf8)
        try AtomicFileWriter.write(corruptBytes, to: corruptURL)
        let corruptPolicy = ClaudeQuotaRefreshPolicy(root: corruptRoot)
        let corruptCalls = PollCalls()
        _ = await corruptPolicy.read(identity: "account-a", now: fixed) {
            await corruptCalls.record(); return lastKnown
        }
        try check(await corruptCalls.count == 0 && Data(contentsOf: corruptURL) == corruptBytes,
            "Unreadable cooldown state must not trigger a blind network request or overwrite the file")
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
        try check(current.cached(profile: profile, auth: auth, now: fixed.addingTimeInterval(ClaudeCurrentUsageService.cacheFreshness + 1))?.isStale == true,
                  "Cache becomes historical after the configured freshness window")
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
        let store = ClaudeProfileStore(environment: environment, bridgeURL: bridge, currentUsageService: integrated,
            quotaRefreshPolicy: ClaudeQuotaRefreshPolicy(root: root.appendingPathComponent("policy-store-api")))
        store.refresh()
        let deadline = Date().addingTimeInterval(10)
        while store.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(store.statuses[profile.id]?.usage?.source == .oauthUsage, "Store publishes current account usage automatically")
        let mismatchedStore = ClaudeProfileStore(environment: environment, bridgeURL: bridge,
            currentUsageService: service("store-mismatch", FakeLoader(), FakeTransport(mismatch: true)),
            quotaRefreshPolicy: ClaudeQuotaRefreshPolicy(root: root.appendingPathComponent("policy-store-mismatch")))
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
            currentUsageService: service("store-native-priority", untouchedLoader, untouchedTransport),
            quotaRefreshPolicy: ClaudeQuotaRefreshPolicy(root: root.appendingPathComponent("policy-store-native")))
        nativeFirst.refresh()
        let nativeDeadline = Date().addingTimeInterval(10)
        while nativeFirst.isRefreshing && Date() < nativeDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(nativeFirst.statuses[profile.id]?.usage?.source == .nativeBridge && untouchedTransport.calls == 0,
                  "A fresh account-matched native bridge avoids quota API calls")
        var oldNative = native
        oldNative["fetchedAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: oldNative), to: nativeURL)
        let fallback = ClaudeProfileStore(environment: environment, bridgeURL: bridge,
            currentUsageService: service("store-bridge-fallback", FakeLoader(), FakeTransport(fail: true)),
            quotaRefreshPolicy: ClaudeQuotaRefreshPolicy(root: root.appendingPathComponent("policy-store-fallback")))
        fallback.refresh()
        let fallbackDeadline = Date().addingTimeInterval(10)
        while fallback.isRefreshing && Date() < fallbackDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(fallback.statuses[profile.id]?.usage?.source == .nativeBridge && fallback.statuses[profile.id]?.error != nil,
                  "A failed live read preserves a matching bridge observation as fallback")
        let olderAPI = ClaudeUsageSnapshot(fiveHour: ClaudeUsageWindow(usedPercentage: 50), sevenDay: nil,
            observedAt: Date().addingTimeInterval(-1200), source: .oauthUsage, isStale: true, accountVerified: true)
        let oldPolicy = ClaudeQuotaRefreshPolicy(root: root.appendingPathComponent("policy-old-api"))
        _ = await oldPolicy.read(identity: ClaudeUsageReader.accountFingerprint(auth)!, seed: olderAPI) {
            throw ClaudeCurrentUsageError.rateLimited
        }
        let cooledTransport = FakeTransport()
        let cooledStore = ClaudeProfileStore(environment: environment, bridgeURL: bridge,
            currentUsageService: service("cooled-store", FakeLoader(), cooledTransport), quotaRefreshPolicy: oldPolicy)
        cooledStore.refresh()
        let cooledDeadline = Date().addingTimeInterval(10)
        while cooledStore.isRefreshing && Date() < cooledDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(cooledStore.statuses[profile.id]?.usage?.source == .nativeBridge && cooledTransport.calls == 0,
            "A more recent bridge observation wins over older API history during a persisted cooldown")
        print("Claude current usage checks passed (fake credentials/HTTPS, identity races, private cache, backoff, isolation, store priority).")
    }
}
