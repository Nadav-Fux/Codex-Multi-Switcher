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
    /// Optional so records written before minute precision decode as zero minutes.
    public var minutesBeforeExpiry: Int?
    public var enabled: Bool
    public var idempotencyKey: String
    public var lastAttemptAt: Date?
    public var retryAfter: Date?
    public var completedAt: Date?
    public var creditExpiresAt: Date?
    public var automaticallyRetryNoOp: Bool?
    public var lastOutcome: String?
    public var lastError: String?

    public var effectiveMinutesBeforeExpiry: Int {
        guard (0...720).contains(self.hoursBeforeExpiry),
              (0...59).contains(self.minutesBeforeExpiry ?? 0) else { return 0 }
        return self.hoursBeforeExpiry * 60 + (self.minutesBeforeExpiry ?? 0)
    }

    public var hasValidBeforeExpiryOffset: Bool {
        (0...720).contains(self.hoursBeforeExpiry)
            && (0...59).contains(self.minutesBeforeExpiry ?? 0)
            && (1...(720 * 60)).contains(self.effectiveMinutesBeforeExpiry)
    }

    public init(profileID: String, creditID: String, accountFingerprint: String,
                mode: BankedResetScheduleMode, scheduledAt: Date,
                hoursBeforeExpiry: Int = 24, minutesBeforeExpiry: Int? = nil, enabled: Bool = true,
                idempotencyKey: String = UUID().uuidString, creditExpiresAt: Date? = nil, automaticallyRetryNoOp: Bool = true, accountClaimFingerprints: [String: String]? = nil) {
        self.profileID = profileID
        self.creditID = creditID
        self.accountFingerprint = accountFingerprint
        self.accountClaimFingerprints = accountClaimFingerprints
        self.mode = mode
        self.scheduledAt = scheduledAt
        // Keep the old initializer's 1...720 hour behavior when callers do
        // not provide minutes. New minute-precision schedules can use 0 hours.
        self.hoursBeforeExpiry = min(720, max(minutesBeforeExpiry == nil ? 1 : 0, hoursBeforeExpiry))
        self.minutesBeforeExpiry = minutesBeforeExpiry.map { min(59, max(0, $0)) }
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
            guard self.hasValidBeforeExpiryOffset else { return nil }
            return (expiresAt ?? self.creditExpiresAt)?.addingTimeInterval(-TimeInterval(self.effectiveMinutesBeforeExpiry) * 60)
        }
    }

    public func isDue(expiresAt: Date?, now: Date) -> Bool {
        guard self.enabled, self.completedAt == nil,
              let trigger = self.triggerDate(expiresAt: expiresAt), trigger <= now,
              self.retryAfter.map({ $0 <= now }) ?? true else { return false }
        return true
    }
}
