import CodexProfileCore
import Foundation
import Darwin

/// Reads the same local language-server methods as the IDE's Models & Usage panel.
/// No agent turn, Keychain access, token refresh, or credential persistence is involved.
struct AntigravityIDEQuotaReader: Sendable {
    struct Endpoint: Sendable {
        let pid: Int32
        let port: Int
        let csrf: String
    }

    /// Exact installed language-server binaries that serve the Models & Usage
    /// panel. The standalone Antigravity app (Nov 2026) ships its own server at
    /// a different path; the older IDE bundle keeps the extension path.
    static let executables: Set<String> = [
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
    ]

    func read() async throws -> ProviderUsageSnapshot {
        let endpoints = try await Task.detached { try Self.discover() }.value
        for endpoint in endpoints {
            do {
                let before = try await Self.request("GetUserStatus", endpoint: endpoint)
                let quota = try await Self.request("RetrieveUserQuotaSummary", endpoint: endpoint)
                let after = try await Self.request("GetUserStatus", endpoint: endpoint)
                // Revalidate the PID and its private connection token before publishing.
                guard try await Task.detached(operation: {
                    try Self.csrf(pid: endpoint.pid) == endpoint.csrf
                }).value else { throw AntigravityUsageError.accountChanged }
                return try Self.snapshot(quota: quota, before: before, after: after)
            } catch { continue }
        }
        throw AntigravityUsageError.noQuotaData
    }

    static func snapshot(quota: Data, before: Data, after: Data) throws -> ProviderUsageSnapshot {
        func email(_ data: Data) throws -> String {
            guard data.count <= 1_048_576,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let user = root["userStatus"] as? [String: Any],
                  let email = user["email"] as? String,
                  email.contains("@"), email.count <= 320,
                  email.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw AntigravityUsageError.accountUnavailable
            }
            return email.lowercased()
        }
        let account = try email(before)
        guard try email(after) == account else { throw AntigravityUsageError.accountChanged }
        guard quota.count <= 1_048_576,
              let envelope = try JSONSerialization.jsonObject(with: quota) as? [String: Any],
              let groups = (envelope["response"] as? [String: Any] ?? envelope)["groups"] as? [[String: Any]] else {
            throw AntigravityUsageError.invalidResponse
        }
        var buckets: [ProviderUsageBucket] = []
        var seen = Set<String>()
        for group in groups {
            guard let entries = group["buckets"] as? [[String: Any]] else { throw AntigravityUsageError.invalidResponse }
            for entry in entries {
                guard let id = entry["bucketId"] as? String else { throw AntigravityUsageError.invalidResponse }
                let family: ProviderUsageBucketGroup
                let title: String
                switch id {
                case "gemini-weekly": family = .gemini; title = "Weekly"
                case "gemini-5h": family = .gemini; title = "5 hour"
                case "3p-weekly": family = .other; title = "Weekly"
                case "3p-5h": family = .other; title = "5 hour"
                default: continue
                }
                guard seen.insert(id).inserted,
                      let fraction = entry["remainingFraction"] as? NSNumber,
                      CFGetTypeID(fraction) != CFBooleanGetTypeID(), fraction.doubleValue.isFinite,
                      (0...1).contains(fraction.doubleValue),
                      let reset = entry["resetTime"] as? String,
                      let date = Self.date(reset) else { throw AntigravityUsageError.invalidResponse }
                buckets.append(ProviderUsageBucket(id: id, title: title,
                    remainingFraction: fraction.doubleValue, resetAt: date, group: family))
            }
        }
        guard !buckets.isEmpty else { throw AntigravityUsageError.noQuotaData }
        return ProviderUsageSnapshot(provider: .antigravity,
            account: ProviderAccount(displayName: "Current Antigravity IDE account", email: account),
            buckets: buckets, observedAt: Date(),
            source: "Antigravity IDE quota · verified active IDE account", accountVerified: true)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func discover() throws -> [Endpoint] {
        let rows = try command("/bin/ps", ["-axo", "pid=,uid=,comm="])
        var endpoints: [Endpoint] = []
        for row in rows.split(separator: "\n") {
            let fields = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[1] == String(getuid()), self.executables.contains(String(fields[2])),
                  let pid = Int32(fields[0]), let token = try? self.csrf(pid: pid) else { continue }
            let listeners = try command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            for line in listeners.split(separator: "\n") {
                // Only listeners owned by this exact installed IDE server and bound
                // to loopback are candidates. Never send the token to a remote host.
                guard line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n[::1]:"),
                      let suffix = line.split(separator: ":").last,
                      let port = Int(suffix), (1...65535).contains(port) else { continue }
                endpoints.append(Endpoint(pid: pid, port: port, csrf: token))
                if endpoints.count == 16 { return endpoints }
            }
        }
        return endpoints
    }

    private static func csrf(pid: Int32) throws -> String {
        let comm = try command("/bin/ps", ["-p", String(pid), "-o", "uid=,comm="])
        let owner = comm.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard owner.count == 2, owner[0] == String(getuid()), self.executables.contains(String(owner[1])) else {
            throw AntigravityUsageError.accountChanged
        }
        let args = try command("/bin/ps", ["-p", String(pid), "-o", "args="])
        let words = args.split(whereSeparator: \.isWhitespace)
        guard let index = words.firstIndex(of: "--csrf_token"), index + 1 < words.count else {
            throw AntigravityUsageError.accountUnavailable
        }
        let token = String(words[index + 1])
        guard (16...256).contains(token.utf8.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw AntigravityUsageError.accountUnavailable
        }
        return token
    }

    private static func command(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        // Drain while the child runs: waiting first can fill ps's pipe and deadlock.
        // The private CSRF value stays in memory, never in a temporary output file.
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        defer { timeout.cancel(); try? output.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            guard data.count + chunk.count <= 1_048_576 else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw AntigravityUsageError.invalidResponse
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, let text = String(data: data, encoding: .utf8) else {
            throw AntigravityUsageError.invalidResponse
        }
        return text
    }

    private static func request(_ method: String, endpoint: Endpoint) async throws -> Data {
        guard ["GetUserStatus", "RetrieveUserQuotaSummary"].contains(method),
              let url = URL(string: "http://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)") else {
            throw AntigravityUsageError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.httpBody = method == "GetUserStatus" ? Data("{}".utf8) : Data("{\"forceRefresh\":true}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: AntigravityIDENoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else {
            throw AntigravityUsageError.invalidResponse
        }
        return data
    }
}

private final class AntigravityIDENoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
