import CodexProfileCore
import Foundation
import CryptoKit

struct AntigravityProviderAdapter: UsageProviderAdapter {
    let providerID = ProviderID.antigravity
    private let reader = AntigravityUsageReader()

    func readUsageSnapshot() async -> ProviderUsageSnapshot {
        do {
            let usage = try await reader.read()
            let buckets = usage.buckets.map { bucket in
                ProviderUsageBucket(id: bucket.id, title: bucket.window == "5h" ? "5 hour" : bucket.window == "weekly" ? "Weekly" : bucket.windowLabel,
                    detail: bucket.modelDescription,
                    remainingFraction: bucket.remainingFraction, resetAt: bucket.resetsAt,
                    group: bucket.family == .gemini ? .gemini : bucket.family == .nonGemini ? .other : .general)
            }
            return ProviderUsageSnapshot(provider: providerID,
                account: ProviderAccount(displayName: "Current Antigravity CLI account"),
                buckets: buckets, observedAt: usage.observedAt,
                source: "Official Antigravity CLI /usage · account used by agy; IDE account may differ",
                accountVerified: usage.accountVerified)
        } catch {
            let state: ProviderSnapshotState
            switch error as? AntigravityUsageError {
            case .cliMissing: state = .unavailable
            case .unsupportedCLIVersion: state = .error(.unsupported)
            case .invalidResponse: state = .error(.malformedResponse)
            case .noQuotaData: state = .unavailable
            case .timedOut: state = .error(.networkUnavailable)
            default: state = .error(.authenticationRequired)
            }
            return ProviderUsageSnapshot(provider: providerID, source: "Official Antigravity CLI /usage", state: state)
        }
    }
}

struct GLMProviderAdapter: UsageProviderAdapter {
    let providerID = ProviderID.glm

    func readUsageSnapshot() async -> ProviderUsageSnapshot {
        async let accountBenefits = GLMAccountBenefitsCache.shared.read()
        do {
            guard let key = try GLMCredentialStore.load() else {
                return ProviderUsageSnapshot(provider: providerID, source: "Z.ai Coding Plan quota",
                    state: .error(.credentialAccessUnsupported), glmAccountBenefits: await GLMAccountBenefitsCache.shared.validate(await accountBenefits))
            }
            let service = GLMCodingPlanUsageService(apiKey: key, planKind: .individual)
            async let quota = service.fetch()
            async let enrichment = GLMMonitorCache.shared.read(apiKey: key)
            let usage = try await quota
            let monitor = await enrichment
            let benefitsRead = await accountBenefits
            guard try GLMCredentialStore.load() == key else { throw GLMQuotaError.accountChanged }
            let benefits = await GLMAccountBenefitsCache.shared.validate(benefitsRead)
            guard try GLMCredentialStore.load() == key else { throw GLMQuotaError.accountChanged }
            let windows: [(String, String, GLMQuotaWindow?)] = [
                ("five-hour", "5 hour", usage.fiveHour),
                ("weekly", "Weekly", usage.weekly),
                ("monthly-tools", "Monthly tools / MCP", usage.monthlyTool),
            ]
            let buckets = windows.compactMap { id, title, window -> ProviderUsageBucket? in
                guard let window else { return nil }
                return ProviderUsageBucket(id: id, title: title,
                    remainingFraction: window.remainingPercentage / 100, resetAt: window.resetsAt)
            }
            return ProviderUsageSnapshot(provider: providerID,
                account: ProviderAccount(displayName: "Connected Z.ai Coding Plan key"),
                plan: ProviderPlan(name: monitor?.subscription?.productName ?? (usage.planKind == .individual ? "Personal Coding Plan" : "Team Coding Plan")),
                buckets: buckets, observedAt: usage.observedAt,
                source: "Z.ai Coding Plan quota · app Keychain key",
                accountVerified: usage.accountVerified, glmMonitor: monitor, glmAccountBenefits: benefits)
        } catch {
            let state: ProviderSnapshotState
            AppLogger.warning("GLM quota read failed", metadata: ["category": String(describing: type(of: error))])
            switch error as? GLMQuotaError {
            case .credentialUnavailable: state = .signedOut
            case .credentialRejected: state = .error(.authenticationRequired)
            case .unsupportedPlan: state = .error(.unsupported)
            case .encryptedCredentialUnsupported: state = .error(.credentialAccessUnsupported)
            case .invalidResponse: state = .error(.malformedResponse)
            case .quotaUnavailable: state = .unavailable
            case .accountChanged: state = .error(.authenticationRequired)
            default: state = error is GLMCredentialStore.Failure ? .error(.credentialAccessUnsupported) : .error(.networkUnavailable)
            }
            return ProviderUsageSnapshot(provider: providerID, source: "Z.ai Coding Plan quota", state: state, glmAccountBenefits: await GLMAccountBenefitsCache.shared.validate(await accountBenefits))
        }
    }
}

/// Rich monitor data needs fewer requests than the compact quota indicator.
/// The cache is memory-only and bound to a key fingerprint, never to a raw key.
private actor GLMMonitorCache {
    static let shared = GLMMonitorCache()
    private var fingerprint: Data?
    private var lastAttempt = Date.distantPast
    private var snapshot: GLMMonitorUsageSnapshot?

    func read(apiKey: String) async -> GLMMonitorUsageSnapshot? {
        let current = Data(SHA256.hash(data: Data(apiKey.utf8)))
        if fingerprint != current {
            fingerprint = current; snapshot = nil; lastAttempt = .distantPast
        }
        guard Date().timeIntervalSince(lastAttempt) >= 120 else { return snapshot }
        lastAttempt = Date()
        let result = try? await GLMMonitorUsageService(apiKey: apiKey).fetch()
        guard fingerprint == current else { return nil }
        snapshot = result
        return result
    }
}

/// Account benefits have their own credential source and cache; API-key identity is unrelated.
private struct GLMBoundAccountBenefits: Sendable {
    let snapshot: GLMAccountBenefitsSnapshot
    let fingerprint: Data
}

private actor GLMAccountBenefitsCache {
    static let shared = GLMAccountBenefitsCache()
    private let service = GLMAccountBenefitsService()
    private var fingerprint: Data?
    private var lastAttempt = Date.distantPast
    private var snapshot: GLMAccountBenefitsSnapshot?

    func read() async -> GLMBoundAccountBenefits? {
        let enabled = (UserDefaults.standard.object(forKey: "glmReadZCodeBenefits") as? Bool) ?? true
        guard enabled, let current = service.credentialSelectionFingerprint() else {
            fingerprint = nil; snapshot = nil; lastAttempt = .distantPast
            return nil
        }
        if fingerprint != current {
            fingerprint = current; snapshot = nil; lastAttempt = .distantPast
        }
        guard Date().timeIntervalSince(lastAttempt) >= 60 else {
            return snapshot.map { GLMBoundAccountBenefits(snapshot: $0, fingerprint: current) }
        }
        lastAttempt = Date()
        let result = await service.fetch()
        guard fingerprint == current, service.credentialSelectionFingerprint() == current else {
            snapshot = nil; lastAttempt = .distantPast
            return nil
        }
        snapshot = result
        return result.map { GLMBoundAccountBenefits(snapshot: $0, fingerprint: current) }
    }

    /// Parallel API-key reads may finish later than a cached account read. Bind publication
    /// to the exact selection captured with that result, including every failure return path.
    func validate(_ read: GLMBoundAccountBenefits?) -> GLMAccountBenefitsSnapshot? {
        let enabled = (UserDefaults.standard.object(forKey: "glmReadZCodeBenefits") as? Bool) ?? true
        guard enabled, let read, fingerprint == read.fingerprint,
              service.credentialSelectionFingerprint() == read.fingerprint else { return nil }
        return read.snapshot
    }
}
