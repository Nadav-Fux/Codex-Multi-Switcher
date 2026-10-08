import Foundation

public enum GLMCodingPlanKind: String, Equatable, Sendable {
    case individual
    case team
}

public enum GLMQuotaSource: String, Equatable, Sendable {
    case zCodeCodingPlan
    case explicitCodingPlanKey
}

/// A quota observation returned by Z.ai's Coding Plan usage endpoint.
/// Percentages represent usage, matching the endpoint's `percentage` field.
public struct GLMQuotaWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?
    public var remainingPercentage: Double { max(0, 100 - self.usedPercentage) }

    public init(usedPercentage: Double, resetsAt: Date? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// Missing windows stay nil when Z.ai does not return a recognized quota bucket.
public struct GLMQuotaSnapshot: Equatable, Sendable {
    public let fiveHour: GLMQuotaWindow?
    public let weekly: GLMQuotaWindow?
    public let monthlyTool: GLMQuotaWindow?
    public let observedAt: Date
    public let source: GLMQuotaSource
    public let planKind: GLMCodingPlanKind
    /// The request succeeded and its ZCode credential scope remained unchanged for the request.
    /// Z.ai's quota endpoint does not return an account identity.
    public let accountVerified: Bool

    public init(fiveHour: GLMQuotaWindow?, weekly: GLMQuotaWindow?, monthlyTool: GLMQuotaWindow?,
                observedAt: Date, source: GLMQuotaSource = .zCodeCodingPlan,
                planKind: GLMCodingPlanKind, accountVerified: Bool = false) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthlyTool = monthlyTool
        self.observedAt = observedAt
        self.source = source
        self.planKind = planKind
        self.accountVerified = accountVerified
    }
}

public enum GLMQuotaError: LocalizedError, Equatable {
    case unsupportedPlan
    case credentialUnavailable
    case encryptedCredentialUnsupported
    case credentialRejected
    case accountChanged
    case invalidResponse
    case quotaUnavailable
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlan:
            return "Automatic quota is available for a selected Z.ai Coding Plan in ZCode."
        case .credentialUnavailable:
            return "ZCode's Coding Plan credential could not be read safely. Open ZCode, then refresh."
        case .encryptedCredentialUnsupported:
            return "ZCode stores account credentials encrypted. Add a personal Coding Plan API key explicitly to read GLM quota."
        case .credentialRejected:
            return "Z.ai rejected the current Coding Plan credential. Open ZCode and reconnect the plan."
        case .accountChanged:
            return "The selected ZCode Coding Plan changed during the quota refresh. Refresh again."
        case .invalidResponse:
            return "Z.ai returned an unsupported Coding Plan quota response."
        case .quotaUnavailable:
            return "Z.ai returned no Coding Plan quota windows for this key. Check the plan and key, or try refreshing later."
        case .requestFailed:
            return "Current GLM Coding Plan quota could not be fetched. Try refreshing again in a few minutes."
        }
    }
}
