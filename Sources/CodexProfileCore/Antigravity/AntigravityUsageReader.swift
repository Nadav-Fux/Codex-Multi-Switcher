import Darwin
import CoreFoundation
import CryptoKit
import Foundation

/// Reads the quota-summary API with the existing usage helper's account. Never launches
/// Antigravity, opens a browser, or accesses Keychain. Google verifies the helper bearer
/// belongs to the same subject/email as the current Antigravity CLI ID-token metadata.
public struct AntigravityUsageReader: Sendable {
    private static let maximumBytes = 1_048_576
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 8) {
        // Retain source compatibility; an AGY executable must never be invoked here.
        self.timeout = min(max(timeout, 1), 30)
    }

    public func read() async throws -> AntigravityUsageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let identityURL = home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let helperDirectory = home.appendingPathComponent("Library/Application Support/antigravity-usage")
        let configURL = helperDirectory.appendingPathComponent("config.json")
        guard let identity = Self.identity(at: identityURL),
              let active = Self.activeAccount(at: configURL), active.lowercased() == identity.email else {
            throw AntigravityUsageError.accountUnavailable
        }
        // Match the existing helper's account-directory sanitization, without enumerating accounts.
        let safeEmail = active.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || "@._-".contains(character)) ? character : "_"
        }
        let tokenURL = helperDirectory.appendingPathComponent("accounts")
            .appendingPathComponent(String(safeEmail)).appendingPathComponent("tokens.json")
        var credential = try Self.credential(at: tokenURL, email: active)
        if credential.expiresAt <= Date().addingTimeInterval(300) {
            try await Task.detached(priority: .utility) {
                try Self.refreshHelperAccount(email: active, home: home)
            }.value
            credential = try Self.credential(at: tokenURL, email: active)
        }
        guard credential.expiresAt > Date(),
              Self.activeAccount(at: configURL) == active,
              Self.identity(at: identityURL) == identity else { throw AntigravityUsageError.accountChanged }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = self.timeout
        configuration.timeoutIntervalForResource = self.timeout
        let session = URLSession(configuration: configuration, delegate: AntigravityNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let user = try await Self.request(url: "https://www.googleapis.com/oauth2/v2/userinfo",
                                          accessToken: credential.accessToken, session: session)
        guard let userRoot = try? JSONSerialization.jsonObject(with: user) as? [String: Any],
              userRoot["id"] as? String == identity.subject,
              let verified = userRoot["verified_email"] as? Bool, verified,
              let email = userRoot["email"] as? String,
              email.lowercased() == identity.email else { throw AntigravityUsageError.accountChanged }
        let response = try await Self.request(
            url: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            accessToken: credential.accessToken, session: session, post: true)
        guard Self.activeAccount(at: configURL) == active,
              Self.identity(at: identityURL) == identity,
              let latest = Self.readFile(at: tokenURL, privateFile: true),
              Self.digest(latest) == credential.digest else { throw AntigravityUsageError.accountChanged }
        return try Self.parse(response, observedAt: Date(), identity: identity.digest)
    }

    private struct Identity: Equatable {
        let issuer: String
        let subject: String
        let email: String
        var digest: String { "sha256:" + AntigravityUsageReader.digest(Data((issuer + "\u{0}" + subject).utf8)) }
    }

    private struct Credential {
        let accessToken: String
        let expiresAt: Date
        let digest: String
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads only known paths, with size and ownership checks. Credential files must be 0600.
    private static func readFile(at url: URL, privateFile: Bool = false) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= maximumBytes,
              !privateFile || info.st_mode & 0o777 == 0o600,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return data
    }

    private static func activeAccount(at url: URL) -> String? {
        guard let data = readFile(at: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = root["activeAccount"] as? String, !email.isEmpty, email.count <= 320,
              email.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return email
    }

    private static func identity(at url: URL) -> Identity? {
        guard let data = readFile(at: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let claimsData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let issuer = claims["iss"] as? String,
              ["https://accounts.google.com", "accounts.google.com"].contains(issuer),
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let email = claims["email"] as? String, !email.isEmpty else { return nil }
        return Identity(issuer: issuer, subject: subject, email: email.lowercased())
    }

    private static func credential(at url: URL, email: String) throws -> Credential {
        guard let data = readFile(at: url, privateFile: true),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedEmail = root["email"] as? String, storedEmail.lowercased() == email.lowercased(),
              let accessToken = root["accessToken"] as? String, !accessToken.isEmpty,
              accessToken.utf8.count <= 65_536,
              accessToken.rangeOfCharacter(from: .controlCharacters) == nil,
              let expiry = root["expiresAt"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite,
              expiry.doubleValue > 0 else { throw AntigravityUsageError.accountUnavailable }
        return Credential(accessToken: accessToken,
                          expiresAt: Date(timeIntervalSince1970: expiry.doubleValue / 1000), digest: digest(data))
    }

    private static func request(url: String, accessToken: String, session: URLSession,
                                post: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = post ? "POST" : "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        if post {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= maximumBytes else { throw AntigravityUsageError.commandFailed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw AntigravityUsageError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch let error as AntigravityUsageError { throw error }
        catch {
            if (error as NSError).code == NSURLErrorTimedOut { throw AntigravityUsageError.timedOut }
            throw AntigravityUsageError.commandFailed
        }
    }

    /// The installed helper's explicit account-refresh branch only refreshes OAuth and saves
    /// that account's token/last-used metadata. It never selects login or changes activeAccount.
    private static func refreshHelperAccount(email: String, home: URL) throws {
        let manager = FileManager.default
        let helperCandidates = [home.appendingPathComponent(".local/bin/antigravity-usage"),
                                URL(fileURLWithPath: "/opt/homebrew/bin/antigravity-usage"),
                                URL(fileURLWithPath: "/usr/local/bin/antigravity-usage")]
        guard let helper = helperCandidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw AntigravityUsageError.cliMissing
        }
        let script = helper.resolvingSymlinksInPath()
        // npm's bin symlink resolves into <prefix>/lib/node_modules/<package>/dist/index.js.
        var nodeCandidates: [URL] = []
        var ancestor = script.deletingLastPathComponent()
        for _ in 0..<6 {
            nodeCandidates.append(ancestor.appendingPathComponent("bin/node"))
            ancestor.deleteLastPathComponent()
        }
        nodeCandidates += [home.appendingPathComponent(".local/opt/node-v24.16.0-darwin-arm64/bin/node"),
                           URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node")]
        nodeCandidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("node")
        }
        guard let node = nodeCandidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw AntigravityUsageError.cliMissing
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AntigravityUsageError.commandFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AntigravityUsageError.commandFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, "/") == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw AntigravityUsageError.commandFailed
        }
        let argv = [node.path, script.path, "accounts", "refresh", email].map { strdup($0) }
        // Keep the real home for file-backed helper storage; exclude shell/config injection.
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CI": "true",
                   "NO_COLOR": "1", "BROWSER": "/usr/bin/false"]
        let envp = env.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
            (envp + [nil]).withUnsafeBufferPointer { environment in
                posix_spawn(&pid, node.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: arguments.baseAddress!),
                            UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard result == 0 else { throw AntigravityUsageError.commandFailed }
        var reaped = false
        defer {
            _ = kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                guard status == 0 else { throw AntigravityUsageError.commandFailed }
                return
            }
            guard waited != -1 || errno == EINTR else { throw AntigravityUsageError.commandFailed }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AntigravityUsageError.timedOut }
            usleep(20_000)
        }
    }

    private static func parse(_ data: Data, observedAt: Date, identity: String) throws -> AntigravityUsageSnapshot {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityUsageError.invalidResponse
        }
        let root = envelope["response"] as? [String: Any] ?? envelope
        guard let groups = root["groups"] as? [[String: Any]] else { throw AntigravityUsageError.invalidResponse }
        var buckets: [AntigravityQuotaBucket] = []
        var seen = Set<String>()
        for group in groups {
            guard let entries = group["buckets"] as? [[String: Any]] else { throw AntigravityUsageError.invalidResponse }
            for entry in entries {
                guard let id = (entry["bucketId"] ?? entry["bucket_id"]) as? String else {
                    throw AntigravityUsageError.invalidResponse
                }
                let family: AntigravityQuotaFamily
                let window: String
                switch id {
                case "gemini-5h": family = .gemini; window = "5h"
                case "gemini-weekly": family = .gemini; window = "weekly"
                case "3p-5h": family = .nonGemini; window = "5h"
                case "3p-weekly": family = .nonGemini; window = "weekly"
                default: continue
                }
                guard seen.insert(id).inserted,
                      let fraction = (entry["remainingFraction"] ?? entry["remaining_fraction"]) as? NSNumber,
                      CFGetTypeID(fraction) != CFBooleanGetTypeID(), fraction.doubleValue.isFinite,
                      (0...1).contains(fraction.doubleValue),
                      let reset = (entry["resetTime"] ?? entry["reset_time"]) as? String,
                      let date = parseDate(reset) else { throw AntigravityUsageError.invalidResponse }
                buckets.append(AntigravityQuotaBucket(id: id,
                    familyLabel: family == .gemini ? "Gemini Models" : "Claude + GPT Models",
                    family: family, windowLabel: window == "5h" ? "5-Hour Limit Remaining" : "Weekly Limit Remaining",
                    window: window, remainingFraction: fraction.doubleValue, resetsAt: date))
            }
        }
        guard !buckets.isEmpty else { throw AntigravityUsageError.noQuotaData }
        return AntigravityUsageSnapshot(buckets: buckets, observedAt: observedAt, source: .quotaSummaryAPI,
            accountProvenance: "Google verified usage-helper bearer matches current Antigravity CLI subject and email",
            accountIdentity: identity, accountVerified: true)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private final class AntigravityNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
