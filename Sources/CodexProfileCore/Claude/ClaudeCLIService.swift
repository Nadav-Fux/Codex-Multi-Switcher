import Darwin
import Foundation

/// Runs only the CLI's token-free auth status command. Never reads Keychain credentials.
public struct ClaudeCLIService: Sendable {
    public let environment: [String: String]
    public let userHome: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, userHome: URL) {
        self.environment = environment
        self.userHome = userHome
    }

    public func discoverExecutable(fileManager: FileManager = .default) -> URL? {
        let paths = (self.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("claude")
        } + [self.userHome.appendingPathComponent(".local/bin/claude"),
             self.userHome.appendingPathComponent(".npm-global/bin/claude"),
             URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
             URL(fileURLWithPath: "/usr/local/bin/claude")]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func sanitizedEnvironment(profile: ClaudeProfile) -> [String: String] {
        var result = self.environment.filter { !Self.isCredentialOverride($0.key) }
        // Claude's default Keychain item differs from an explicitly configured directory,
        // even when that directory is ~/.claude. Preserve the CLI's native default mode.
        if !self.usesNativeDefault(profile: profile) { result["CLAUDE_CONFIG_DIR"] = profile.configDirectory }
        result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    public static func isCredentialOverride(_ key: String) -> Bool {
        key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_USE_") ||
        key == "CLAUDE_CODE_OAUTH_TOKEN" || key == "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" ||
        key == "CLAUDE_CONFIG_DIR" || key == "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    }

    /// An isolated preview/test may call its own directory "default". Only the
    /// actual HOME/.claude account can use Claude's implicit default Keychain mode.
    private func usesNativeDefault(profile: ClaudeProfile) -> Bool {
        guard profile.isDefault else { return false }
        let nativeHome = self.environment["HOME"].flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL.path ==
            nativeHome.appendingPathComponent(".claude", isDirectory: true).path
    }

    public func authStatus(profile: ClaudeProfile, timeout: TimeInterval = 6) throws -> ClaudeAuthInfo {
        guard let executable = self.discoverExecutable() else { throw ClaudeIntegrationError.cliMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.environment = self.sanitizedEnvironment(profile: profile)
        process.currentDirectoryURL = self.userHome
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.1), 30))
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var observedExit = false
        while true {
            let length = Darwin.read(fd, &buffer, buffer.count)
            if length > 0 {
                guard output.count + length <= 65_536 else {
                    Self.stop(process)
                    throw ClaudeIntegrationError.invalidStatus
                }
                output.append(contentsOf: buffer.prefix(length))
                continue
            }
            if length < 0 && errno == EINTR { continue }
            if observedExit { break }
            if !process.isRunning {
                // The child may have written its final JSON between the EAGAIN read
                // above and this exit observation. Drain once more after exit, then
                // stop at EOF/EAGAIN even if a descendant kept the pipe open.
                observedExit = true
                continue
            }
            if Date() >= deadline {
                Self.stop(process)
                throw ClaudeIntegrationError.timeout
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else { throw ClaudeIntegrationError.invalidStatus }
        // Extract a fixed list of non-secret fields; never persist or log the raw response.
        return ClaudeAuthInfo(loggedIn: loggedIn, email: Self.safeString(json["email"]),
                              organization: Self.safeString(json["orgName"]),
                              subscription: Self.safeString(json["subscriptionType"]),
                              authenticationMethod: Self.safeString(json["authMethod"]),
                              accountID: Self.safeString(json["accountUuid"] ?? json["accountId"]),
                              organizationID: Self.safeString(json["orgId"] ?? json["orgUuid"]))
    }

    /// Generates a private launcher for a NEW Terminal process. It never retargets a live session.
    public func makeTerminalScript(profile: ClaudeProfile, login: Bool, scriptsRoot: URL) throws -> URL {
        guard let executable = self.discoverExecutable() else { throw ClaudeIntegrationError.cliMissing }
        let unset = Set(self.environment.keys.filter(Self.isCredentialOverride)).union([
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR",
        ])
        var script = "#!/bin/zsh\n# A new independent Claude Code session.\n"
        script += "for claude_env_name in ${(k)parameters}; do\n"
        script += "  case \"$claude_env_name\" in ANTHROPIC_*|CLAUDE_CODE_USE_*|CLAUDE_CODE_OAUTH_TOKEN*|CLAUDE_SECURESTORAGE_CONFIG_DIR) unset \"$claude_env_name\" ;; esac\n"
        script += "done\n"
        script += "unset " + unset.sorted().map(Self.shellQuote).joined(separator: " ") + "\n"
        if !self.usesNativeDefault(profile: profile) {
            script += "export CLAUDE_CONFIG_DIR=" + Self.shellQuote(profile.configDirectory) + "\n"
        }
        script += "export DISABLE_AUTOUPDATER=1\n"
        script += "cd " + Self.shellQuote(self.userHome.path) + " || exit 1\n"
        script += Self.shellQuote(executable.path)
        script += login ? " auth login\n" : "\n"
        if login {
            script += "printf '\\nClaude sign-in finished. Refresh Claude in Codex Multi Switcher.\\n'\n"
        }
        let destination = scriptsRoot.appendingPathComponent("claude-\(profile.id)-\(UUID().uuidString).command")
        try AtomicFileWriter.write(Data(script.utf8), to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 512,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
