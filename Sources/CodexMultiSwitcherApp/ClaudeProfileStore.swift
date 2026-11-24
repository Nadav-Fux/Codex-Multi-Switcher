import AppKit
import CodexProfileCore
import Combine
import Foundation

/// Independent from Codex profiles: selecting here affects only the next NEW Claude process.
@MainActor
final class ClaudeProfileStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published private(set) var statuses: [String: ClaudeProfileStatus] = [:]
    @Published private(set) var selectedID = ClaudeProfileRegistry.defaultID
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizingCredential = false
    @Published private(set) var nextUsageRefresh: [String: Date] = [:]
    var onChange: (() -> Void)?

    private let registry: ClaudeProfileRegistry
    private let cli: ClaudeCLIService
    private let installer: ClaudeBridgeInstaller
    private let scriptsRoot: URL
    private let currentUsage: ClaudeCurrentUsageService
    private let quotaRefreshPolicy: ClaudeQuotaRefreshPolicy
    private let priorQuotaURL: URL
    private let claudeUserHome: URL
    private var refreshTask: Task<Void, Never>?
    private var pendingBridgeOperations: Set<String> = []
    private var pendingConnectID: String?
    private var lastCodeUsageRefresh: [String: Date] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         bridgeURL: URL? = Bundle.main.url(forResource: "ClaudeStatuslineBridge", withExtension: "py"),
         currentUsageService: ClaudeCurrentUsageService? = nil,
         quotaRefreshPolicy: ClaudeQuotaRefreshPolicy? = nil) {
        let paths = AppPaths(environment: environment)
        self.registry = ClaudeProfileRegistry(paths: paths)
        self.claudeUserHome = self.registry.defaultDirectory.deletingLastPathComponent()
        self.cli = ClaudeCLIService(environment: environment, userHome: self.claudeUserHome)
        self.installer = ClaudeBridgeInstaller(root: self.registry.root, bridgeURL: bridgeURL)
        self.scriptsRoot = self.registry.root.appendingPathComponent("launchers", isDirectory: true)
        self.currentUsage = currentUsageService ?? ClaudeCurrentUsageService(root: self.registry.root, helper: ClaudeUsageHelperClient.bundled())
        self.quotaRefreshPolicy = quotaRefreshPolicy ?? ClaudeQuotaRefreshPolicy(root: self.registry.root)
        self.priorQuotaURL = self.registry.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Library/Application Support/Codex Multi Switcher/Claude Usage Helper/usage-observations/claude-default.json")
        if currentUsageService == nil {
            let removed = ClaudeUsageHelperClient.bundled().clearStaleAccessBlocks()
            if removed > 0 { CoreLogger.info("Removed stale Claude helper access flags", metadata: ["count": String(removed)]) }
        }
        do { self.apply(try self.registry.load()) }
        catch {
            self.profiles = [self.registry.defaultProfile]
            self.error = error.localizedDescription
        }
    }

    /// `force` is for an explicit Refresh click or a finished Connect: it asks Claude Code and
    /// the helper again right away instead of reusing a recent (possibly failed) observation.
    func refresh(force: Bool = false) {
        guard !self.isRefreshing, !self.isAuthorizingCredential else { return }
        self.error = nil
        do { self.apply(try self.registry.load()) }
        catch { self.error = error.localizedDescription; self.onChange?(); return }
        self.isRefreshing = true
        let profiles = self.profiles.filter { !self.pendingBridgeOperations.contains($0.id) }
        for profile in profiles {
            var status = self.statuses[profile.id] ?? ClaudeProfileStatus()
            status.busy = true
            status.error = nil
            self.statuses[profile.id] = status
        }
        let cli = self.cli
        let currentUsage = self.currentUsage
        let quotaRefreshPolicy = self.quotaRefreshPolicy
        let priorQuotaURL = self.priorQuotaURL
        let userHome = self.claudeUserHome
        // Ask Claude Code itself to refresh its usage cache (`claude -p /usage`, no model call) at
        // most every 4 minutes per profile, or 30 seconds apart when the user asked for it.
        let now = Date()
        let refreshExecutable = ClaudeCodeUsageRefresher.isEnabled ? cli.discoverExecutable() : nil
        var codeRefreshDue: Set<String> = []
        for profile in profiles {
            let last = self.lastCodeUsageRefresh[profile.id] ?? .distantPast
            if refreshExecutable != nil, now.timeIntervalSince(last) >= (force ? 30 : 240) {
                codeRefreshDue.insert(profile.id)
                self.lastCodeUsageRefresh[profile.id] = now
            }
        }
        self.refreshTask = Task { [weak self] in
            // Bound concurrent metadata and usage reads for large profile registries.
            await withTaskGroup(of: (String, ClaudeProfileStatus, Date?).self) { group in
                var pending = profiles.makeIterator()
                func enqueue(_ profile: ClaudeProfile) {
                    group.addTask {
                        var status = ClaudeProfileStatus()
                        var nextRefresh: Date?
                        do { status.auth = try cli.identityMetadata(profile: profile) }
                        catch {
                            status.error = error.localizedDescription
                            CoreLogger.warning("Claude quota unavailable", metadata: ["category": "auth_status_unavailable"])
                        }
                        let usage = ClaudeUsageReader.read(profile: profile, auth: status.auth)
                        if let warning = usage.warning { status.error = warning }
                        // Claude Code caches its own usage reads in its config file. That needs no
                        // Keychain access, so it keeps working after Claude Code rewrites its login.
                        var codeCache = ClaudeCodeUsageCache.read(profile: profile, auth: status.auth, userHome: userHome)
                        let codeCacheIsRecent = codeCache.map { Date().timeIntervalSince($0.observedAt) < 180 } ?? false
                        if codeRefreshDue.contains(profile.id), !codeCacheIsRecent || force,
                           let executable = refreshExecutable, status.auth?.accountID != nil,
                           ClaudeCodeUsageRefresher.run(executable: executable,
                                                        environment: cli.sanitizedEnvironment(profile: profile)) {
                            codeCache = ClaudeCodeUsageCache.read(profile: profile, auth: status.auth, userHome: userHome)
                        }
                        let local = [usage.snapshot, codeCache].compactMap { $0 }
                        let localMatched = local.filter(\.accountMatched)
                        status.usage = (localMatched.isEmpty ? local : localMatched).max { $0.observedAt < $1.observedAt }
                        // Prefer recent local observations. Only poll the API when neither the
                        // account-matched bridge nor Claude Code's cache supplies current usage.
                        let freshLocal = status.usage.map { $0.accountMatched && !$0.isStale } ?? false
                        if currentUsage.supports(profile), let auth = status.auth,
                           let identity = ClaudeUsageReader.accountFingerprint(auth), !freshLocal {
                            do {
                                let seed = currentUsage.cached(profile: profile, auth: auth)
                                    ?? ClaudeQuotaRefreshPolicy.priorObservation(at: priorQuotaURL, profile: profile, identity: identity)
                                let observation = await quotaRefreshPolicy.read(identity: identity, seed: seed, force: force) {
                                    try await currentUsage.fetch(profile: profile, authBefore: auth,
                                        authAfter: { try cli.identityMetadata(profile: profile) }, force: force)
                                }
                                guard ClaudeUsageReader.accountFingerprint(try cli.identityMetadata(profile: profile)) == identity else {
                                    throw ClaudeCurrentUsageError.accountChanged
                                }
                                nextRefresh = observation.nextRefreshAt
                                let observations = [status.usage, observation.snapshot].compactMap { $0 }
                                let matched = observations.filter(\.accountMatched)
                                status.usage = (matched.isEmpty ? observations : matched).max { $0.observedAt < $1.observedAt }
                                if observation.failure == .accountChanged { status.usage = nil }
                                status.error = observation.failure?.localizedDescription
                            } catch {
                                let category = (error as? ClaudeCurrentUsageError).map { String(describing: $0) } ?? "request_failed"
                                CoreLogger.warning("Claude quota unavailable", metadata: ["category": category])
                                // Recheck local identity after failed network/renewal attempts before
                                // reusing any observation; an account switch can happen in flight.
                                if case ClaudeCurrentUsageError.accountChanged = error {
                                    status.usage = nil
                                } else {
                                    if let after = try? cli.identityMetadata(profile: profile),
                                       ClaudeUsageReader.accountFingerprint(after) == ClaudeUsageReader.accountFingerprint(auth) {
                                        status.auth = after
                                        let bridge = ClaudeUsageReader.read(profile: profile, auth: after).snapshot
                                        let cached = currentUsage.cached(profile: profile, auth: after)
                                        let codeCache = ClaudeCodeUsageCache.read(profile: profile, auth: after, userHome: userHome)
                                        let observations = [cached, bridge, codeCache].compactMap { $0 }
                                        let matched = observations.filter(\.accountMatched)
                                        status.usage = (matched.isEmpty ? observations : matched).max { $0.observedAt < $1.observedAt }
                                    } else {
                                        status.usage = nil
                                    }
                                }
                                status.error = error.localizedDescription
                            }
                        }
                        return (profile.id, status, nextRefresh)
                    }
                }
                for _ in 0..<3 { if let profile = pending.next() { enqueue(profile) } }
                for await (id, var status, nextRefresh) in group {
                    guard let self else { group.cancelAll(); return }
                    if let profile = self.profiles.first(where: { $0.id == id }) {
                        status.bridgeInstalled = self.installer.isInstalled(profile: profile)
                        self.statuses[id] = status
                        self.nextUsageRefresh[id] = nextRefresh
                        self.onChange?()
                    }
                    if let profile = pending.next() { enqueue(profile) }
                }
            }
            guard let self else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.installMissingRecorders()
            let blockedMessage = ClaudeCurrentUsageError.credentialInteractionRequired.localizedDescription
            ClaudeAccessNotifier.update(blocked: self.statuses.values.contains { $0.error == blockedMessage })
            self.onChange?()
            if let id = self.pendingConnectID {
                self.pendingConnectID = nil
                self.connectNativeAccount(id: id)
            }
        }
        self.onChange?()
    }

    func addProfile(label: String) { self.mutate { try self.registry.add(label: label) } }
    func renameProfile(id: String, label: String) { self.mutate { try self.registry.rename(id: id, label: label) } }
    func removeProfile(id: String) { self.mutate { try self.registry.remove(id: id) } }
    func select(id: String) { self.mutate { try self.registry.select(id: id) } }
    func signIn(id: String) { self.launch(id: id, login: true) }
    func openSession(id: String) { self.launch(id: id, login: false) }

    func supportsNativeUsage(_ profile: ClaudeProfile) -> Bool { self.currentUsage.supports(profile) }

    /// One answer for the Settings banner: is usage for this account working,
    /// and if not, what single step fixes it.
    func connectionState(_ profile: ClaudeProfile) -> ClaudeConnectionState {
        let status = self.statuses[profile.id]
        if self.isAuthorizingCredential, self.currentUsage.supports(profile) { return .needsApproval }
        if status?.auth?.loggedIn == false { return .needsSignIn }
        let blocked = [ClaudeCurrentUsageError.credentialInteractionRequired, .credentialUnavailable]
            .map(\.localizedDescription)
        if self.currentUsage.supports(profile), let error = status?.error, blocked.contains(error) { return .needsApproval }
        if status?.busy == true, status?.usage == nil { return .checking }
        if status == nil { return .checking }
        if self.currentUsage.supports(profile) {
            // `loggedIn` is nil (unknown), not false, when no account metadata
            // exists — a never-signed-in default profile must still offer the
            // Sign In action instead of reporting Connected.
            let hasAccountMetadata = status?.auth?.email != nil || status?.auth?.accountID != nil
            if !hasAccountMetadata, status?.usage == nil { return .needsSignIn }
            if let error = status?.error, status?.usage == nil { return .problem(error) }
            return .connected("Usage updates automatically in the background.")
        }
        if status?.bridgeInstalled == true {
            return .connected(status?.usage == nil
                ? "Usage appears after the first Claude reply in a session opened with this account."
                : "Usage updates from Claude sessions opened with this account.")
        }
        if let error = status?.error { return .problem(error) }
        return .checking
    }

    /// The click authorizes only an existing native Claude credential read.
    /// Run Security off the main actor so the macOS consent dialog stays usable.
    func connectNativeAccount(id: String) {
        guard !self.isAuthorizingCredential,
              let profile = self.profile(id), self.currentUsage.supports(profile) else { return }
        // A click during a background refresh used to be dropped silently. Run it right after.
        if self.isRefreshing {
            self.pendingConnectID = id
            self.statuses[id]?.busy = true
            self.onChange?()
            CoreLogger.info("Claude Connect queued until the current refresh ends", metadata: [:])
            return
        }
        CoreLogger.info("Claude Connect started", metadata: [:])
        self.error = nil
        self.isAuthorizingCredential = true
        self.statuses[id]?.busy = true
        NSApp.activate(ignoringOtherApps: true)
        let currentUsage = self.currentUsage
        Task { [weak self] in
            do {
                try await Task.detached {
                    try currentUsage.authorizeNativeCredentialAccess(profile: profile)
                }.value
                guard let self else { return }
                CoreLogger.info("Claude Connect succeeded", metadata: [:])
                self.isAuthorizingCredential = false
                self.statuses[id]?.busy = false
                self.statuses[id]?.error = nil
                self.refresh(force: true)
            } catch {
                guard let self else { return }
                let category = (error as? ClaudeCurrentUsageError).map { String(describing: $0) } ?? "other"
                CoreLogger.warning("Claude Connect failed", metadata: ["category": category])
                self.isAuthorizingCredential = false
                self.statuses[id]?.busy = false
                self.statuses[id]?.error = error.localizedDescription
                self.error = error.localizedDescription
                self.onChange?()
            }
        }
        self.onChange?()
    }

    private static func recorderOptOutKey(_ id: String) -> String { "claudeBridgeOptOut.\(id)" }

    /// Separate accounts can only report usage through their statusline
    /// recorder, so install it once the account is signed in — unless the
    /// user removed it on purpose.
    private func installMissingRecorders() {
        for profile in self.profiles where !self.currentUsage.supports(profile) {
            guard let status = self.statuses[profile.id], !status.bridgeInstalled, !status.busy,
                  status.auth?.email != nil || status.auth?.accountID != nil,
                  !UserDefaults.standard.bool(forKey: Self.recorderOptOutKey(profile.id)) else { continue }
            CoreLogger.info("Installing Claude usage recorder for a separate account")
            self.installBridge(id: profile.id)
        }
    }

    func installBridge(id: String) {
        UserDefaults.standard.removeObject(forKey: Self.recorderOptOutKey(id))
        self.error = nil
        guard let profile = self.profile(id) else { return }
        var status = self.statuses[id] ?? ClaudeProfileStatus()
        guard !status.busy, !self.pendingBridgeOperations.contains(id) else {
            self.error = "Wait for the Claude operation to finish."
            self.onChange?()
            return
        }
        self.pendingBridgeOperations.insert(id)
        status.busy = true
        self.statuses[id] = status
        let cli = self.cli
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.pendingBridgeOperations.remove(id)
                self.statuses[id]?.busy = false
                self.onChange?()
            }
            do {
                // Verify the current identity at installation, rather than using an older UI status.
                let auth = try await Task.detached { try cli.identityMetadata(profile: profile) }.value
                guard self.profiles.contains(where: { $0.id == id }) else { return }
                guard auth.email != nil || auth.accountID != nil else {
                    self.error = "Sign in to this Claude profile so its account metadata is available before installing its usage bridge."
                    return
                }
                try self.installer.install(profile: profile, auth: auth)
                self.statuses[id]?.auth = auth
                self.statuses[id]?.bridgeInstalled = true
                self.statuses[id]?.usage = ClaudeUsageReader.read(profile: profile, auth: auth).snapshot
            } catch {
                // A removed entry cannot receive a late error/status update.
                if self.profiles.contains(where: { $0.id == id }) {
                    self.error = error.localizedDescription
                }
            }
        }
        self.onChange?()
    }

    func restoreBridge(id: String) {
        self.error = nil
        guard let profile = self.profile(id) else { return }
        guard !self.pendingBridgeOperations.contains(id) else {
            self.error = "Wait for the Claude bridge installation to finish before restoring its statusline."
            self.onChange?()
            return
        }
        do {
            try self.installer.restore(profile: profile)
            self.statuses[id]?.bridgeInstalled = false
            UserDefaults.standard.set(true, forKey: Self.recorderOptOutKey(id))
        } catch { self.error = error.localizedDescription }
        self.onChange?()
    }

    private func launch(id: String, login: Bool) {
        self.error = nil
        guard let profile = self.profile(id) else { return }
        do {
            let script = try self.cli.makeTerminalScript(profile: profile, login: login, scriptsRoot: self.scriptsRoot)
            let configuration = NSWorkspace.OpenConfiguration()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
                if error != nil {
                    Task { @MainActor [weak self] in
                        self?.error = ClaudeIntegrationError.launchFailed.localizedDescription
                        self?.onChange?()
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
        self.onChange?()
    }

    private func profile(_ id: String) -> ClaudeProfile? {
        guard let profile = self.profiles.first(where: { $0.id == id }), self.registry.isValid(profile) else {
            self.error = ClaudeIntegrationError.invalidProfile.localizedDescription
            self.onChange?()
            return nil
        }
        return profile
    }

    private func mutate(_ operation: () throws -> ClaudeProfileRegistryState) {
        self.error = nil
        do { self.apply(try operation()) }
        catch { self.error = error.localizedDescription }
        self.onChange?()
    }

    private func apply(_ state: ClaudeProfileRegistryState) {
        self.profiles = state.profiles
        self.selectedID = state.selectedID
        let ids = Set(state.profiles.map(\.id))
        self.statuses = self.statuses.filter { ids.contains($0.key) }
    }
}

/// One plain answer to "is Claude working?", shown at the top of Settings.
enum ClaudeConnectionState: Equatable {
    case checking
    case connected(String)
    case needsSignIn
    case needsApproval
    case problem(String)

    var isHealthy: Bool { if case .connected = self { return true } else { return false } }
}

/// Reads the usage Claude Code itself caches in its config file (`cachedUsageUtilization`).
/// Only that block and its account id are used; nothing else in the file is read or logged.
enum ClaudeCodeUsageCache {
    /// Claude Code rewrites this cache every few minutes while it is in use, not on a fixed
    /// timer, so allow longer than the helper's 5 minutes before treating it as old.
    static let staleAfter: TimeInterval = 900

    static func read(profile: ClaudeProfile, auth: ClaudeAuthInfo?, userHome: URL,
                     now: Date = Date(), fileManager: FileManager = .default) -> ClaudeUsageSnapshot? {
        guard let accountID = auth?.accountID, !accountID.isEmpty else { return nil }
        let url: URL
        if profile.isDefault {
            url = userHome.appendingPathComponent(".claude.json")
        } else {
            let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
            let legacy = directory.appendingPathComponent(".config.json")
            url = fileManager.fileExists(atPath: legacy.path) ? legacy : directory.appendingPathComponent(".claude.json")
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_777_216,
              let data = try? Data(contentsOf: url),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = document["cachedUsageUtilization"] as? [String: Any],
              cache["accountUuid"] as? String == accountID,
              let fetchedMs = Self.number(cache["fetchedAtMs"]),
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        let observedAt = Date(timeIntervalSince1970: fetchedMs / 1000)
        let age = now.timeIntervalSince(observedAt)
        guard age >= -60, age <= 86_400 else { return nil }
        let five = Self.window(utilization["five_hour"])
        let seven = Self.window(utilization["seven_day"])
        guard five != nil || seven != nil else { return nil }
        return ClaudeUsageSnapshot(
            fiveHour: five, sevenDay: seven, modelWeekly: Self.window(utilization["seven_day_opus"]),
            observedAt: observedAt, source: .oauthUsage,
            isStale: age > Self.staleAfter, accountVerified: true,
            resets: ClaudeLimitReset.parse(utilization["cedar_ember"]))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard let window = value as? [String: Any], let used = Self.number(window["utilization"]),
              (0...100).contains(used) else { return nil }
        return ClaudeUsageWindow(usedPercentage: used, resetsAt: Self.date(window["resets_at"]))
    }

    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String else { return nil }
        // Claude Code writes microseconds; ISO8601DateFormatter accepts at most milliseconds.
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            if digits.count > 3 { text.replaceSubrange(text.index(dot, offsetBy: 4)..<end, with: "") }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Runs `claude -p /usage`: Claude Code reads its own login, asks the server for usage and
/// rewrites `cachedUsageUtilization`. It makes no model call. If a run ever reports turns,
/// tokens or cost, the refresher turns itself off for good and logs why.
enum ClaudeCodeUsageRefresher {
    private static let disabledKey = "claudeCodeUsageRefreshDisabled"
    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: Self.disabledKey) }

    static func run(executable: URL, environment: [String: String], timeout: TimeInterval = 45) -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("claude-usage-refresh-" + UUID().uuidString)
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? fileManager.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.json")
        guard fileManager.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "project"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            try? handle.close()
            CoreLogger.warning("Claude usage refresh could not start", metadata: [:])
            return false
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            try? handle.close()
            CoreLogger.warning("Claude usage refresh timed out", metadata: [:])
            return false
        }
        try? handle.close()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: output), data.count <= 262_144,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            CoreLogger.warning("Claude usage refresh failed", metadata: ["status": String(process.terminationStatus)])
            return false
        }
        let usage = result["usage"] as? [String: Any] ?? [:]
        let spent = [result["num_turns"], result["total_cost_usd"], usage["input_tokens"], usage["output_tokens"]]
            .map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        guard spent.allSatisfy({ $0 == 0 }) else {
            UserDefaults.standard.set(true, forKey: Self.disabledKey)
            CoreLogger.warning("Claude usage refresh used model tokens and is now off", metadata: [:])
            return false
        }
        return result["is_error"] as? Bool != true
    }
}
