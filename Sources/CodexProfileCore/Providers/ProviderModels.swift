import Foundation

/// Stable identifiers for providers supported by the shared usage model.
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case antigravity
    case glm

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .glm: return "GLM / Z.ai"
        }
    }

    /// A plain-text symbol name, so this core model has no UI-framework dependency.
    public var symbolName: String {
        switch self {
        case .codex: return "sparkles"
        case .claude: return "brain"
        case .antigravity: return "arrow.up.right"
        case .glm: return "globe.asia.australia"
        }
    }
}

/// Non-secret account identity that is safe to present in the UI.
public struct ProviderAccount: Codable, Equatable, Sendable {
    public let displayName: String?
    public let email: String?
    public let accountID: String?

    public init(displayName: String? = nil, email: String? = nil, accountID: String? = nil) {
        self.displayName = displayName
        self.email = email
        self.accountID = accountID
    }
}

/// A provider's user-facing plan label; it never contains authentication data.
public struct ProviderPlan: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// Describes how a usage bucket is grouped for presentation and comparison.
public enum ProviderUsageBucketGroup: String, Codable, Sendable {
    /// Gemini model quota, useful for distinguishing Antigravity's Gemini pool.
    case gemini
    /// A provider-specific pool for non-Gemini models.
    case other
    /// A general pool when the provider does not report model categories.
    case general
}

/// One quota window or pool. `remainingFraction` is in the inclusive range 0...1
/// when known, and nil when the provider does not report remaining capacity.
public struct ProviderUsageBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let remainingFraction: Double?
    public let resetAt: Date?
    public let group: ProviderUsageBucketGroup

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        remainingFraction: Double? = nil,
        resetAt: Date? = nil,
        group: ProviderUsageBucketGroup = .general
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        if let remainingFraction,
           remainingFraction.isFinite,
           (0 ... 1).contains(remainingFraction) {
            self.remainingFraction = remainingFraction
        } else {
            self.remainingFraction = nil
        }
        self.resetAt = resetAt
        self.group = group
    }
}

/// Categorized read failures avoid carrying raw responses or credential material.
public enum ProviderSnapshotError: String, Codable, Sendable {
    case authenticationRequired
    case credentialAccessUnsupported
    case rateLimited
    case networkUnavailable
    case malformedResponse
    case unsupported
    case unknown
}

public enum ProviderSnapshotState: Codable, Equatable, Sendable {
    case available
    case signedOut
    case unavailable
    case error(ProviderSnapshotError)
}

/// A portable, normalized view of provider status and quota information.
/// Credentials, tokens, cookies, and raw authentication payloads must never be
/// placed in this value or persisted through it.
public struct ProviderUsageSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let account: ProviderAccount?
    public let plan: ProviderPlan?
    public let buckets: [ProviderUsageBucket]
    public let fetchedAt: Date
    /// Time the provider's underlying usage observation was made, when known.
    /// May be earlier than `fetchedAt` when a provider returns cached data.
    public let observedAt: Date?
    public let source: String
    public let state: ProviderSnapshotState
    public let accountVerified: Bool
    public let isStale: Bool

    public init(
        provider: ProviderID,
        account: ProviderAccount? = nil,
        plan: ProviderPlan? = nil,
        buckets: [ProviderUsageBucket] = [],
        fetchedAt: Date = Date(),
        observedAt: Date? = nil,
        source: String,
        state: ProviderSnapshotState = .available,
        accountVerified: Bool = false,
        isStale: Bool = false
    ) {
        self.provider = provider
        self.account = account
        self.plan = plan
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.observedAt = observedAt
        self.source = source
        self.state = state
        self.accountVerified = accountVerified
        self.isStale = isStale
    }

    /// Whether this observation is recent enough to present as current.
    /// Missing observation timestamps are conservatively treated as unverified.
    public func isCurrent(at now: Date = Date(), maxAge: TimeInterval = 180) -> Bool {
        guard !self.isStale, self.accountVerified, let observedAt = self.observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -30 && age <= max(0, maxAge)
    }
}
