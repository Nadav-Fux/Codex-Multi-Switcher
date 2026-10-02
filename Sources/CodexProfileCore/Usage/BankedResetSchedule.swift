import Foundation

public enum BankedResetScheduleMode: String, Codable, CaseIterable, Sendable {
    case atDate
    case beforeExpiry
}

/// One explicit credit, one durable idempotency key. A retry can never spend
/// the next credit simply because the selected credit has disappeared.
public struct BankedResetSchedule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(profileID):\(creditID)" }
    public let profileID: String
    public let creditID: String
    public var accountFingerprint: String
    public var accountClaimFingerprints: [String: String]?
    public var mode: BankedResetScheduleMode
    public var scheduledAt: Date
    public var hoursBeforeExpiry: Int
    public var enabled: Bool
    public var idempotencyKey: String
    public var lastAttemptAt: Date?
    public var retryAfter: Date?
    public var completedAt: Date?
    public var creditExpiresAt: Date?
    public var automaticallyRetryNoOp: Bool?
    public var lastOutcome: String?
    public var lastError: String?

    public init(profileID: String, creditID: String, accountFingerprint: String,
                mode: BankedResetScheduleMode, scheduledAt: Date,
                hoursBeforeExpiry: Int = 24, enabled: Bool = true,
                idempotencyKey: String = UUID().uuidString, creditExpiresAt: Date? = nil, automaticallyRetryNoOp: Bool = true, accountClaimFingerprints: [String: String]? = nil) {
        self.profileID = profileID
        self.creditID = creditID
        self.accountFingerprint = accountFingerprint
        self.accountClaimFingerprints = accountClaimFingerprints
        self.mode = mode
        self.scheduledAt = scheduledAt
        self.hoursBeforeExpiry = min(720, max(1, hoursBeforeExpiry))
        self.enabled = enabled
        self.idempotencyKey = idempotencyKey
        self.creditExpiresAt = creditExpiresAt
        self.automaticallyRetryNoOp = automaticallyRetryNoOp
    }

    public func matchesAccount(authData: Data) -> Bool {
        if let claims = self.accountClaimFingerprints {
            return AuthBlob.identityMatches(authData, claimFingerprints: claims)
        }
        return AuthBlob.identityFingerprint(from: authData) == self.accountFingerprint
    }

    public func triggerDate(expiresAt: Date?) -> Date? {
        switch self.mode {
        case .atDate: return self.scheduledAt
        case .beforeExpiry:
            return (expiresAt ?? self.creditExpiresAt)?.addingTimeInterval(-TimeInterval(self.hoursBeforeExpiry) * 3600)
        }
    }

    public func isDue(expiresAt: Date?, now: Date) -> Bool {
        guard self.enabled, self.completedAt == nil,
              let trigger = self.triggerDate(expiresAt: expiresAt), trigger <= now,
              self.retryAfter.map({ $0 <= now }) ?? true else { return false }
        return true
    }
}
