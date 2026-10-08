import Foundation

/// Reads account identity from Claude's local metadata. CLI execution is reserved for user-launched sessions.
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

    /// Compatibility entry point: no subprocess is started and no credential is read.
    /// Local metadata remembers an identity; it cannot attest that its credential is valid.
    public func authStatus(profile: ClaudeProfile, timeout: TimeInterval = 6) throws -> ClaudeAuthInfo {
        try self.identityMetadata(profile: profile)
    }

    public func identityMetadata(profile: ClaudeProfile, fileManager: FileManager = .default) throws -> ClaudeAuthInfo {
        let metadataURL: URL
        if profile.isDefault {
            // The native account's metadata lives beside ~/.claude, not inside it.
            // Use the configured home so isolated previews cannot read the real account.
            metadataURL = self.userHome.appendingPathComponent(".claude.json")
        } else {
            let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
            // Claude Code 2.1.260's installed source prefers this legacy config file
            // when present, otherwise its production OAuth metadata is .claude.json.
            let legacy = directory.appendingPathComponent(".config.json")
            metadataURL = fileManager.fileExists(atPath: legacy.path)
                ? legacy : directory.appendingPathComponent(".claude.json")
        }
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return ClaudeAuthInfo(loggedIn: nil)
        }
        guard let size = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16_777_216 else { throw ClaudeIntegrationError.invalidStatus }
        let document: IdentityDocument
        do {
            let data = try Data(contentsOf: metadataURL)
            guard data.count <= 16_777_216 else { throw ClaudeIntegrationError.invalidStatus }
            // Decode only oauthAccount identity fields. Ignore credentials and all other settings.
            document = try JSONDecoder().decode(IdentityDocument.self, from: data)
        } catch { throw ClaudeIntegrationError.invalidStatus }
        guard let account = document.oauthAccount else { return ClaudeAuthInfo(loggedIn: nil) }
        let email = Self.safeString(account.emailAddress)
        let accountID = Self.safeString(account.accountUuid)
        guard email != nil || accountID != nil else { return ClaudeAuthInfo(loggedIn: nil) }
        return ClaudeAuthInfo(loggedIn: nil, email: email,
                              organization: Self.safeString(account.organizationName),
                              authenticationMethod: "account_metadata",
                              accountID: accountID,
                              organizationID: Self.safeString(account.organizationUuid))
    }

    private struct IdentityDocument: Decodable {
        let oauthAccount: AccountMetadata?
    }

    private struct AccountMetadata: Decodable {
        let accountUuid: String?
        let emailAddress: String?
        let organizationName: String?
        let organizationUuid: String?
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

}
