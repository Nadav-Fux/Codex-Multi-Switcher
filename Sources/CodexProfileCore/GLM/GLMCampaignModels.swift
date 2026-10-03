import Foundation

/// Published ZCode campaign/reward fields from `CodingPlanCampaignDiscountDetail`.
/// The official schema does not define a boost coefficient or a coefficient time window.
public struct GLMCampaignDiscount: Codable, Equatable, Sendable {
    public let campaignName: String?
    public let campaignDiscountAmount: Double?
    public let rewardMode: String?
    public let rewardAmount: Double?
    public let rewardDetail: String?
    public let applyScene: String?

    public init(campaignName: String? = nil, campaignDiscountAmount: Double? = nil,
                rewardMode: String? = nil, rewardAmount: Double? = nil,
                rewardDetail: String? = nil, applyScene: String? = nil) {
        self.campaignName = campaignName
        self.campaignDiscountAmount = campaignDiscountAmount
        self.rewardMode = rewardMode
        self.rewardAmount = rewardAmount
        self.rewardDetail = rewardDetail
        self.applyScene = applyScene
    }

    /// Parses an array using the exact published ZCode campaign detail field names.
    public static func parse(_ data: Data) -> [Self]? {
        guard data.count <= GLMSourceParser.maximumPayloadBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let rows = value as? [[String: Any]], rows.count <= GLMSourceParser.maximumRows else { return nil }
        var result: [Self] = []
        for row in rows {
            for key in ["campaignName", "rewardMode", "rewardDetail", "applyScene"] {
                if let raw = row[key], !(raw is NSNull), GLMSourceParser.string(raw) == nil { return nil }
            }
            for key in ["campaignDiscountAmount", "rewardAmount"] {
                if let raw = row[key], !(raw is NSNull), GLMSourceParser.number(raw) == nil { return nil }
            }
            result.append(Self(campaignName: GLMSourceParser.string(row["campaignName"]),
                               campaignDiscountAmount: GLMSourceParser.number(row["campaignDiscountAmount"]),
                               rewardMode: GLMSourceParser.string(row["rewardMode"]),
                               rewardAmount: GLMSourceParser.number(row["rewardAmount"]),
                               rewardDetail: GLMSourceParser.string(row["rewardDetail"]),
                               applyScene: GLMSourceParser.string(row["applyScene"])))
        }
        return result
    }
}
