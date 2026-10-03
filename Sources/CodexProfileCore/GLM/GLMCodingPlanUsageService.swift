import Foundation

public protocol GLMQuotaTransport: Sendable {
    func quota(authorizationValue: String) async throws -> Data
}

/// The quota monitor and its companion read-only monitor endpoints share one bounded HTTPS transport.
public protocol GLMMonitorTransport: Sendable {
    func get(_ endpoint: GLMMonitorEndpoint, authorizationValue: String) async throws -> Data
}

public enum GLMMonitorEndpoint: Sendable {
    case subscription
    case modelUsage(start: Date, end: Date)
    case toolUsage(start: Date, end: Date)

    fileprivate var pathAndQuery: String {
        switch self {
        case .subscription:
            return "/api/biz/subscription/list"
        case let .modelUsage(start, end):
            return "/api/monitor/usage/model-usage" + Self.query(start: start, end: end)
        case let .toolUsage(start, end):
            return "/api/monitor/usage/tool-usage" + Self.query(start: start, end: end)
        }
    }

    private static func query(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        let valueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return "?startTime=\(startText.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? startText)"
            + "&endTime=\(endText.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? endText)"
    }
}

/// Calls Z.ai's read-only Coding Plan quota and monitor endpoints.
public struct GLMHTTPSQuotaTransport: GLMQuotaTransport, GLMMonitorTransport {
    public init() {}

    public func quota(authorizationValue: String) async throws -> Data {
        try await Self.get(pathAndQuery: "/api/monitor/usage/quota/limit",
                           authorizationValue: authorizationValue)
    }

    public func get(_ endpoint: GLMMonitorEndpoint, authorizationValue: String) async throws -> Data {
        try await Self.get(pathAndQuery: endpoint.pathAndQuery, authorizationValue: authorizationValue)
    }

    private static func get(pathAndQuery: String, authorizationValue: String) async throws -> Data {
        guard authorizationValue.utf8.count <= 65_536,
              let url = URL(string: "https://api.z.ai\(pathAndQuery)"),
              url.scheme == "https", url.host == "api.z.ai" else {
            throw GLMQuotaError.credentialUnavailable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = BoundedGLMQuotaResponse(continuation: continuation)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 6
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.dataTask(with: request).resume()
        }
    }
}

/// Fetches a fresh observation; neither authorization values nor API responses are cached.
public final class GLMCodingPlanUsageService: @unchecked Sendable {
    private let credentialLoader: (any GLMCodingPlanCredentialLoading)?
    private let authorizationOverride: String?
    private let overridePlanKind: GLMCodingPlanKind?
    private let transport: any GLMQuotaTransport

    /// `apiKey` is an optional in-memory override for a secure credential helper.
    /// When omitted, the default loader refuses ZCode’s encrypted store; it does not read or transmit it.
    public init(apiKey: String? = nil, planKind: GLMCodingPlanKind? = nil,
                credentialLoader: any GLMCodingPlanCredentialLoading = ZCodeCodingPlanCredentialLoader(),
                transport: any GLMQuotaTransport = GLMHTTPSQuotaTransport()) {
        self.authorizationOverride = apiKey
        self.overridePlanKind = planKind
        self.credentialLoader = apiKey == nil ? credentialLoader : nil
        self.transport = transport
    }

    public func fetch(now: Date = Date()) async throws -> GLMQuotaSnapshot {
        let credential: GLMCodingPlanCredential
        if let authorizationOverride {
            guard !authorizationOverride.isEmpty, authorizationOverride.utf8.count <= 65_536,
                  let overridePlanKind else { throw GLMQuotaError.credentialUnavailable }
            credential = GLMCodingPlanCredential(authorizationValue: authorizationOverride,
                                                  planKind: overridePlanKind)
        } else if let credentialLoader {
            credential = try credentialLoader.load()
        } else {
            throw GLMQuotaError.credentialUnavailable
        }

        let data = try await self.transport.quota(authorizationValue: credential.authorizationValue)
        guard data.count <= 1_048_576 else { throw GLMQuotaError.invalidResponse }
        let snapshot = try Self.parse(data, planKind: credential.planKind, observedAt: now,
                                      source: authorizationOverride == nil ? .zCodeCodingPlan : .explicitCodingPlanKey,
                                      accountVerified: authorizationOverride != nil)

        // Detect a selected plan or credential change while the request was in flight.
        if authorizationOverride == nil, let credentialLoader {
            do {
                let current = try credentialLoader.load()
                guard current.planKind == credential.planKind,
                      Self.constantTimeEqual(current.authorizationValue, credential.authorizationValue) else {
                    throw GLMQuotaError.accountChanged
                }
            } catch {
                throw GLMQuotaError.accountChanged
            }
            return GLMQuotaSnapshot(fiveHour: snapshot.fiveHour, weekly: snapshot.weekly,
                                    monthlyTool: snapshot.monthlyTool, observedAt: snapshot.observedAt,
                                    source: snapshot.source, planKind: snapshot.planKind,
                                    accountVerified: true)
        }
        return snapshot
    }

    private static func parse(_ data: Data, planKind: GLMCodingPlanKind,
                              observedAt: Date, source: GLMQuotaSource,
                              accountVerified: Bool) throws -> GLMQuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GLMQuotaError.invalidResponse
        }
        if let success = root["success"] as? NSNumber,
           CFGetTypeID(success) == CFBooleanGetTypeID(), !success.boolValue {
            if Self.integer(root["code"]) == 401 { throw GLMQuotaError.credentialRejected }
            throw GLMQuotaError.requestFailed
        }
        if let rawCode = root["code"] {
            guard let code = Self.integer(rawCode) else { throw GLMQuotaError.invalidResponse }
            if code == 401 { throw GLMQuotaError.credentialRejected }
            guard code == 0 || code == 200 else { throw GLMQuotaError.requestFailed }
        }
        let payload = root["data"] as? [String: Any] ?? root
        guard let limits = payload["limits"] as? [[String: Any]] else {
            throw GLMQuotaError.invalidResponse
        }

        var fiveHour: GLMQuotaWindow?
        var weekly: GLMQuotaWindow?
        var monthlyTool: GLMQuotaWindow?
        for limit in limits {
            guard let percentage = Self.percentage(limit["percentage"]) else { continue }
            let type = (limit["type"] as? String ?? "").lowercased()
            let description = ["name", "label", "quotaType", "quota_type", "unit"]
                .compactMap { limit[$0] as? String }
                .joined(separator: " ").lowercased()
            let window = GLMQuotaWindow(usedPercentage: percentage,
                                        resetsAt: Self.resetDate(in: limit))
            if description.contains("week") || type.contains("week") {
                if weekly == nil { weekly = window }
            } else if type == "time_limit" || description.contains("mcp")
                        || description.contains("tool") && description.contains("month") {
                if monthlyTool == nil { monthlyTool = window }
            } else if description.contains("hour") || type == "tokens_limit" {
                if fiveHour == nil { fiveHour = window }
            }
        }
        guard fiveHour != nil || weekly != nil || monthlyTool != nil else {
            throw GLMQuotaError.invalidResponse
        }
        return GLMQuotaSnapshot(fiveHour: fiveHour, weekly: weekly, monthlyTool: monthlyTool,
                                observedAt: observedAt, source: source, planKind: planKind,
                                accountVerified: accountVerified)
    }

    private static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func resetDate(in value: [String: Any]) -> Date? {
        for key in ["resetAt", "reset_at", "nextResetTime", "next_reset_time", "resetTime", "reset_time"] {
            guard let raw = value[key] else { continue }
            if let number = raw as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                let seconds = number.doubleValue > 10_000_000_000
                    ? number.doubleValue / 1_000 : number.doubleValue
                if let date = Date(timeIntervalSince1970: seconds).validResetDate { return date }
            }
            if let string = raw as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string),
                   let validDate = date.validResetDate { return validDate }
            }
        }
        return nil
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

private extension Date {
    var validResetDate: Date? {
        self.timeIntervalSince1970.isFinite
            && self < Date(timeIntervalSinceNow: 60 * 60 * 24 * 366 * 10) ? self : nil
    }
}

private final class BoundedGLMQuotaResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var session: URLSession?
    private var bytes = Data()
    private var valid = false
    private var failure: GLMQuotaError = .requestFailed
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 { self.failure = .credentialRejected }
        self.valid = http.statusCode == 200
            && (response.expectedContentLength < 0 || response.expectedContentLength <= 1_048_576)
        completionHandler(self.valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.bytes.count + data.count <= 1_048_576 else {
            self.valid = false
            dataTask.cancel()
            return
        }
        self.bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if error == nil, self.valid { continuation.resume(returning: self.bytes) }
        else { continuation.resume(throwing: self.failure) }
        self.bytes.removeAll()
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
