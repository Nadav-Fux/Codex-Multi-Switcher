import Darwin
import CoreFoundation
import CryptoKit
import Foundation

/// Reads Antigravity's live quota snapshot through the official read-only CLI command.
/// Runs with a disposable private home and working directory so user statusline commands,
/// hooks, plugins, and project settings cannot run. Only the known cached auth metadata is
/// copied; real auth/settings state is never written and no model prompt fallback is used.
public struct AntigravityUsageReader: Sendable {
    private static let minimumSafeCLI = [1, 2, 11]
    private static let maximumOutputBytes = 1_048_576

    private let explicitExecutableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 8) {
        self.explicitExecutableURL = executableURL
        self.timeout = min(max(timeout, 1), 30)
    }

    /// Performs a fresh `/usage` fetch. Antigravity's CLI refreshes quota state for this command.
    public func read() async throws -> AntigravityUsageSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.readSynchronously(executableURL: self.explicitExecutableURL,
                                       timeout: self.timeout)
        }.value
    }

    private static func readSynchronously(executableURL: URL?, timeout: TimeInterval) throws -> AntigravityUsageSnapshot {
        guard let executable = executableURL ?? Self.resolveExecutable() else {
            throw AntigravityUsageError.cliMissing
        }
        let realTokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let token = Self.cachedToken(at: realTokenURL),
              let identityBefore = Self.accountIdentity(token) else {
            throw AntigravityUsageError.accountUnavailable
        }
        let isolated = try IsolatedHome(token: token)
        defer { isolated.remove() }
        guard Self.currentAccountIdentity(at: isolated.tokenURL) == identityBefore else {
            throw AntigravityUsageError.accountChanged
        }

        let versionData: Data
        do {
            versionData = try Self.run(executable: executable, arguments: ["--version"], home: isolated, timeout: timeout)
        } catch AntigravityUsageError.timedOut {
            throw AntigravityUsageError.timedOut
        } catch {
            throw AntigravityUsageError.commandFailed
        }
        guard let versionText = String(data: versionData, encoding: .utf8),
              let version = Self.version(in: versionText),
              Self.isSafeVersion(version) else {
            // Older builds may treat `/usage` as a user prompt. Do not invoke them.
            throw AntigravityUsageError.unsupportedCLIVersion
        }

        let response: Data
        do {
            response = try Self.run(executable: executable,
                                    arguments: ["-p", "/usage", "--output-format", "json",
                                                "--print-timeout", "\(Int(ceil(timeout)))s"],
                                    home: isolated, timeout: timeout)
        } catch AntigravityUsageError.timedOut {
            throw AntigravityUsageError.timedOut
        } catch {
            throw AntigravityUsageError.commandFailed
        }
        guard let identityAfter = Self.currentAccountIdentity(at: realTokenURL),
              identityBefore == identityAfter,
              Self.currentAccountIdentity(at: isolated.tokenURL) == identityAfter else {
            throw AntigravityUsageError.accountChanged
        }
        return try Self.parse(response, observedAt: Date(), accountIdentity: identityAfter)
    }

    /// Loads just the official CLI's known token metadata. Unknown top-level fields are not
    /// copied, and credentials are never included in errors or diagnostic output.
    private static func cachedToken(at url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= Self.maximumOutputBytes,
              let data = try? Data(contentsOf: url), data.count <= Self.maximumOutputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = root["auth_method"] as? String, !method.isEmpty,
              let idToken = root["id_token"] as? String,
              let token = root["token"] as? [String: Any], !token.isEmpty else { return nil }
        return ["auth_method": method, "id_token": idToken, "token": token]
    }

    private static func currentAccountIdentity(at url: URL) -> String? {
        guard let token = Self.cachedToken(at: url) else { return nil }
        return Self.accountIdentity(token)
    }

    /// Hashes the ID-token issuer and subject; no token or other claim is returned.
    private static func accountIdentity(_ token: [String: Any]) -> String? {
        guard let idToken = token["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let payloadData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let issuer = claims["iss"] as? String, !issuer.isEmpty,
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((issuer + "\u{0}" + subject).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "sha256:" + digest
    }

    private static func resolveExecutable() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            URL(fileURLWithPath: "/usr/bin/agy"),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates.append(contentsOf: path.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("agy")
        })
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    private struct IsolatedHome {
        let url: URL
        let tokenURL: URL

        init(token: [String: Any]) throws {
            // mkdtemp creates the parent atomically with mode 0700, before credentials exist.
            var template = Array(FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-agy-quota-XXXXXX").path.utf8CString)
            guard let path = mkdtemp(&template) else { throw AntigravityUsageError.commandFailed }
            let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            let cli = root.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            let tokenURL = cli.appendingPathComponent("antigravity-oauth-token")
            do {
                let manager = FileManager.default
                for directory in [cli, root.appendingPathComponent(".gemini/config"),
                                  root.appendingPathComponent(".agents"),
                                  root.appendingPathComponent("tmp")] {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                }
                let settings: [String: Any] = [
                    "statusLine": ["enabled": false],
                    "title": ["enabled": false],
                    "hooks": [:], "mcpServers": [:],
                    "notifications": false, "enableTelemetry": false,
                ]
                for (file, data) in [
                    (tokenURL, try JSONSerialization.data(withJSONObject: token)),
                    (cli.appendingPathComponent("settings.json"),
                     try JSONSerialization.data(withJSONObject: settings)),
                    (root.appendingPathComponent(".gemini/config/hooks.json"), Data("{}".utf8)),
                    (root.appendingPathComponent(".agents/hooks.json"), Data("{}".utf8)),
                ] {
                    guard manager.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
                        throw AntigravityUsageError.commandFailed
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw AntigravityUsageError.commandFailed
            }
            self.url = root
            self.tokenURL = tokenURL
        }

        var environment: [String: String] {
            // Do not inherit provider keys, host-auth switches, config paths, or shell setup.
            ["HOME": url.path, "CFFIXED_USER_HOME": url.path,
             "XDG_CONFIG_HOME": url.appendingPathComponent(".config").path,
             "XDG_CACHE_HOME": url.appendingPathComponent(".cache").path,
             "XDG_DATA_HOME": url.appendingPathComponent(".local/share").path,
             "TMPDIR": url.appendingPathComponent("tmp").path,
             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
             "TERM": "dumb", "NO_COLOR": "1", "CI": "true",
             "BROWSER": "/usr/bin/false", "GIT_CONFIG_GLOBAL": "/dev/null",
             "GIT_CONFIG_NOSYSTEM": "1"]
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private static func run(executable: URL, arguments: [String], home: IsolatedHome,
                            timeout: TimeInterval) throws -> Data {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw AntigravityUsageError.commandFailed }
        defer { close(descriptors[0]); close(descriptors[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AntigravityUsageError.commandFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AntigravityUsageError.commandFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group owns all inherited descendants; kill it on every exit path.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, home.url.path) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else {
            throw AntigravityUsageError.commandFailed
        }
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = home.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let launch = (argv + [nil]).withUnsafeBufferPointer { argvPointer in
            (envp + [nil]).withUnsafeBufferPointer { envPointer in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argvPointer.baseAddress!),
                            UnsafeMutablePointer(mutating: envPointer.baseAddress!))
            }
        }
        guard launch == 0 else { throw AntigravityUsageError.commandFailed }
        var reaped = false
        defer {
            _ = kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else {
            throw AntigravityUsageError.commandFailed
        }
        // Parent must not keep the writing end alive. Mark it closed for the outer defer.
        close(descriptors[1])
        descriptors[1] = -1
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var exitStatus: Int32 = 0
        while true {
            while true {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= Self.maximumOutputBytes else {
                        throw AntigravityUsageError.invalidResponse
                    }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == -1 && errno == EINTR {
                    continue
                } else if count == -1 && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw AntigravityUsageError.commandFailed
                } else {
                    break
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AntigravityUsageError.timedOut
                }
            }
            let result = waitpid(pid, &exitStatus, WNOHANG)
            if result == pid {
                reaped = true
                _ = kill(-pid, SIGKILL)
                // Read remaining buffered output, without waiting for descendants to close it.
                while true {
                    let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                    guard count > 0 else { break }
                    guard data.count + count <= Self.maximumOutputBytes else {
                        throw AntigravityUsageError.invalidResponse
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                break
            }
            guard result != -1 || errno == EINTR else { throw AntigravityUsageError.commandFailed }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AntigravityUsageError.timedOut
            }
            var pollDescriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&pollDescriptor, 1, 20)
        }
        guard exitStatus == 0 else { throw AntigravityUsageError.commandFailed }
        return data
    }

    private static func version(in value: String) -> [Int]? {
        let pattern = #"(?:^|\s)v?(\d+)\.(\d+)\.(\d+)(?:$|\s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges == 4 else { return nil }
        return (1...3).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
    }

    private static func isSafeVersion(_ value: [Int]) -> Bool {
        for index in 0..<minimumSafeCLI.count {
            let current = index < value.count ? value[index] : 0
            if current != minimumSafeCLI[index] { return current > minimumSafeCLI[index] }
        }
        return true
    }

    private static func parse(_ data: Data, observedAt: Date,
                              accountIdentity: String) throws -> AntigravityUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let numTurns = root["num_turns"] as? Int, numTurns == 0,
              let command = root["command"] as? [String: Any],
              command["name"] as? String == "usage",
              let commandData = command["data"] as? [String: Any],
              let groups = commandData["groups"] as? [[String: Any]] else {
            throw AntigravityUsageError.invalidResponse
        }

        var buckets: [AntigravityQuotaBucket] = []
        var seenIDs = Set<String>()
        for group in groups {
            guard let familyLabel = group["name"] as? String, !familyLabel.isEmpty,
                  let rawBuckets = group["buckets"] as? [[String: Any]] else {
                throw AntigravityUsageError.invalidResponse
            }
            let family: AntigravityQuotaFamily = familyLabel.localizedCaseInsensitiveContains("gemini")
                ? .gemini : .nonGemini
            let description = group["description"] as? String
            for bucket in rawBuckets {
                guard let id = bucket["id"] as? String, !id.isEmpty,
                      seenIDs.insert(id).inserted,
                      let windowLabel = bucket["name"] as? String, !windowLabel.isEmpty,
                      let window = bucket["window"] as? String, !window.isEmpty,
                      let fractionNumber = bucket["remaining_fraction"] as? NSNumber,
                      CFGetTypeID(fractionNumber) != CFBooleanGetTypeID(),
                      fractionNumber.doubleValue.isFinite,
                      (0...1).contains(fractionNumber.doubleValue),
                      let resetText = bucket["reset_time"] as? String,
                      let resetsAt = Self.parseDate(resetText) else {
                    throw AntigravityUsageError.invalidResponse
                }
                buckets.append(AntigravityQuotaBucket(
                    id: id,
                    familyLabel: familyLabel,
                    family: family,
                    modelDescription: description,
                    windowLabel: windowLabel,
                    window: window,
                    remainingFraction: fractionNumber.doubleValue,
                    resetsAt: resetsAt
                ))
            }
        }
        guard !buckets.isEmpty else { throw AntigravityUsageError.noQuotaData }
        return AntigravityUsageSnapshot(buckets: buckets, observedAt: observedAt,
                                        accountIdentity: accountIdentity, accountVerified: true)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}
