import CodexProfileCore
import Combine
import Foundation

/// Usage observers are independent of the account-switching registries.
@MainActor
final class ExternalProviderStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderUsageSnapshot] = [:]
    @Published private(set) var refreshing: Set<ProviderID> = []
    var onChange: (() -> Void)?

    private let adapters: [ProviderID: any UsageProviderAdapter]
    private var tasks: [ProviderID: Task<Void, Never>] = [:]
    private var credentialGeneration: [ProviderID: UInt64] = [:]
    private var pendingForced: Set<ProviderID> = []
    private var lastAttempt: [ProviderID: Date] = [:]

    init(adapters: [any UsageProviderAdapter]) {
        self.adapters = Dictionary(adapters.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func refresh(_ provider: ProviderID? = nil, force: Bool = false) {
        for id in provider.map({ [$0] }) ?? [.antigravity, .glm] {
            guard let adapter = adapters[id] else { continue }
            if refreshing.contains(id) {
                if force { pendingForced.insert(id) }
                continue
            }
            let failedAuth = snapshots[id]?.state == .error(.authenticationRequired)
            let cooldown: TimeInterval = failedAuth ? 120 : 29
            guard force || Date().timeIntervalSince(lastAttempt[id] ?? .distantPast) >= cooldown else { continue }
            let generation = credentialGeneration[id, default: 0]
            lastAttempt[id] = Date()
            refreshing.insert(id)
            tasks[id] = Task { [weak self] in
                let snapshot = await adapter.readUsageSnapshot()
                guard let self, !Task.isCancelled else { return }
                defer {
                    self.refreshing.remove(id); self.tasks[id] = nil; self.onChange?()
                    if self.pendingForced.remove(id) != nil { self.refresh(id, force: true) }
                }
                guard snapshot.provider == id, self.credentialGeneration[id, default: 0] == generation else { return }
                // Failed reads replace the observation. Old-account numbers never
                // survive a sign-out or a failed account verification as current quota.
                self.snapshots[id] = snapshot
            }
        }
        onChange?()
    }

    func credentialsDidChange(_ provider: ProviderID) {
        credentialGeneration[provider, default: 0] &+= 1
        snapshots.removeValue(forKey: provider)
        onChange?()
        refresh(provider, force: true)
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        pendingForced.removeAll()
        refreshing.removeAll()
    }
}

enum ProviderQuotaPresentation {
    static func modeKey(_ provider: ProviderID, _ bucket: ProviderUsageBucket) -> String {
        let id = Data(bucket.id.utf8).base64EncodedString()
        return "usageMode.\(provider.rawValue).\(id)"
    }

    static func remaining(_ bucket: ProviderUsageBucket, snapshot: ProviderUsageSnapshot?, at date: Date = Date()) -> Double? {
        guard let snapshot, snapshot.isCurrent(at: date),
              bucket.resetAt.map({ $0 > date }) ?? true,
              let fraction = bucket.remainingFraction, fraction.isFinite else { return nil }
        return fraction * 100
    }

    static func selectedBuckets(_ snapshot: ProviderUsageSnapshot?) -> [ProviderUsageBucket] {
        guard let snapshot else { return [] }
        if snapshot.provider == .antigravity {
            return [ProviderUsageBucketGroup.gemini, .other].compactMap { group in
                let candidates = snapshot.buckets.filter { $0.group == group }
                let selectedID = UserDefaults.standard.string(forKey: "antigravityMenuBucket.\(group.rawValue)")
                return candidates.first(where: { $0.id == selectedID }) ?? candidates.first
            }
        }
        return Array(snapshot.buckets.prefix(2))
    }

    static func message(_ snapshot: ProviderUsageSnapshot?, provider: ProviderID) -> String {
        guard let snapshot else { return "Checking existing \(provider.displayName) sign-in…" }
        switch snapshot.state {
        case .available:
            if !snapshot.accountVerified { return "Account could not be verified; quota is unavailable." }
            if !snapshot.isCurrent() { return "Observation is out of date. Refresh to read current quota." }
            return snapshot.buckets.isEmpty ? "The service did not report quota windows." : ""
        case .signedOut: return "Sign in to \(provider == .glm ? "ZCode / Z.ai" : "Antigravity") to read your subscription quota."
        case .unavailable: return "No supported quota source was found. See settings for connection details."
        case .error(let error):
            switch error {
            case .credentialAccessUnsupported: return "Connect a Z.ai Coding Plan API key in settings. ZCode keeps its sign-in encrypted."
            case .authenticationRequired: return provider == .glm ? "Z.ai rejected the supplied Coding Plan API key. Check it in settings, then refresh." : "Check your Antigravity CLI sign-in, then refresh."
            case .rateLimited: return "The service asked us to wait before refreshing."
            case .networkUnavailable: return "Could not reach the quota service."
            case .malformedResponse: return "The service returned an unsupported quota response."
            case .unsupported: return "This installed version does not expose supported quota data."
            case .unknown: return "Could not read the current quota."
            }
        }
    }
}
