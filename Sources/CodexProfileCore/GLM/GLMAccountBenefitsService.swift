import Foundation

public enum ZCodeAccountBenefitsError: LocalizedError, Equatable {
    case credentialsUnavailable
    case accountChanged
    case requestFailed
    case rejected(Int)

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable: return "ZCode account credentials are unavailable."
        case .accountChanged: return "The selected ZCode account changed during refresh."
        case .requestFailed, .rejected: return "ZCode account benefits could not be refreshed."
        }
    }
}

/// Fetches the ZCode reset-card and Start Plan benefit views with read-only GET requests.
/// Secrets stay in this service's memory and never enter the returned snapshot.
public final class GLMAccountBenefitsService: @unchecked Sendable {
    private let credentials: ZCodeAccountCredentialReader

    public init() { self.credentials = ZCodeAccountCredentialReader() }

    /// A stable, non-secret fingerprint for invalidating account-benefit cache generations.
    public func credentialSelectionFingerprint() -> Data? {
        try? credentials.load().fileFingerprint
    }

    /// Returns partial data when one official endpoint is unavailable. Returns nil when neither
    /// endpoint can produce a valid snapshot. The calls never redeem reset opportunities.
    public func fetch(now: Date = Date()) async -> GLMAccountBenefitsSnapshot? {
        guard let credential = try? credentials.load() else { return nil }
        var reset: GLMCodingPlanResetStatus?
        var startPlan: GLMStartPlanBenefits?
        var startPlanUnavailableReason = "ZCode balance is unavailable; no current token balance was verified."

        guard !Task.isCancelled else { return nil }
        if credential.resetCardsSelectedForIndividualPlan, let zaiOAuthToken = credential.zaiOAuthToken {
            do {
                let data = try await Self.get(path: "/api/v1/coding-plan/reset/status",
                                              authorization: "Bearer \(credential.zcodeJWT)",
                                              headers: ["X-Bigmodel-Authorization": zaiOAuthToken,
                                                        "Bigmodel-Target-Type": "PERSONAL"])
                try credentials.verifyUnchanged(credential.fileFingerprint)
                reset = GLMCodingPlanResetStatus.parse(data, sourceObservedAt: now)
            } catch let error as ZCodeAccountBenefitsError {
                if error == .accountChanged { return nil }
            } catch { }
        }

        if credential.zaiOAuthToken != nil, let version = Self.installedZCodeVersion() {
          guard !Task.isCancelled else { return nil }
          do {
            var components = URLComponents(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!
            components.queryItems = [URLQueryItem(name: "app_version", value: version)]
            guard let url = components.url else { throw ZCodeAccountBenefitsError.requestFailed }
            let data = try await Self.get(url: url, authorization: "Bearer \(credential.zcodeJWT)",
                                          headers: Self.sourceHeaders(version: version))
            try credentials.verifyUnchanged(credential.fileFingerprint)
            startPlan = GLMStartPlanBenefits.parse(data, observedAt: now)
            if startPlan == nil { startPlanUnavailableReason = "ZCode balance response could not be read; no current token balance was verified." }
          } catch let error as ZCodeAccountBenefitsError {
              if error == .accountChanged { return nil }
              if case .rejected(let status) = error {
                  startPlanUnavailableReason = "ZCode balance request rejected (HTTP \(status)); no current token balance was verified."
              }
          } catch { }
        }

        // Confirm the on-disk token selection even if a request failed or the app version
        // metadata was unavailable; otherwise a prior partial response could be misattributed.
        guard (try? credentials.verifyUnchanged(credential.fileFingerprint)) != nil else { return nil }
        guard !Task.isCancelled else { return nil }

        guard reset != nil || startPlan != nil else { return nil }
        let scope = GLMAccountScope(family: .zai,
                                    planKind: reset == nil ? .startPlan : .individualCodingPlan)
        return Self.snapshot(reset: reset, startPlan: startPlan, reason: startPlan == nil ? startPlanUnavailableReason : nil, now: now, scope: scope)
    }

    private static func snapshot(reset: GLMCodingPlanResetStatus?, startPlan: GLMStartPlanBenefits?,
                                 reason: String?, now: Date, scope: GLMAccountScope) -> GLMAccountBenefitsSnapshot? {
        guard reset != nil || startPlan != nil else { return nil }
        return GLMAccountBenefitsSnapshot(resetStatus: reset, startPlan: startPlan, startPlanUnavailableReason: reason,
                                          sourceObservedAt: startPlan?.sourceObservedAt ?? reset?.sourceObservedAt ?? now,
                                          account: scope, accountVerified: true)
    }

    /// Required compatibility metadata uses the actual installed version. The requesting
    /// client identifies itself explicitly; no device tracking IDs or telemetry are read.
    private static func sourceHeaders(version: String) -> [String: String] {
        ["User-Agent": "CodexMultiSwitcher ZCode/\(version)",
         "HTTP-Referer": "https://zcode.z.ai", "X-ZCode-App-Version": version,
         "X-Title": "Codex Multi Switcher", "x-request-id": UUID().uuidString]
    }

    private static func installedZCodeVersion() -> String? {
        let candidates = ["/Applications/ZCode.app", NSHomeDirectory() + "/Applications/ZCode.app"]
        for path in candidates {
            guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                  let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  !version.isEmpty, version.utf8.count <= 64,
                  version.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_+").contains($0) }) else { continue }
            return version
        }
        return nil
    }

    private static func get(path: String, authorization: String, headers: [String: String]) async throws -> Data {
        guard path.hasPrefix("/api/v1/"), !path.contains(".."),
              let url = URL(string: "https://zcode.z.ai\(path)") else {
            throw ZCodeAccountBenefitsError.requestFailed
        }
        return try await get(url: url, authorization: authorization, headers: headers)
    }

    private static func get(url: URL, authorization: String, headers: [String: String]) async throws -> Data {
        guard url.scheme == "https", url.host == "zcode.z.ai", url.user == nil, url.password == nil,
              authorization.utf8.count <= 65_536,
              !authorization.contains("\r"), !authorization.contains("\n") else {
            throw ZCodeAccountBenefitsError.requestFailed
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers {
            guard value.utf8.count <= 65_536, !value.contains("\r"), !value.contains("\n") else {
                throw ZCodeAccountBenefitsError.requestFailed
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return try await BoundedZCodeRequest.run(request, configuration: configuration)
    }
}

private final class BoundedZCodeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var body = Data()
    private var failure: Error?

    static func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let operation = BoundedZCodeRequest(continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
            operation.session = session
            session.dataTask(with: request).resume()
        }
    }

    private init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        failure = ZCodeAccountBenefitsError.requestFailed
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https", http.url?.host == "zcode.z.ai" else {
            failure = (response as? HTTPURLResponse).map { ZCodeAccountBenefitsError.rejected($0.statusCode) } ?? .requestFailed
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= GLMSourceParser.maximumPayloadBytes else {
            failure = ZCodeAccountBenefitsError.requestFailed
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Data, Error>
        lock.lock()
        if let continuation {
            self.continuation = nil
            if let failure { result = .failure(failure) }
            else if let error { result = .failure(error) }
            else { result = .success(body) }
            lock.unlock()
            continuation.resume(with: result)
        } else {
            lock.unlock()
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
