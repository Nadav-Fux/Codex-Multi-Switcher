import Foundation

/// Which model family Antigravity assigned a quota bucket to.
public enum AntigravityQuotaFamily: String, Codable, Equatable, Sendable {
    case gemini
    case nonGemini
    case unknown
}

/// A quota window returned by Antigravity's read-only quota API.
public struct AntigravityQuotaBucket: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier derived from the family and the service's window label.
    public let id: String
    /// The original family heading from the service, such as "Gemini Models".
    public let familyLabel: String
    public let family: AntigravityQuotaFamily
    /// The service's description of which models share this family quota.
    public let modelDescription: String?
    /// The original quota window label, such as "Weekly Limit Remaining".
    public let windowLabel: String
    /// The original machine-readable window from the service, such as "weekly" or "5h".
    public let window: String
    /// Remaining fraction as directly reported by Antigravity, in the range 0...1.
    public let remainingFraction: Double
    /// Percent is only a unit conversion of the reported fraction.
    public var remainingPercent: Double { self.remainingFraction * 100 }
    /// Reset instant returned by Antigravity.
    public let resetsAt: Date

    public init(id: String, familyLabel: String, family: AntigravityQuotaFamily,
                modelDescription: String? = nil, windowLabel: String,
                window: String, remainingFraction: Double, resetsAt: Date) {
        self.id = id
        self.familyLabel = familyLabel
        self.family = family
        self.modelDescription = modelDescription
        self.windowLabel = windowLabel
        self.window = window
        self.remainingFraction = remainingFraction
        self.resetsAt = resetsAt
    }
}

public enum AntigravityUsageSource: String, Codable, Equatable, Sendable {
    case antigravityCLIUsageCommand // Retained for decoding older snapshots.
    case quotaSummaryAPI
}

/// A live quota observation of shared model-family buckets, fractions, and reset times.
/// The server-verified helper account must match local CLI identity before and after the read.
public struct AntigravityUsageSnapshot: Codable, Equatable, Sendable {
    public let buckets: [AntigravityQuotaBucket]
    public let observedAt: Date
    public let source: AntigravityUsageSource
    /// Describes the credential context used without claiming an identity the CLI did not return.
    public let accountProvenance: String
    /// A pseudonymous identity derived from the current CLI ID token's issuer and subject.
    public let accountIdentity: String?
    /// True only when the same cached CLI identity was observed before and after the request.
    public let accountVerified: Bool

    public init(buckets: [AntigravityQuotaBucket], observedAt: Date,
                source: AntigravityUsageSource = .antigravityCLIUsageCommand,
                accountProvenance: String = "Current Antigravity CLI sign-in; identity matched before and after refresh",
                accountIdentity: String?, accountVerified: Bool = true) {
        self.buckets = buckets
        self.observedAt = observedAt
        self.source = source
        self.accountProvenance = accountProvenance
        self.accountIdentity = accountIdentity
        self.accountVerified = accountVerified
    }
}

public enum AntigravityUsageError: LocalizedError, Equatable {
    case cliMissing
    case accountUnavailable
    case accountChanged
    case unsupportedCLIVersion
    case timedOut
    case commandFailed
    case invalidResponse
    case noQuotaData

    public var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "The existing antigravity-usage helper or Node runtime was not found. Restore the statusline helper, then refresh."
        case .accountUnavailable:
            return "A matching Antigravity sign-in and antigravity-usage helper account are required. Check the existing connections, then refresh."
        case .accountChanged:
            return "The Antigravity CLI sign-in changed during quota refresh. Try again."
        case .unsupportedCLIVersion:
            return "This Antigravity CLI version cannot safely provide quotas without starting an agent turn. Update `agy`, then refresh."
        case .timedOut:
            return "Antigravity quota refresh timed out. Try again in a few minutes."
        case .commandFailed:
            return "Antigravity could not refresh quota data. Check the existing antigravity-usage connection, then try again."
        case .invalidResponse:
            return "Antigravity returned an unsupported quota response."
        case .noQuotaData:
            return "Antigravity did not return any model quota buckets for this sign-in."
        }
    }
}
