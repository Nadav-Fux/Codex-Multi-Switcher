@testable import CodexMultiSwitcherApp
import CodexProfileCore
import Foundation
import Testing

struct RefreshRegressionTests {
    @Test @MainActor
    func reauthenticationOnlyReplacesUnchangedLiveAuth() throws {
        let paths = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.userHome) }
        let store = Self.profileStore(paths: paths)
        let previous = Self.fakeAuth("previous")
        let renewed = Self.fakeAuth("renewed")
        let desktop = Self.fakeAuth("desktop")
        func signIn(startingWith expected: Data?, duringLogin: () throws -> Void) throws -> Bool? {
            try store.saveAuthDataToVault(previous, for: "1")
            var finishLogin: ((Result<Void, CodexBridgeError>) -> Void)?
            var syncResult: Result<Bool?, Error>?
            store.startLogin(for: "1", launch: { _, callback in
                // Hold the callback until Desktop has had a chance to write.
                finishLogin = callback
            }) { _, start in
                syncResult = Result {
                    #expect(try start.liveAuth.get() == expected)
                    return try store.syncSavedAuthAfterLogin(start)
                }
            }
            try duringLogin()
            try store.saveAuthDataToVault(renewed, for: "1")
            let callback = try #require(finishLogin)
            callback(.success(()))
            return try #require(syncResult).get()
        }

        #expect(try signIn(startingWith: nil) {
            try AtomicFileWriter.write(desktop, to: paths.liveAuthURL)
        } == false)
        #expect(try store.liveAuthData() == desktop)

        try AtomicFileWriter.write(previous, to: paths.liveAuthURL)
        #expect(try signIn(startingWith: previous) {
            try AtomicFileWriter.write(desktop, to: paths.liveAuthURL)
        } == false)
        #expect(try store.liveAuthData() == desktop)

        try AtomicFileWriter.write(previous, to: paths.liveAuthURL)
        #expect(try signIn(startingWith: previous) {
            try FileManager.default.removeItem(at: paths.liveAuthURL)
        } == false)
        #expect(try store.liveAuthData() == nil)
        #expect(try signIn(startingWith: nil) {} == true)
        #expect(try store.liveAuthData() == renewed)

        try AtomicFileWriter.write(previous, to: paths.liveAuthURL)
        #expect(try signIn(startingWith: previous) {} == true)
        #expect(try store.liveAuthData() == renewed)
    }

    @Test @MainActor
    func reauthenticationClearsUsageWhenAccountIsDifferentOrUnknown() throws {
        let paths = Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.userHome) }
        let store = Self.profileStore(paths: paths)
        let other = store.addProfile().id
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(planType: "team", creditsRemaining: nil, primaryUsedPercent: 75,
            primaryResetAt: nil, secondaryUsedPercent: 50, secondaryResetAt: nil, fetchedAt: timestamp)
        let override = ExhaustionOverride(blockedUntil: timestamp, reason: "quota", source: "test")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try store.saveAuthDataToVault(Self.fakeAuth("old"), for: "1")
        let oldFingerprint = try #require(store.savedAuthFingerprint(for: "1"))
        let cached = UsageCache(snapshots: ["1": snapshot, other: snapshot],
            exhaustionOverrides: ["1": override, other: override])
        try encoder.encode(cached).write(to: paths.cacheURL, options: .atomic)
        let loaded = Self.profileStore(paths: paths)
        loaded.updateRefreshDiagnostics("1", ProfileRefreshDiagnostics(lastDecision: "available"))

        loaded.discardUsageIfAccountChanged(for: "1", previousFingerprint: oldFingerprint)
        #expect(loaded.cache.snapshots["1"] == snapshot)
        #expect(loaded.cache.exhaustionOverrides["1"] == override)

        try loaded.saveAuthDataToVault(Self.fakeAuth("new"), for: "1")
        loaded.discardUsageIfAccountChanged(for: "1", previousFingerprint: oldFingerprint)
        #expect(loaded.cache.snapshots["1"] == nil)
        #expect(loaded.cache.exhaustionOverrides["1"] == nil)
        #expect(loaded.refreshDiagnostics["1"] == nil)
        guard case .loading? = loaded.statuses["1"] else {
            try envFail("Account change did not reset the displayed status")
        }
        let onDisk = try decoder.decode(UsageCache.self, from: Data(contentsOf: paths.cacheURL))
        #expect(onDisk.snapshots == [other: snapshot])
        #expect(onDisk.exhaustionOverrides == [other: override])

        loaded.updateStatus("1", .available(snapshot))
        loaded.discardUsageIfAccountChanged(for: "1", previousFingerprint: nil)
        #expect(loaded.cache.snapshots["1"] == nil)
    }

    @Test @MainActor
    func glmCooldownBlocksForcedRefreshUntilFiveMinutesAfterRateLimit() async {
        let adapter = RateLimitedGLMAdapter()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ExternalProviderStore(adapters: [adapter], now: { now })
        await withCheckedContinuation { continuation in
            store.onChange = {
                guard !store.refreshing.contains(.glm) else { return }
                store.onChange = nil
                continuation.resume()
            }
            store.refresh(.glm)
            store.refresh(.glm, force: true)
            now += 6
        }
        #expect(store.snapshots[.glm]?.state == .error(.rateLimited))
        #expect(!store.refreshing.contains(.glm))
        now += 299
        store.refresh(.glm)
        store.refresh(.glm, force: true)
        #expect(!store.refreshing.contains(.glm))
        #expect(await adapter.callCount == 1)

        now += 1
        await withCheckedContinuation { continuation in
            store.onChange = {
                guard !store.refreshing.contains(.glm) else { return }
                store.onChange = nil
                continuation.resume()
            }
            store.refresh(.glm, force: true)
        }
        #expect(await adapter.callCount == 2)
        #expect(store.snapshots[.glm]?.state == .available)
    }

    private static func temporaryPaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-refresh-tests-\(UUID().uuidString)", isDirectory: true)
        return AppPaths(environment: ["CODEX_PROFILE_HOME": root.path])
    }

    @MainActor private static func profileStore(paths: AppPaths) -> ProfileStore {
        let vault = FileAuthVault(root: paths.devAuthStoreURL, authLockURL: paths.authLockURL)
        return ProfileStore(authVault: vault, environment: paths.environment)
    }

    private static func fakeAuth(_ label: String) -> Data {
        Data(#"{"OPENAI_API_KEY":"test-\#(label)"}"#.utf8)
    }
}

private actor RateLimitedGLMAdapter: UsageProviderAdapter {
    let providerID = ProviderID.glm
    private(set) var callCount = 0

    func readUsageSnapshot() async -> ProviderUsageSnapshot {
        self.callCount += 1
        return ProviderUsageSnapshot(provider: self.providerID, source: "fixture",
            state: self.callCount == 1 ? .error(.rateLimited) : .available)
    }
}
