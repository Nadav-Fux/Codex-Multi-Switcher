import Foundation
import CoreFoundation

/// ZCode's explicit account-access scope. These are scope identifiers, not a user identity.
/// The reset and balance APIs do not return an account email or stable account ID.
public struct GLMAccountScope: Codable, Equatable, Sendable {
    public enum Family: String, Codable, Sendable { case zai, bigmodel }
    public enum PlanKind: String, Codable, Sendable {
        case startPlan = "start-plan"
        case individualCodingPlan = "individual-coding-plan"
        case teamCodingPlan = "team-coding-plan"
    }

    public let family: Family
    public let planKind: PlanKind
    public let productID: String?
    public let organizationID: String?
    public let projectID: String?

    public init(family: Family, planKind: PlanKind, productID: String? = nil,
                organizationID: String? = nil, projectID: String? = nil) {
        self.family = family
        self.planKind = planKind
        self.productID = productID
        self.organizationID = organizationID
        self.projectID = projectID
    }
}

/// Normalized, non-secret account benefits. `accountVerified` is supplied by the caller after
/// verifying the selected account remained unchanged across the request.
public struct GLMAccountBenefitsSnapshot: Codable, Equatable, Sendable {
    public let resetStatus: GLMCodingPlanResetStatus?
    public let startPlan: GLMStartPlanBenefits?
    public let startPlanUnavailableReason: String?
    public let campaignDiscounts: [GLMCampaignDiscount]?
    public let sourceObservedAt: Date
    public let account: GLMAccountScope
    public let accountVerified: Bool

    public init(resetStatus: GLMCodingPlanResetStatus? = nil, startPlan: GLMStartPlanBenefits? = nil,
                startPlanUnavailableReason: String? = nil,
                campaignDiscounts: [GLMCampaignDiscount]? = nil, sourceObservedAt: Date,
                account: GLMAccountScope, accountVerified: Bool) {
        self.resetStatus = resetStatus
        self.startPlan = startPlan
        self.startPlanUnavailableReason = startPlanUnavailableReason
        self.campaignDiscounts = campaignDiscounts
        self.sourceObservedAt = sourceObservedAt
        self.account = account
        self.accountVerified = accountVerified
    }
}

enum GLMSourceParser {
    static let maximumPayloadBytes = 1_048_576
    static let maximumRows = 200
    static let maximumStringLength = 512

    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= maximumPayloadBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func number(_ value: Any?) -> Double? {
        guard let value, !isBoolean(value), let number = value as? NSNumber,
              number.doubleValue.isFinite, (0...1_000_000_000_000_000).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    static func units(_ value: Any?) -> Double? {
        if let number = number(value) { return number }
        if let string = value as? String, string.utf8.count <= 64,
           let parsed = Double(string), parsed.isFinite,
           (0...1_000_000_000_000_000).contains(parsed) { return parsed }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= maximumStringLength else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ZCode Start Plan timestamps are seconds; reset-card timestamps are milliseconds.
    static func date(_ value: Any?, milliseconds: Bool = false) -> Date? {
        guard let number = number(value) else { return nil }
        let seconds = milliseconds ? number / 1_000 : number
        // Bound absolute dates before Date construction. This rejects corrupt/non-finite or
        // implausibly distant timestamps without discarding legitimate expired records.
        guard seconds >= 946_684_800, seconds <= 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func envelopeData(_ root: [String: Any]) -> [String: Any]? {
        if let success = root["success"] {
            guard isBoolean(success), (success as? NSNumber)?.boolValue == true else { return nil }
        }
        if let rawCode = root["code"] {
            guard let code = integer(rawCode), code == 0 || code == 200 else { return nil }
        }
        return root["data"] as? [String: Any]
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value, !isBoolean(value) else { return nil }
        if let number = value as? NSNumber, number.doubleValue.isFinite,
           number.doubleValue.rounded(.towardZero) == number.doubleValue,
           number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) {
            return number.intValue
        }
        if let string = value as? String, string.utf8.count <= 16 { return Int(string) }
        return nil
    }
}
