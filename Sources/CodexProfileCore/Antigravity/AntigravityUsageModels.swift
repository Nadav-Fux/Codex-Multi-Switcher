import Foundation

/// Which model family Antigravity assigned a quota bucket to.
public enum AntigravityQuotaFamily: String, Codable, Equatable, Sendable {
    case gemini
    case nonGemini
    case unknown
}

/// A quota window returned by Antigravity's read-only `/usage` command.
public struct AntigravityQuotaBucket: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier derived from the family and the CLI's window label.
    public let id: String
    /// The original family heading from the CLI, such as "Gemini Models".
    public let familyLabel: String
    public let family: AntigravityQuotaFamily
    /// The CLI's description of which models share this family quota.
    public let modelDescription: String?
    /// The original quota window label, such as "Weekly Limit Remaining".
    public let windowLabel: String
    /// The original machine-readable window from the CLI, such as "weekly" or "5h".
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
    case antigravityCLIUsageCommand
}

/// A live quota observation. `/usage` reports shared model-family buckets, remaining fractions,
/// and reset times; it does not report absolute quota amounts. Account provenance is bound to
/// the same local CLI ID-token issuer/subject observed before and after the request.
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
            return "Antigravity CLI was not found. Install or configure the official `agy` CLI, then refresh."
        case .accountUnavailable:
            return "The current Antigravity CLI sign-in could not be identified safely. Sign in with Antigravity, then refresh."
        case .accountChanged:
            return "The Antigravity CLI sign-in changed during quota refresh. Try again."
        case .unsupportedCLIVersion:
            return "This Antigravity CLI version cannot safely provide quotas without starting an agent turn. Update `agy`, then refresh."
        case .timedOut:
            return "Antigravity quota refresh timed out. Try again in a few minutes."
        case .commandFailed:
            return "Antigravity could not refresh quota data. Check the current Antigravity CLI sign-in, then try again."
        case .invalidResponse:
            return "Antigravity returned an unsupported quota response."
        case .noQuotaData:
            return "Antigravity did not return any model quota buckets for this sign-in."
        }
    }
}
