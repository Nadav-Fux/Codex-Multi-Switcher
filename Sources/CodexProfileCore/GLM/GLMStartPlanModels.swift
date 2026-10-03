import Foundation

public struct GLMStartPlanEntitlement: Codable, Equatable, Sendable {
    public let entitlementID: String?
    public let showName: String?
    public let period: String?
    public let effectiveAt: Date?
}

public struct GLMStartPlanSubscription: Codable, Equatable, Sendable {
    public let userPlanID: String?
    public let planID: String?
    public let name: String?
    public let status: String?
    public let startsAt: Date?
    public let endsAt: Date?
    public let entitlements: [GLMStartPlanEntitlement]?
}

/// A Start Plan quota bucket. `remainingUnits` follows ZCode's balance field; `availableUnits`
/// is kept separate because ZCode defines it as the amount after in-flight reservations.
public struct GLMStartPlanBalance: Codable, Equatable, Sendable {
    public let bucketID: String?
    public let userPlanID: String?
    public let planID: String?
    public let entitlementID: String?
    public let showName: String?
    public let meter: String?
    public let unitType: String?
    public let capabilities: [String]?
    public let totalUnits: Double?
    public let usedUnits: Double?
    public let reservedUnits: Double?
    public let remainingUnits: Double?
    public let availableUnits: Double?
    public let periodStart: Date?
    public let periodEnd: Date?
    /// Expiry of this quota bucket, which ZCode also maps to the bucket's next reset time.
    public let expiresAt: Date?
}

public struct GLMStartPlanBenefits: Codable, Equatable, Sendable {
    public let serverTime: Date?
    public let plans: [GLMStartPlanSubscription]
    public let balances: [GLMStartPlanBalance]
    public let sourceObservedAt: Date

    public init(serverTime: Date?, plans: [GLMStartPlanSubscription], balances: [GLMStartPlanBalance],
                sourceObservedAt: Date) {
        self.serverTime = serverTime
        self.plans = plans
        self.balances = balances
        self.sourceObservedAt = sourceObservedAt
    }

    /// Parses the official ZCode Start Plan balance envelope. Retains the reported units; presentation can derive a ratio only from valid remaining and total units.
    public static func parse(_ data: Data, observedAt: Date = Date()) -> Self? {
        guard let root = GLMSourceParser.object(data),
              let payload = GLMSourceParser.envelopeData(root) else { return nil }
        if let raw = payload["plans"], !(raw is [[String: Any]]) { return nil }
        if let raw = payload["balances"], !(raw is [[String: Any]]) { return nil }
        let rawPlans = payload["plans"] as? [[String: Any]] ?? []
        let rawBalances = payload["balances"] as? [[String: Any]] ?? []
        guard rawPlans.count <= GLMSourceParser.maximumRows,
              rawBalances.count <= GLMSourceParser.maximumRows,
              let plans = rawPlansValue(rawPlans), let balances = rawBalancesValue(rawBalances) else { return nil }

        let serverTime = date(payload["server_time"])
        return Self(serverTime: serverTime, plans: plans, balances: balances,
                    sourceObservedAt: serverTime ?? observedAt)
    }

    private static func rawPlansValue(_ rows: [[String: Any]]) -> [GLMStartPlanSubscription]? {
        var result: [GLMStartPlanSubscription] = []
        for row in rows {
            let rawEntitlements = row["entitlements"] as? [[String: Any]]
            if let raw = row["entitlements"], !(raw is NSNull), rawEntitlements == nil { return nil }
            guard rawEntitlements == nil || rawEntitlements!.count <= GLMSourceParser.maximumRows else { return nil }
            let entitlements = rawEntitlements?.compactMap { item -> GLMStartPlanEntitlement? in
                // All fields in this source shape are optional; reject malformed supplied values.
                if let raw = item["effective_at"], !(raw is NSNull), date(raw) == nil { return nil }
                for key in ["entitlement_id", "show_name", "period"] {
                    if let raw = item[key], !(raw is NSNull), GLMSourceParser.string(raw) == nil { return nil }
                }
                return GLMStartPlanEntitlement(entitlementID: GLMSourceParser.string(item["entitlement_id"]),
                                               showName: GLMSourceParser.string(item["show_name"]),
                                               period: GLMSourceParser.string(item["period"]),
                                               effectiveAt: date(item["effective_at"]))
            }
            if let rawEntitlements, entitlements?.count != rawEntitlements.count { return nil }
            for key in ["user_plan_id", "plan_id", "name", "status"] {
                if let raw = row[key], !(raw is NSNull), GLMSourceParser.string(raw) == nil { return nil }
            }
            for key in ["starts_at", "ends_at"] {
                if let raw = row[key], !(raw is NSNull), date(raw) == nil { return nil }
            }
            result.append(GLMStartPlanSubscription(userPlanID: GLMSourceParser.string(row["user_plan_id"]),
                                                   planID: GLMSourceParser.string(row["plan_id"]),
                                                   name: GLMSourceParser.string(row["name"]),
                                                   status: GLMSourceParser.string(row["status"]),
                                                   startsAt: date(row["starts_at"]), endsAt: date(row["ends_at"]),
                                                   entitlements: entitlements))
        }
        return result
    }

    private static func rawBalancesValue(_ rows: [[String: Any]]) -> [GLMStartPlanBalance]? {
        var result: [GLMStartPlanBalance] = []
        for row in rows {
            for key in ["bucket_id", "user_plan_id", "plan_id", "entitlement_id", "show_name", "meter", "unit_type"] {
                if let raw = row[key], !(raw is NSNull), GLMSourceParser.string(raw) == nil { return nil }
            }
            let rawCapabilities = row["capabilities"] as? [Any]
            if let raw = row["capabilities"], !(raw is NSNull), rawCapabilities == nil { return nil }
            guard rawCapabilities == nil || rawCapabilities!.count <= GLMSourceParser.maximumRows else { return nil }
            let capabilities = rawCapabilities?.compactMap { GLMSourceParser.string($0) }
            if let rawCapabilities, capabilities?.count != rawCapabilities.count { return nil }

            let quantities = ["total_units", "used_units", "reserved_units", "remaining_units", "available_units"]
                .map { key -> Double?? in
                    guard let raw = row[key], !(raw is NSNull) else { return .some(nil) }
                    guard let value = GLMSourceParser.units(raw) else { return nil }
                    return .some(value)
                }
            guard quantities.count == 5, quantities.allSatisfy({ $0 != nil }) else { return nil }
            for key in ["period_start", "period_end", "expires_at"] {
                if let raw = row[key], !(raw is NSNull), date(raw) == nil { return nil }
            }
            result.append(GLMStartPlanBalance(bucketID: GLMSourceParser.string(row["bucket_id"]),
                                              userPlanID: GLMSourceParser.string(row["user_plan_id"]),
                                              planID: GLMSourceParser.string(row["plan_id"]),
                                              entitlementID: GLMSourceParser.string(row["entitlement_id"]),
                                              showName: GLMSourceParser.string(row["show_name"]),
                                              meter: GLMSourceParser.string(row["meter"]),
                                              unitType: GLMSourceParser.string(row["unit_type"]),
                                              capabilities: capabilities,
                                              totalUnits: quantities[0]!, usedUnits: quantities[1]!,
                                              reservedUnits: quantities[2]!, remainingUnits: quantities[3]!,
                                              availableUnits: quantities[4]!, periodStart: date(row["period_start"]),
                                              periodEnd: date(row["period_end"]), expiresAt: date(row["expires_at"])))
        }
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let date = GLMSourceParser.date(value) { return date }
        if let string = value as? String, string.utf8.count <= 64,
           let seconds = Double(string), seconds.isFinite {
            return GLMSourceParser.date(NSNumber(value: seconds))
        }
        return nil
    }
}
