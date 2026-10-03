import CodexProfileCore
import Foundation

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
        do {
            guard let key = try GLMCredentialStore.load() else {
                return ProviderUsageSnapshot(provider: providerID, source: "Z.ai Coding Plan quota",
                    state: .error(.credentialAccessUnsupported))
            }
            let service = GLMCodingPlanUsageService(apiKey: key, planKind: .individual)
            let usage = try await service.fetch()
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
                plan: ProviderPlan(name: usage.planKind == .individual ? "Personal Coding Plan" : "Team Coding Plan"),
                buckets: buckets, observedAt: usage.observedAt,
                source: "Z.ai Coding Plan quota · app Keychain key",
                accountVerified: usage.accountVerified)
        } catch {
            let state: ProviderSnapshotState
            switch error as? GLMQuotaError {
            case .credentialUnavailable: state = .signedOut
            case .credentialRejected: state = .error(.authenticationRequired)
            case .unsupportedPlan: state = .error(.unsupported)
            case .encryptedCredentialUnsupported: state = .error(.credentialAccessUnsupported)
            case .invalidResponse: state = .error(.malformedResponse)
            case .accountChanged: state = .error(.authenticationRequired)
            default: state = .error(.networkUnavailable)
            }
            return ProviderUsageSnapshot(provider: providerID, source: "Z.ai Coding Plan quota", state: state)
        }
    }
}
