import Foundation
import CodexProfileCore
import CryptoKit

// MARK: - UsageProvider

@MainActor
final class UsageProvider {
    private let store: ProfileStore
    private let paths: AppPaths
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UUID?
    private var lastRefreshAll: Date = .distantPast
    private var lastRefreshActive: [String: Date] = [:]
    private(set) var isRefreshing = false
    /// Leases currently held by this refresh cycle, keyed by profile ID, so
    /// `cancelRefreshes()` can release them immediately instead of waiting on
    /// an in-flight task's own `defer` — cooperative cancellation means that
    /// defer only runs once the task next checks `Task.isCancelled`, which can
    /// lag a cancellation by a couple of seconds while a fetch is in flight.
    private var activeLeases: [String: String] = [:]
    /// The in-flight lease release started by `cancelRefreshes()`. Releasing is
    /// `async` (the flock must stay off the main thread), and `clearSavedAuth`
    /// cancels and then immediately requests a fresh refresh — so without this
    /// handle the new refresh can reach `claimLease` before the old lease row
    /// is gone and lose its own claim for the lease's full lifetime. Awaited
    /// before any claim, which makes the ordering deterministic.
    private var pendingLeaseRelease: Task<Void, Never>?
    var onRefreshComplete: (() -> Void)?
    /// Fired after a profile's guarded status update, before slower profiles finish.
    var onProfileRefresh: ((String) -> Void)?

    init(store: ProfileStore) {
        self.store = store
        self.paths = store.usageAuthSource().paths
    }

    func cancelRefreshes() {
        let cancelledActiveRefresh = self.refreshGeneration != nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.refreshGeneration = nil
        self.isRefreshing = false
        // removeLease is `async` (it holds the flock, which must stay off the
        // main thread) and this method's callers are synchronous, so the
        // releases start here and are awaited at the next claim rather than
        // blocking this main-actor call. Chained onto any previous release so
        // two cancels in a row cannot reorder.
        let leasesToRelease = self.activeLeases
        self.activeLeases.removeAll()
        if !leasesToRelease.isEmpty {
            let previous = self.pendingLeaseRelease
            let paths = self.paths
            self.pendingLeaseRelease = Task {
                await previous?.value
                for (profileID, token) in leasesToRelease {
                    await Self.removeLease(profileIDs: [profileID], expectedToken: token, paths: paths)
                }
            }
        }
        if cancelledActiveRefresh {
            self.store.flushCacheIfDirty()
        }
    }

    func refreshAll(force: Bool = false) {
        guard !self.isRefreshing else { return }
        guard force || Date().timeIntervalSince(self.lastRefreshAll) > 60 else { return }

        // The nightly renewal LaunchAgent writes rejections to the shared cache
        // file from a separate process; re-read them at the start of every
        // cycle so this run's statuses reflect the current on-disk state.
        self.store.reloadRenewalStatesFromDisk()

        if !force,
           self.store.statuses.values.allSatisfy({
               switch $0 {
               case .notSetUp: return true
               default: return false
               }
           }) {
            return
        }

        let now = Date()
        self.lastRefreshAll = now
        let liveId = self.store.liveProfileId ?? ""
        let profiles = self.store.config.profiles.sorted {
            // Keep stable profile order while scheduling the active credential first.
            ($0.id == liveId ? 0 : 1) < ($1.id == liveId ? 0 : 1)
        }
        if profiles.contains(where: { $0.id == liveId }) {
            self.lastRefreshActive[liveId] = now
        }
        let contexts = profiles.map { p in
            RefreshContext(id: p.id, cached: self.store.cache.snapshots[p.id], isLive: p.id == liveId)
        }
        self.startRefresh(contexts: contexts)
    }

    /// Cheap timer/menu refresh of only the current profile. Shares the full refresh's
    /// lifecycle so cancellation, renewal coordination and leases remain serialized.
    func refreshActive(force: Bool = false) {
        guard !self.isRefreshing, !self.store.isAuthMutationInProgress(),
              let id = self.store.liveProfileId,
              self.store.config.profiles.contains(where: { $0.id == id }) else { return }
        let now = Date()
        // A slightly late timer fire must not make the next 30s tick miss its
        // cooldown by a fraction of a second and defer the refresh to 60s.
        let activeCooldown = max(1, RefreshPreferences.activeAccountRefreshInterval - 1)
        guard force || now.timeIntervalSince(self.lastRefreshActive[id] ?? .distantPast) >= activeCooldown else { return }
        self.store.reloadRenewalStatesFromDisk()
        self.lastRefreshActive[id] = now
        self.startRefresh(contexts: [RefreshContext(id: id, cached: self.store.cache.snapshots[id], isLive: true)])
    }

    private func startRefresh(contexts: [RefreshContext]) {
        self.isRefreshing = true
        let generation = UUID()
        self.refreshGeneration = generation
        let source = self.store.usageAuthSource()

        self.refreshTask = Task { @MainActor in
            let groups = await Self.groupContexts(contexts, source: source)
            guard !Task.isCancelled, self.refreshGeneration == generation else { return }
            await withTaskGroup(of: Void.self) { group in
                var pending = groups[...]
                let initialBatch = min(3, pending.count)
                for _ in 0 ..< initialBatch {
                    let fetchGroup = pending.removeFirst()
                    group.addTask { @MainActor in
                        await self.refreshGroup(fetchGroup, generation: generation, source: source)
                    }
                }
                for await _ in group {
                    guard !Task.isCancelled, self.refreshGeneration == generation else {
                        group.cancelAll()
                        break
                    }
                    if let fetchGroup = pending.popFirst() {
                        group.addTask { @MainActor in
                            await self.refreshGroup(fetchGroup, generation: generation, source: source)
                        }
                    }
                }
            }
            if self.refreshGeneration == generation {
                self.isRefreshing = false
                self.refreshTask = nil
                self.refreshGeneration = nil
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    struct RefreshContext {
        let id: String
        let cached: UsageSnapshot?
        let isLive: Bool
        /// This profile's own credential fingerprint (SHA-256(refresh token),
        /// first 12 hex chars — matches the CLI's `renewalCredentialFingerprint`),
        /// computed from its individually-loaded auth blob before batching by
        /// identity. Used to detect that a persisted rejection's credential has
        /// been replaced. Nil when the auth blob could not be loaded or parsed.
        var credentialFingerprint: String? = nil
        var usesLiveAuth = false
        var usesReadOnlyLiveAuth = false
    }

    struct RefreshGroup {
        var contexts: [RefreshContext]
        let authData: Data?
        let queryAuthData: Data?
        let loadError: (any Error)?
    }

    nonisolated static func groupContexts(
        _ contexts: [RefreshContext], source: ProfileStore.UsageAuthSource
    ) async -> [RefreshGroup] {
        var groups: [String: RefreshGroup] = [:]
        for var context in contexts {
            guard !Task.isCancelled else { break }
            var loadError: (any Error)?
            var authData: Data?
            var queryAuthData: Data?
            do {
                let loaded = try await Self.loadAuthData(
                    source: source, profileID: context.id, isLive: context.isLive)
                authData = loaded?.data
                queryAuthData = loaded?.queryData
                context.usesLiveAuth = loaded?.usesLiveAuth ?? false
                context.usesReadOnlyLiveAuth = loaded?.isReadOnlyLive ?? false
            } catch {
                loadError = error
            }
            context.credentialFingerprint = authData.flatMap(Self.credentialFingerprint(from:))
            // Group by credential fingerprint, not identity: this batches
            // per-profile usage/health refreshes, and two profiles sharing an
            // account identity can still hold different credentials. Batching
            // by identity would fetch one profile's usage and apply it to a
            // sibling profile with a different refresh token.
            let key = context.usesReadOnlyLiveAuth ? "live-read-only:\(context.id)" :
                (context.credentialFingerprint ?? "profile:\(context.id)")
            if var group = groups[key] {
                group.contexts.append(context)
                groups[key] = group
            } else {
                groups[key] = RefreshGroup(contexts: [context], authData: authData,
                                           queryAuthData: queryAuthData, loadError: loadError)
            }
        }
        // Dictionary iteration order must not push the active account behind slow
        // inactive requests. Preserve the supplied order for the other groups.
        let order = Dictionary(contexts.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: min)
        return groups.values.sorted { lhs, rhs in
            let leftLive = lhs.contexts.contains(where: \.isLive)
            let rightLive = rhs.contexts.contains(where: \.isLive)
            if leftLive != rightLive { return leftLive }
            let leftOrder = lhs.contexts.compactMap { order[$0.id] }.min() ?? Int.max
            let rightOrder = rhs.contexts.compactMap { order[$0.id] }.min() ?? Int.max
            return leftOrder < rightOrder
        }
    }

    /// Mirrors the CLI's `renewalCredentialFingerprint`: SHA-256 of the refresh
    /// token, first 12 hex characters. Used to detect when a profile's stored
    /// credential has moved past the one a persisted rejection condemned.
    private nonisolated static func credentialFingerprint(from authData: Data) -> String? {
        guard let credentials = try? AuthBlob.load(from: authData), !credentials.refreshToken.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(credentials.refreshToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(12))
    }

    private func refreshGroup(
        _ fetchGroup: RefreshGroup, generation: UUID, source: ProfileStore.UsageAuthSource
    ) async {
        guard !Task.isCancelled, self.refreshGeneration == generation,
              !self.store.isAuthMutationInProgress() else { return }
        var diagnostics = Dictionary(uniqueKeysWithValues: fetchGroup.contexts.map {
            ($0.id, ProfileRefreshDiagnostics(lastAttemptAt: Date()))
        })

        func canFinalize(_ context: RefreshContext) -> Bool {
            !Task.isCancelled && self.refreshGeneration == generation
                && !self.store.isAuthMutationInProgress()
                && context.isLive == (context.id == (self.store.liveProfileId ?? ""))
                && self.store.config.profiles.contains(where: { $0.id == context.id })
        }

        func finalize(
            _ context: RefreshContext, _ status: ProfileStatus, decision: String
        ) async {
            // Bail if the refresh was cancelled (e.g. by cancelRefreshes() during
            // a profile switch). Prevents in-flight stale writes from landing.
            guard canFinalize(context) else { return }

            // Re-derive liveness at finalize time. The snapshot was fetched under
            // whichever credentials were live at refresh START; if the live
            // profile changed mid-flight, this snapshot was read against the wrong
            // auth.json and must not be written under `id`. The post-switch forced
            // refreshAll will supply correct data, so we drop the result here.
            let currentlyLive = context.id == (self.store.liveProfileId ?? "")
            diagnostics[context.id]?.lastDecision = decision
            // A new login can replace the same profile slot during a fetch.
            // Re-read its credential off the main actor and reject results
            // belonging to the prior account, even if the slot stayed live.
            let currentAuth: LoadedAuth?
            do {
                currentAuth = try await Self.loadAuthData(
                    source: source, profileID: context.id, isLive: currentlyLive)
            } catch {
                guard canFinalize(context) else { return }
                diagnostics[context.id]?.lastError = error.localizedDescription
                diagnostics[context.id]?.lastDecision = "auth-unavailable"
                self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
                self.store.updateStatus(context.id, .stale(context.cached))
                self.onProfileRefresh?(context.id)
                return
            }
            guard canFinalize(context) else { return }
            if currentAuth == nil {
                let overrideDecision = context.cached != nil ? "relogin-needed" : "not-set-up"
                diagnostics[context.id]?.lastDecision = overrideDecision
                self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
                self.store.updateStatus(context.id, context.cached.map { .reloginNeeded($0) } ?? .notSetUp)
                self.onProfileRefresh?(context.id)
                return
            }
            if context.usesReadOnlyLiveAuth, currentAuth?.isReadOnlyLive != true {
                // Desktop may have switched accounts or its token may have
                // expired during the query. A fallback saved blob is not proof
                // that this result still belongs to the current live session.
                diagnostics[context.id]?.lastDecision = "live-read-only-source-changed"
                self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
                self.store.updateStatus(context.id, .stale(context.cached))
                self.onProfileRefresh?(context.id)
                return
            }
            if let fetchedAuth = fetchGroup.authData, let currentAuth,
               !AuthBlob.identityMatches(fetchedAuth, currentAuth.data) {
                return
            }
            if !context.usesReadOnlyLiveAuth {
                self.store.clearRenewalStateIfCredentialMoved(
                    for: context.id,
                    currentCredentialFingerprint: currentAuth.flatMap { Self.credentialFingerprint(from: $0.data) })
            }
            if context.usesReadOnlyLiveAuth, case let .available(snapshot) = status {
                diagnostics[context.id]?.lastDecision = "available-live-read-only"
                self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
                self.store.updateLiveUsageSnapshot(context.id, snapshot)
                self.onProfileRefresh?(context.id)
                return
            }
            self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
            self.store.updateStatus(context.id, status)
            self.onProfileRefresh?(context.id)
        }

        guard let authData = fetchGroup.authData else {
            for context in fetchGroup.contexts {
                if let error = fetchGroup.loadError {
                    // Loading the auth blob threw. `.notFound` means genuinely no
                    // credential; any other error (e.g. a Keychain read failure)
                    // must not be reported as "not set up" — fall back to the
                    // last-known snapshot and surface the error, matching the
                    // pre-batching behavior this replaced.
                    diagnostics[context.id]?.lastError = error.localizedDescription
                    if let authError = error as? AuthError, case .notFound = authError {
                        await finalize(context, .notSetUp, decision: "not-set-up")
                    } else {
                        await finalize(context, .stale(context.cached), decision: "stale")
                        AppLogger.warning("Usage refresh failed",
                                          metadata: ["profile": context.id, "error": error.localizedDescription])
                    }
                } else {
                    await finalize(context, .notSetUp, decision: "not-set-up")
                }
            }
            return
        }

        let reservation = LeaseReservation(
            token: UUID().uuidString,
            home: "",
            expiresAt: Date().addingTimeInterval(60),
            createdAt: Date())
        await self.pendingLeaseRelease?.value
        guard !Task.isCancelled, self.refreshGeneration == generation,
              !self.store.isAuthMutationInProgress() else { return }
        guard await Self.claimLease(
            profileIDs: fetchGroup.contexts.map(\.id), reservation: reservation, paths: self.paths) else {
            for context in fetchGroup.contexts {
                await finalize(context, .stale(context.cached), decision: "reserved")
            }
            return
        }
        guard !Task.isCancelled, self.refreshGeneration == generation,
              !self.store.isAuthMutationInProgress() else {
            await Self.removeLease(
                profileIDs: fetchGroup.contexts.map(\.id), expectedToken: reservation.token, paths: self.paths)
            return
        }
        for context in fetchGroup.contexts {
            self.activeLeases[context.id] = reservation.token
        }
        // `removeLease` is `async` (it holds `flock` and must stay off the
        // main thread), and `defer` cannot contain `await`, so the lease
        // release below is called explicitly on every exit path from this
        // point instead of via `defer`. There are exactly two: the
        // `CancellationError` early return, and falling off the end of the
        // `do`/`catch` below.

        do {
            let result = try await CLIUsageFetcher.fetchResult(
                profileId: fetchGroup.contexts[0].id, authData: fetchGroup.queryAuthData ?? authData,
                codexConfigURL: self.store.codexConfigURL(),
                environment: source.paths.environment,
                clientVersion: AppInfo.version)
            await self.persistRotatedAuth(result.updatedAuthData, original: authData, group: fetchGroup, source: source)
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = nil
                await finalize(context, .available(result.snapshot), decision: "available")
                AppLogger.info("Usage refresh succeeded", metadata: ["profile": context.id])
            }
        } catch is CancellationError {
            await self.releaseLease(fetchGroup.contexts.map(\.id), expectedToken: reservation.token)
            return
        } catch let error as CLIUsageOperationError {
            await self.persistRotatedAuth(error.updatedAuthData, original: authData, group: fetchGroup, source: source)
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                await finalize(
                    context,
                    error.isAuthRequired ? .reloginNeeded(context.cached) : .stale(context.cached),
                    decision: error.isAuthRequired ? "relogin-needed" : "stale")
                AppLogger.warning("Usage refresh failed",
                                  metadata: ["profile": context.id, "error": error.localizedDescription])
            }
        } catch let error as CodexRPCError where error.isAuthRequired {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                await finalize(context, .reloginNeeded(context.cached), decision: "relogin-needed")
                AppLogger.warning("Usage refresh requires re-login",
                                  metadata: ["profile": context.id, "error": error.localizedDescription])
            }
        } catch let error as AuthError {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                if case .notFound = error {
                    await finalize(context, .notSetUp, decision: "not-set-up")
                } else {
                    await finalize(context, .stale(context.cached), decision: "stale")
                    AppLogger.warning("Usage refresh failed",
                                      metadata: ["profile": context.id, "error": error.localizedDescription])
                }
            }
        } catch {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                await finalize(context, .stale(context.cached), decision: "stale")
                AppLogger.warning("Usage refresh failed",
                                  metadata: ["profile": context.id, "error": error.localizedDescription])
            }
        }
        await self.releaseLease(fetchGroup.contexts.map(\.id), expectedToken: reservation.token)
    }

    /// Releases a lease claimed by `refreshGroup` and clears it from
    /// `activeLeases`. Called explicitly at every exit point of
    /// `refreshGroup` after the lease is claimed, since `removeLease` is
    /// `async` and `defer` bodies cannot contain `await`.
    private func releaseLease(_ profileIDs: [String], expectedToken: String) async {
        await Self.removeLease(profileIDs: profileIDs, expectedToken: expectedToken, paths: self.paths)
        for id in profileIDs where self.activeLeases[id] == expectedToken {
            self.activeLeases.removeValue(forKey: id)
        }
    }

    /// Thrown inside the lock closures below to short-circuit a write when
    /// `loadCache` reports `.decodeFailed` — the on-disk cache is
    /// unknown-but-real and must not be clobbered with an empty/partial one.
    private struct CacheDecodeFailed: Error {}

    nonisolated static func claimLease(
        profileIDs: [String], reservation: LeaseReservation, paths: AppPaths
    ) async -> Bool {
        do {
            try CacheLock.withLock(at: paths.cacheLockURL) {
                var cache: UsageCache
                switch Self.loadCache(paths: paths) {
                case .missing:
                    cache = UsageCache(snapshots: [:])
                case .loaded(let loaded):
                    cache = loaded
                case .decodeFailed:
                    AppLogger.warning(
                        "Usage cache failed to decode; refusing to claim lease over unknown on-disk state",
                        metadata: ["path": paths.cacheURL.path])
                    throw CacheDecodeFailed()
                }
                for profileID in profileIDs {
                    if let existing = cache.leases[profileID], existing.token != reservation.token {
                        guard existing.isActive() || !existing.home.isEmpty else {
                            cache.leases.removeValue(forKey: profileID)
                            continue
                        }
                        throw LeaseClaimLost()
                    }
                }
                for profileID in profileIDs {
                    cache.leases[profileID] = reservation
                }
                try Self.saveCache(cache, paths: paths)
            }
            return true
        } catch {
            return false
        }
    }

    nonisolated static func removeLease(
        profileIDs: [String], expectedToken: String, paths: AppPaths
    ) async {
        try? CacheLock.withLock(at: paths.cacheLockURL) {
            var cache: UsageCache
            switch Self.loadCache(paths: paths) {
            case .missing:
                cache = UsageCache(snapshots: [:])
            case .loaded(let loaded):
                cache = loaded
            case .decodeFailed:
                AppLogger.warning(
                    "Usage cache failed to decode; refusing to release lease over unknown on-disk state",
                    metadata: ["path": paths.cacheURL.path])
                return
            }
            for profileID in profileIDs where cache.leases[profileID]?.token == expectedToken {
                cache.leases.removeValue(forKey: profileID)
            }
            try Self.saveCache(cache, paths: paths)
        }
    }

    /// Outcome of attempting to load the on-disk cache. Distinguishes "no file
    /// yet" (an empty cache is the correct value, safe to write back) from
    /// "a file exists but didn't decode" (its content is unknown-but-real —
    /// missing, unreadable, corrupt, or containing a sub-record shape this
    /// build can't parse — and callers must not overwrite it).
    private enum CacheLoadResult {
        case missing
        case decodeFailed
        case loaded(UsageCache)
    }

    private nonisolated static func loadCache(paths: AppPaths) -> CacheLoadResult {
        guard FileManager.default.fileExists(atPath: paths.cacheURL.path) else {
            return .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: paths.cacheURL),
              let cache = try? decoder.decode(UsageCache.self, from: data) else {
            return .decodeFailed
        }
        return .loaded(cache)
    }

    private nonisolated static func saveCache(_ cache: UsageCache, paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(cache), to: paths.cacheURL)
    }

    private struct LeaseClaimLost: Error {}

    /// Loads the auth blob off the main actor. `nonisolated` so that awaiting it
    /// from the main actor runs the body on the global concurrent executor,
    /// keeping the potentially-blocking file/Keychain syscall off the main thread.
    struct LoadedAuth {
        let data: Data
        let queryData: Data
        let usesLiveAuth: Bool
        let isReadOnlyLive: Bool
    }

    nonisolated static func loadAuthData(
        source: ProfileStore.UsageAuthSource, profileID: String, isLive: Bool
    ) async throws -> LoadedAuth? {
        if let saved = try source.vault.loadAuthBlob(profileID: profileID) {
            // A plan change or Desktop token rotation can leave an independent
            // saved session stale. Use the matching active Desktop access token
            // only while its JWT is valid, with its real refresh token removed.
            if isLive, let live = try? Data(contentsOf: source.liveAuthURL),
               AuthBlob.identityMatches(saved, live), let query = ReadOnlyUsageAuth.prepare(from: live) {
                return LoadedAuth(data: live, queryData: query, usesLiveAuth: true, isReadOnlyLive: true)
            }
            return LoadedAuth(data: saved, queryData: saved, usesLiveAuth: false, isReadOnlyLive: false)
        }
        // Without a saved identity there is no proof that this slot owns the
        // live account. Never borrow another account or an unknown live session.
        return nil
    }

    private func persistRotatedAuth(
        _ updated: Data?, original: Data, group: RefreshGroup, source: ProfileStore.UsageAuthSource
    ) async {
        guard let updated else { return }
        // All child writes from a live read-only query are disposable, including
        // errors. Neither the vault nor Desktop auth can receive that output.
        guard !group.contexts.contains(where: \.usesReadOnlyLiveAuth) else { return }
        // Persist a successfully rotated token even when the refresh was
        // cancelled after its network request. The CAS preserves any newer
        // login/deletion while preventing cancellation from discarding rotation.
        let profileIDs = group.contexts.map(\.id)
        let liveURL = group.contexts.contains(where: \.usesLiveAuth) ? source.liveAuthURL : nil
        await Self.persistRotatedAuth(
            updated, original: original, profileIDs: profileIDs, vault: source.vault, liveAuthURL: liveURL)
    }

    private nonisolated static func persistRotatedAuth(
        _ updated: Data, original: Data, profileIDs: [String], vault: AuthVault, liveAuthURL: URL?
    ) async {
        do {
            _ = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: updated,
                profileIDs: profileIDs, vault: vault, liveAuthURL: liveAuthURL)
        } catch {
            AppLogger.warning("Could not save Codex's rotated credential",
                              metadata: ["error": error.localizedDescription])
        }
    }
}
