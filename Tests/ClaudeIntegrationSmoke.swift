import CodexProfileCore
import Foundation

/// All CLI invocations use a fake executable; all profile data lives in one temp fixture.
@main
struct ClaudeIntegrationSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
    private static func expectFailure(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(description: message)
    }
    private static func writeJSON(_ object: [String: Any], _ url: URL) throws {
        try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: object), to: url)
    }
    private static func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claude-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try AtomicFileWriter.ensurePrivateDirectory(root)
        let dedicatedHome = root.appendingPathComponent("claude-user", isDirectory: true)
        try AtomicFileWriter.ensurePrivateDirectory(dedicatedHome)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try AtomicFileWriter.ensurePrivateDirectory(bin)
        let executable = bin.appendingPathComponent("claude")
        let trace = root.appendingPathComponent("launcher-trace")
        let fake = #"""
        #!/bin/sh
        if [ "$1" = auth ] && [ "$2" = status ]; then
          if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$CLAUDE_SECURESTORAGE_CONFIG_DIR" ] || [ -n "$ANTHROPIC_UNKNOWN_OVERRIDE" ]; then
            printf 'bad environment'; exit 2
          fi
          printf '{"loggedIn":true,"email":"fixture@example.test","orgName":"Fixture Org","orgId":"org-fixture","subscriptionType":"max","authMethod":"claude.ai"}'
        else
          printf '%s\n' "$CLAUDE_CONFIG_DIR" > "$TRACE_FILE"
          if [ -n "$ANTHROPIC_RUNTIME_ONLY" ] || [ -n "$CLAUDE_CODE_USE_RUNTIME_ONLY" ] || [ -n "$CLAUDE_SECURESTORAGE_CONFIG_DIR" ]; then
            printf 'unsafe\n' >> "$TRACE_FILE"
          fi
        fi
        """#
        try AtomicFileWriter.write(Data(fake.utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = ["CODEX_PROFILE_TEST_HOME": root.path, "CLAUDE_PROFILE_USER_HOME": dedicatedHome.path,
                           "PATH": bin.path + ":/usr/bin:/bin", "HOME": dedicatedHome.path,
                           "ANTHROPIC_API_KEY": "fake-must-not-inherit", "ANTHROPIC_UNKNOWN_OVERRIDE": "fake",
                           "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/unsafe-not-used", "TRACE_FILE": trace.path]
        let paths = AppPaths(environment: environment)
        let registry = ClaudeProfileRegistry(paths: paths)
        let defaultProfile = registry.defaultProfile
        try require(defaultProfile.configDirectory == dedicatedHome.appendingPathComponent(".claude").path,
                    "Dedicated Claude home must be independent from Codex vault home")
        let originalSettings: [String: Any] = ["theme": "light", "statusLine": [
            "type": "command", "command": "printf 'old status'", "padding": 2, "refreshInterval": 12]]
        let settingsURL = URL(fileURLWithPath: defaultProfile.configDirectory).appendingPathComponent("settings.json")
        try writeJSON(originalSettings, settingsURL)
        let sentinel = Data("fictional-default-auth-never-copied".utf8)
        let credentialsURL = settingsURL.deletingLastPathComponent().appendingPathComponent(".credentials.json")
        try AtomicFileWriter.write(sentinel, to: credentialsURL)
        let originalSettingsBytes = try Data(contentsOf: settingsURL)
        let codexConfigURL = paths.configURL
        try AtomicFileWriter.write(Data("codex-selection-sentinel".utf8), to: codexConfigURL)

        let initial = try registry.load()
        try require(initial.selectedID == ClaudeProfileRegistry.defaultID, "Default Claude detected")
        let added = try registry.add(label: " Work ")
        let managed = added.profiles.last!
        try require(managed.label == "Work" && !managed.isDefault, "Managed account added")
        try require(!fm.fileExists(atPath: managed.configDirectory + "/.credentials.json"), "No credential copying")
        try require((try registry.load()).selectedID == managed.id, "Claude selection persisted")
        _ = try registry.rename(id: managed.id, label: "Research")
        try expectFailure("Invalid labels must fail") { _ = try registry.rename(id: managed.id, label: "\n") }
        try expectFailure("Default profile cannot be removed") { _ = try registry.remove(id: defaultProfile.id) }
        _ = try registry.select(id: defaultProfile.id)
        try require(try Data(contentsOf: settingsURL) == originalSettingsBytes, "Registry never touches default settings")
        try require(try Data(contentsOf: credentialsURL) == sentinel, "Registry preserves default credentials")
        try require(try Data(contentsOf: codexConfigURL) == Data("codex-selection-sentinel".utf8), "Claude selection independent of Codex")

        let cli = ClaudeCLIService(environment: environment, userHome: dedicatedHome)
        try require(cli.sanitizedEnvironment(profile: defaultProfile)["CLAUDE_CONFIG_DIR"] == nil,
                    "Default auth uses Claude's native Keychain mode without CLAUDE_CONFIG_DIR")
        try require(cli.sanitizedEnvironment(profile: managed)["CLAUDE_CONFIG_DIR"] == managed.configDirectory,
                    "Managed auth explicitly selects an isolated directory")
        var previewEnvironment = environment
        previewEnvironment.removeValue(forKey: "CLAUDE_PROFILE_USER_HOME")
        let separateNativeHome = root.appendingPathComponent("different-native-home", isDirectory: true)
        previewEnvironment["HOME"] = separateNativeHome.path
        let previewRegistry = ClaudeProfileRegistry(paths: AppPaths(environment: previewEnvironment))
        let previewCLI = ClaudeCLIService(environment: previewEnvironment, userHome: root)
        try require(previewCLI.sanitizedEnvironment(profile: previewRegistry.defaultProfile)["CLAUDE_CONFIG_DIR"] ==
                    previewRegistry.defaultProfile.configDirectory,
                    "A preview's isolated default cannot read the native HOME account")
        let previewLauncher = try previewCLI.makeTerminalScript(profile: previewRegistry.defaultProfile, login: false,
                                                                scriptsRoot: root.appendingPathComponent("preview-launchers"))
        try require(try String(contentsOf: previewLauncher, encoding: .utf8).contains(
            "export CLAUDE_CONFIG_DIR=" + ClaudeCLIService.shellQuote(previewRegistry.defaultProfile.configDirectory)),
                    "Preview default launcher explicitly selects its isolated directory")
        let auth = try cli.authStatus(profile: managed)
        try require(auth.loggedIn == true && auth.email == "fixture@example.test", "Bounded sanitized auth status")
        let fingerprint = ClaudeUsageReader.accountFingerprint(auth)!
        let now = Date()
        let nativeURL = URL(fileURLWithPath: managed.configDirectory).appendingPathComponent(ClaudeUsageReader.nativeSnapshotName)
        var snapshot: [String: Any] = ["schemaVersion": 1, "profileID": managed.id,
                                       "configDirectory": managed.configDirectory,
                                       "fetchedAt": ISO8601DateFormatter().string(from: now),
                                       "authIdentityDigest": fingerprint,
                                       "fiveHour": ["usedPercent": 30, "resetAt": NSNull()], "sevenDay": NSNull()]
        try writeJSON(snapshot, nativeURL)
        let current = ClaudeUsageReader.read(profile: managed, auth: auth, now: now).snapshot
        try require(current?.fiveHour?.usedPercentage == 30 && current?.sevenDay == nil && current?.accountVerified == true,
                    "Valid profile and account bound native snapshot parsed with null week")
        let other = ClaudeAuthInfo(loggedIn: true, email: "other@example.test", organizationID: "org-fixture")
        try require(ClaudeUsageReader.read(profile: managed, auth: other).snapshot == nil,
                    "Snapshots rejected after account identity changes")
        snapshot["profileID"] = defaultProfile.id
        try writeJSON(snapshot, nativeURL)
        try require(ClaudeUsageReader.read(profile: managed, auth: auth).snapshot == nil, "Wrong profile ID rejected")
        snapshot["profileID"] = managed.id
        snapshot["fetchedAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        try writeJSON(snapshot, nativeURL)
        try require(ClaudeUsageReader.read(profile: managed, auth: auth).snapshot?.isStale == true, "Native age reported stale")
        snapshot["fiveHour"] = ["usedPercent": true]
        try writeJSON(snapshot, nativeURL)
        try require(ClaudeUsageReader.read(profile: managed, auth: auth).snapshot == nil, "Boolean percentages rejected")
        let legacyURL = settingsURL.deletingLastPathComponent().appendingPathComponent("statusline-usage-cache.json")
        try writeJSON(["five_hour": ["utilization": 60], "seven_day": ["utilization": 15]], legacyURL)
        let legacy = ClaudeUsageReader.read(profile: defaultProfile, auth: auth).snapshot
        try require(legacy?.source == .legacyStatusline && legacy?.isStale == true && legacy?.accountVerified == false,
                    "Legacy cache always labelled historical and identity unverified")

        let launcher = try cli.makeTerminalScript(profile: managed, login: false, scriptsRoot: registry.root.appendingPathComponent("launchers"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path]
        var terminalEnvironment = environment
        terminalEnvironment["ANTHROPIC_RUNTIME_ONLY"] = "fake-terminal-secret"
        terminalEnvironment["CLAUDE_CODE_USE_RUNTIME_ONLY"] = "1"
        process.environment = terminalEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Isolated launcher exits")
        try require(try String(contentsOf: trace, encoding: .utf8) == managed.configDirectory + "\n",
                    "Runtime Terminal overrides scrubbed and managed directory selected")
        let permissions = try fm.attributesOfItem(atPath: launcher.path)[.posixPermissions] as! NSNumber
        try require(permissions.intValue == 0o700, "Launcher is private")

        let bridge = root.appendingPathComponent("ClaudeStatuslineBridge.py")
        try AtomicFileWriter.write(Data("# fixture never executed\n".utf8), to: bridge)
        let installer = ClaudeBridgeInstaller(root: registry.root, bridgeURL: bridge,
                                              pythonURL: URL(fileURLWithPath: "/usr/bin/true"))
        try installer.install(profile: defaultProfile, auth: auth)
        try installer.install(profile: defaultProfile, auth: auth)
        var installed = try readJSON(settingsURL)
        let line = installed["statusLine"] as! [String: Any]
        try require(line["padding"] as? Int == 2 && line["refreshInterval"] as? Int == 12,
                    "Installer preserves statusLine fields")
        let command = line["command"] as! String
        try require(command.components(separatedBy: "ClaudeStatuslineBridge.py").count == 2 && command.contains("--previous-command"),
                    "Reinstall is idempotent and preserves default command")
        try require(command.contains("'--previous-timeout' '10'"), "Installed bridge gives existing statusline bounded 10-second allowance")
        installed["theme"] = "dark"
        try writeJSON(installed, settingsURL)
        try installer.restore(profile: defaultProfile)
        let restored = try readJSON(settingsURL)
        try require(restored["theme"] as? String == "dark", "Restore preserves unrelated settings changed since install")
        try require((restored["statusLine"] as! NSDictionary) == (originalSettings["statusLine"] as! NSDictionary),
                    "Restore restores full original statusLine")
        try require(try Data(contentsOf: credentialsURL) == sentinel, "Installer never touches auth")
        try installer.install(profile: defaultProfile, auth: auth)
        let originalURL = registry.root.appendingPathComponent("bridge-originals/\(defaultProfile.id).json")
        let originalBackup = try Data(contentsOf: originalURL)
        let installedBytes = try Data(contentsOf: settingsURL)
        try AtomicFileWriter.write(Data("broken".utf8), to: originalURL)
        try expectFailure("Reinstall with corrupt original must fail") { try installer.install(profile: defaultProfile, auth: auth) }
        try require(try Data(contentsOf: settingsURL) == installedBytes, "Corrupt backup fails without replacing settings")
        try AtomicFileWriter.write(originalBackup, to: originalURL)
        try installer.restore(profile: defaultProfile)

        let managedSettings = URL(fileURLWithPath: managed.configDirectory).appendingPathComponent("settings.json")
        try writeJSON(["statusLine": ["type": "command", "command": "printf managed", "padding": 1]], managedSettings)
        try installer.install(profile: managed, auth: auth)
        let managedCommand = (try readJSON(managedSettings)["statusLine"] as! [String: Any])["command"] as! String
        try require(managedCommand.contains("--previous-command") && managedCommand.contains("printf managed"),
                    "Custom managed statusLine is preserved without importing default")
        try installer.restore(profile: managed)

        let store = ClaudeProfileStore(environment: environment, bridgeURL: bridge)
        var callbackCount = 0
        store.onChange = { callbackCount += 1 }
        store.select(id: managed.id)
        store.refresh()
        let deadline = Date().addingTimeInterval(10)
        while store.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(!store.isRefreshing && store.statuses[managed.id]?.auth?.email == auth.email,
                    "Observable store asynchronously refreshes fake profile auth")
        try require(callbackCount > 0 && store.selectedID == managed.id, "Store selection and menu callback")
        let managedBytesBeforePendingInstall = try Data(contentsOf: managedSettings)
        let delayedAuth = "#!/bin/sh\n/bin/sleep 0.2\nprintf '{\"loggedIn\":true,\"email\":\"fixture@example.test\",\"orgId\":\"org-fixture\"}'\n"
        try AtomicFileWriter.write(Data(delayedAuth.utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        store.installBridge(id: managed.id)
        try require(store.statuses[managed.id]?.busy == true, "Bridge installation publishes pending operation")
        store.refresh()
        try require(store.statuses[managed.id]?.busy == true, "Refresh preserves pending bridge operation state")
        store.restoreBridge(id: managed.id)
        try require(store.error != nil, "Restore cannot race a pending bridge install")
        store.removeProfile(id: managed.id)
        try require(store.error == nil && !store.profiles.contains(where: { $0.id == managed.id }), "Store removes managed metadata")
        try require(fm.fileExists(atPath: managed.configDirectory), "Removing profile preserves authentication/history directory")
        try await Task.sleep(nanoseconds: 600_000_000)
        try require(store.statuses[managed.id] == nil, "Removed profiles cannot receive late auth/install status")
        try require(try Data(contentsOf: managedSettings) == managedBytesBeforePendingInstall,
                    "A pending bridge install does not modify a profile removed before auth completed")
        try require(!store.isRefreshing, "Refresh excluding pending profile completes normally")

        // Authentication failures are bounded without a Keychain or network request.
        try AtomicFileWriter.write(Data("#!/bin/sh\nprintf '{\"loggedIn\":true,\"email\":\"fast-exit@example.test\"}'\nexit 0\n".utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for _ in 0..<64 {
            try require(try cli.authStatus(profile: defaultProfile).email == "fast-exit@example.test",
                        "Fast-exiting auth status retains the child's final JSON output")
        }
        try AtomicFileWriter.write(Data("#!/bin/sh\nwhile true; do printf '1234567890'; done\n".utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let oversizedStart = Date()
        try expectFailure("Auth status output cap must reject noisy CLI") { _ = try cli.authStatus(profile: defaultProfile) }
        try require(Date().timeIntervalSince(oversizedStart) < 2, "Auth status output remains bounded at 65KB")
        try AtomicFileWriter.write(Data("#!/bin/sh\nprintf '{\"loggedIn\":false}'\nexit 1\n".utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try require(try cli.authStatus(profile: defaultProfile).loggedIn == false, "Logged-out status remains valid at CLI exit1")
        try AtomicFileWriter.write(Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let start = Date()
        try expectFailure("Auth status must time out") { _ = try cli.authStatus(profile: defaultProfile, timeout: 0.1) }
        try require(Date().timeIntervalSince(start) < 2, "Auth status timeout bounded")
        try AtomicFileWriter.write(Data("corrupt registry sentinel".utf8), to: registry.registryURL)
        try expectFailure("Corrupt registry must fail closed") { _ = try registry.add(label: "New") }
        try require(try String(contentsOf: registry.registryURL, encoding: .utf8) == "corrupt registry sentinel",
                    "Corrupt registry is never overwritten")
        print("Claude integration checks passed (isolated fake CLI, account binding, registry, installer, launcher, async store).")
    }
}
