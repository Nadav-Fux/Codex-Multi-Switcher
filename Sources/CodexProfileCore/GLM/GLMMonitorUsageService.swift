import Foundation
import CoreFoundation

public struct GLMMonitorUsageSnapshot: Codable, Equatable, Sendable {
    public let subscription: GLMMonitorSubscription?
    public let modelUsage: GLMMonitorModelUsage?
    public let toolUsage: GLMMonitorToolUsage?
    public let observedAt: Date
    public let windowStart: Date
    public let windowEnd: Date

    public init(subscription: GLMMonitorSubscription?, modelUsage: GLMMonitorModelUsage?,
                toolUsage: GLMMonitorToolUsage?, observedAt: Date,
                windowStart: Date, windowEnd: Date) {
        self.subscription = subscription
        self.modelUsage = modelUsage
        self.toolUsage = toolUsage
        self.observedAt = observedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct GLMMonitorSubscription: Codable, Equatable, Sendable {
    public let productName: String
    /// Preserved exactly as returned by the service; it is not treated as an expiry date.
    public let nextRenewTime: String?
    public let billingCycle: String?
}

public struct GLMMonitorModelUsage: Codable, Equatable, Sendable {
    public let totalTokensUsage: Int?
    public let totalModelCallCount: Int?
    public let models: [GLMMonitorModelSummary]
}

public struct GLMMonitorModelSummary: Codable, Equatable, Sendable {
    public let modelName: String
    public let totalTokens: Int
}

public struct GLMMonitorToolUsage: Codable, Equatable, Sendable {
    public let totalNetworkSearchCount: Int?
    public let totalWebReadMcpCount: Int?
    public let totalZreadMcpCount: Int?
    public let totalSearchMcpCount: Int?
}

/// Reads optional Z.ai monitor enrichment with the explicitly supplied API key.
/// Failure of an individual endpoint leaves only that part of the snapshot unavailable.
public final class GLMMonitorUsageService: @unchecked Sendable {
    private let apiKey: String
    private let transport: any GLMMonitorTransport

    public init(apiKey: String, transport: any GLMMonitorTransport = GLMHTTPSQuotaTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func fetch(now: Date = Date()) async throws -> GLMMonitorUsageSnapshot {
        guard !self.apiKey.isEmpty, self.apiKey.utf8.count <= 65_536 else {
            throw GLMQuotaError.credentialUnavailable
        }
        let windowEnd = Self.roundedHour(now)
        let windowStart = windowEnd.addingTimeInterval(-24 * 60 * 60)

        async let subscriptionData = Self.optionalData(transport: self.transport, endpoint: .subscription,
                                                       key: self.apiKey)
        async let modelData = Self.optionalData(transport: self.transport,
                                                endpoint: .modelUsage(start: windowStart, end: windowEnd),
                                                key: self.apiKey)
        async let toolData = Self.optionalData(transport: self.transport,
                                               endpoint: .toolUsage(start: windowStart, end: windowEnd),
                                               key: self.apiKey)

        let (subscriptionBytes, modelBytes, toolBytes) = await (subscriptionData, modelData, toolData)
        let subscription = subscriptionBytes.flatMap(Self.parseSubscription)
        let modelUsage = modelBytes.flatMap(Self.parseModelUsage)
        let toolUsage = toolBytes.flatMap(Self.parseToolUsage)
        guard subscription != nil || modelUsage != nil || toolUsage != nil else {
            throw GLMQuotaError.requestFailed
        }
        return GLMMonitorUsageSnapshot(subscription: subscription, modelUsage: modelUsage,
                                       toolUsage: toolUsage, observedAt: now,
                                       windowStart: windowStart, windowEnd: windowEnd)
    }

    /// The monitor's timestamp timezone is unspecified. This window is deliberately rounded in UTC;
    /// consumers should show the UTC label rather than imply the service's own bucket timezone.
    public static func windowLabel(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private static func optionalData(transport: any GLMMonitorTransport,
                                     endpoint: GLMMonitorEndpoint, key: String) async -> Data? {
        try? await transport.get(endpoint, authorizationValue: key)
    }

    private static func roundedHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(seconds / 3_600) * 3_600)
    }

    private static func payload(_ data: Data) -> Any? {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let success = root["success"] {
            guard GLMSourceParser.isBoolean(success), (success as? NSNumber)?.boolValue == true else { return nil }
        }
        if let rawCode = root["code"] {
            guard let code = GLMSourceParser.integer(rawCode), code == 0 || code == 200 else { return nil }
        }
        return root["data"] ?? root
    }

    private static func parseSubscription(_ data: Data) -> GLMMonitorSubscription? {
        guard let value = payload(data) else { return nil }
        let items = value as? [[String: Any]] ?? (value as? [String: Any]).flatMap { $0["list"] as? [[String: Any]] }
        guard let items, items.count <= GLMSourceParser.maximumRows, let item = items.first(where: { row in
            let name = (row["productName"] as? String ?? "").lowercased()
            let productID = (row["productId"] as? String ?? "").lowercased()
            return (row["status"] as? String)?.uppercased() == "VALID"
                && (row["inCurrentPeriod"] as? Bool) == true
                && (name.contains("coding") || productID.contains("coding"))
        }), let name = GLMSourceParser.string(item["productName"]) else { return nil }
        let nextRenewTime = GLMSourceParser.string(item["nextRenewTime"])
        let billingCycle = GLMSourceParser.string(item["billingCycle"])
        return GLMMonitorSubscription(productName: name,
                                      nextRenewTime: nextRenewTime,
                                      billingCycle: billingCycle)
    }

    private static func parseModelUsage(_ data: Data) -> GLMMonitorModelUsage? {
        guard let root = payload(data) as? [String: Any] else { return nil }
        let total = root["totalUsage"] as? [String: Any] ?? [:]
        let rows = total["modelSummaryList"] as? [[String: Any]] ?? root["modelSummaryList"] as? [[String: Any]] ?? []
        guard rows.count <= GLMSourceParser.maximumRows else { return nil }
        let models = rows.compactMap { row -> GLMMonitorModelSummary? in
                guard let name = GLMSourceParser.string(row["modelName"]),
                      let tokens = Self.integer(row["totalTokens"]) else { return nil }
                return GLMMonitorModelSummary(modelName: name, totalTokens: tokens)
            }
        guard !total.isEmpty || !models.isEmpty else { return nil }
        return GLMMonitorModelUsage(totalTokensUsage: Self.integer(total["totalTokensUsage"]),
                                    totalModelCallCount: Self.integer(total["totalModelCallCount"]),
                                    models: models)
    }

    private static func parseToolUsage(_ data: Data) -> GLMMonitorToolUsage? {
        guard let root = payload(data) as? [String: Any],
              let total = root["totalUsage"] as? [String: Any] else { return nil }
        return GLMMonitorToolUsage(totalNetworkSearchCount: Self.integer(total["totalNetworkSearchCount"]),
                                   totalWebReadMcpCount: Self.integer(total["totalWebReadMcpCount"]),
                                   totalZreadMcpCount: Self.integer(total["totalZreadMcpCount"]),
                                   totalSearchMcpCount: Self.integer(total["totalSearchMcpCount"]))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue <= 1_000_000_000_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}
