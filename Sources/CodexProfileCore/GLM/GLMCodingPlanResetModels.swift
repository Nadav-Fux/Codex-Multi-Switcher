import Foundation

public struct GLMCodingPlanResetOpportunity: Codable, Equatable, Sendable {
    /// Expiry of this issued reset opportunity (not a quota refill/reset time).
    public let expiresAt: Date
    public init(expiresAt: Date) { self.expiresAt = expiresAt }
}

public struct GLMCodingPlanResetHistory: Codable, Equatable, Sendable {
    public let usedAt: Date
    public init(usedAt: Date) { self.usedAt = usedAt }
}

public struct GLMCodingPlanResetStatus: Codable, Equatable, Sendable {
    public let availableFiveHourResets: [GLMCodingPlanResetOpportunity]
    public let availableWeekResets: [GLMCodingPlanResetOpportunity]
    public let latestFiveHourResetHistory: GLMCodingPlanResetHistory?
    public let latestWeekResetHistory: GLMCodingPlanResetHistory?
    public let hasUnreadHistory: Bool
    public let sourceObservedAt: Date

    public init(availableFiveHourResets: [GLMCodingPlanResetOpportunity],
                availableWeekResets: [GLMCodingPlanResetOpportunity],
                latestFiveHourResetHistory: GLMCodingPlanResetHistory?,
                latestWeekResetHistory: GLMCodingPlanResetHistory?,
                hasUnreadHistory: Bool, sourceObservedAt: Date) {
        self.availableFiveHourResets = availableFiveHourResets
        self.availableWeekResets = availableWeekResets
        self.latestFiveHourResetHistory = latestFiveHourResetHistory
        self.latestWeekResetHistory = latestWeekResetHistory
        self.hasUnreadHistory = hasUnreadHistory
        self.sourceObservedAt = sourceObservedAt
    }

    /// Parses the official ZCode reset-status response shape. This performs no network or auth work.
    public static func parse(_ data: Data, sourceObservedAt: Date = Date()) -> Self? {
        guard let root = GLMSourceParser.object(data),
              let payload = GLMSourceParser.envelopeData(root),
              let five = payload["available_five_hour_resets"] as? [[String: Any]], five.count <= GLMSourceParser.maximumRows,
              let week = payload["available_week_resets"] as? [[String: Any]], week.count <= GLMSourceParser.maximumRows,
              let unreadValue = payload["has_unread_history"], GLMSourceParser.isBoolean(unreadValue),
              let unread = (unreadValue as? NSNumber)?.boolValue,
              let fiveHistory = history(payload["latest_five_hour_reset_history"]),
              let weekHistory = history(payload["latest_week_reset_history"]) else { return nil }

        guard let fiveItems = opportunities(five), let weekItems = opportunities(week) else { return nil }
        return Self(availableFiveHourResets: fiveItems, availableWeekResets: weekItems,
                    latestFiveHourResetHistory: fiveHistory, latestWeekResetHistory: weekHistory,
                    hasUnreadHistory: unread, sourceObservedAt: sourceObservedAt)
    }

    private static func opportunities(_ rows: [[String: Any]]) -> [GLMCodingPlanResetOpportunity]? {
        var result: [GLMCodingPlanResetOpportunity] = []
        for row in rows {
            guard let raw = row["expire_at"], let date = GLMSourceParser.date(raw, milliseconds: true) else { return nil }
            result.append(GLMCodingPlanResetOpportunity(expiresAt: date))
        }
        return result
    }

    private static func history(_ value: Any?) -> GLMCodingPlanResetHistory?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        guard let row = value as? [String: Any], let raw = row["used_at"],
              let date = GLMSourceParser.date(raw, milliseconds: true) else { return nil }
        return .some(GLMCodingPlanResetHistory(usedAt: date))
    }
}
