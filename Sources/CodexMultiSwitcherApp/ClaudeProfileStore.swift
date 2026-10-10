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
    var onChange: (() -> Void)?

    private let registry: ClaudeProfileRegistry
    private let cli: ClaudeCLIService
    private let installer: ClaudeBridgeInstaller
    private let scriptsRoot: URL
    private let currentUsage: ClaudeCurrentUsageService
    private var refreshTask: Task<Void, Never>?
    private var pendingBridgeOperations: Set<String> = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         bridgeURL: URL? = Bundle.main.url(forResource: "ClaudeStatuslineBridge", withExtension: "py"),
         currentUsageService: ClaudeCurrentUsageService? = nil) {
        let paths = AppPaths(environment: environment)
        self.registry = ClaudeProfileRegistry(paths: paths)
        self.cli = ClaudeCLIService(environment: environment, userHome: self.registry.defaultDirectory.deletingLastPathComponent())
        self.installer = ClaudeBridgeInstaller(root: self.registry.root, bridgeURL: bridgeURL)
        self.scriptsRoot = self.registry.root.appendingPathComponent("launchers", isDirectory: true)
        self.currentUsage = currentUsageService ?? ClaudeCurrentUsageService(root: self.registry.root, helper: ClaudeUsageHelperClient.bundled())
        do { self.apply(try self.registry.load()) }
        catch {
            self.profiles = [self.registry.defaultProfile]
            self.error = error.localizedDescription
        }
    }

    func refresh() {
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
        self.refreshTask = Task { [weak self] in
            // Bound concurrent metadata and usage reads for large profile registries.
            await withTaskGroup(of: (String, ClaudeProfileStatus).self) { group in
                var pending = profiles.makeIterator()
                func enqueue(_ profile: ClaudeProfile) {
                    group.addTask {
                        var status = ClaudeProfileStatus()
                        do { status.auth = try cli.identityMetadata(profile: profile) }
                        catch {
                            status.error = error.localizedDescription
                            CoreLogger.warning("Claude quota unavailable", metadata: ["category": "auth_status_unavailable"])
                        }
                        let usage = ClaudeUsageReader.read(profile: profile, auth: status.auth)
                        status.usage = usage.snapshot
                        if let warning = usage.warning { status.error = warning }
                        // The native account refreshes directly even when no Claude session
                        // is running. Bridge observations remain a fallback for managed accounts.
                        if currentUsage.supports(profile), let auth = status.auth,
                           ClaudeUsageReader.accountFingerprint(auth) != nil {
                            do {
                                status.usage = try await currentUsage.fetch(profile: profile, authBefore: auth,
                                    authAfter: { try cli.identityMetadata(profile: profile) })
                                status.error = nil
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
                                        let observations = [cached, bridge].compactMap { $0 }
                                        let matched = observations.filter(\.accountMatched)
                                        status.usage = (matched.isEmpty ? observations : matched).max { $0.observedAt < $1.observedAt }
                                    } else {
                                        status.usage = nil
                                    }
                                }
                                status.error = error.localizedDescription
                            }
                        }
                        return (profile.id, status)
                    }
                }
                for _ in 0..<3 { if let profile = pending.next() { enqueue(profile) } }
                for await (id, var status) in group {
                    guard let self else { group.cancelAll(); return }
                    if let profile = self.profiles.first(where: { $0.id == id }) {
                        status.bridgeInstalled = self.installer.isInstalled(profile: profile)
                        self.statuses[id] = status
                        self.onChange?()
                    }
                    if let profile = pending.next() { enqueue(profile) }
                }
            }
            guard let self else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.onChange?()
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

    /// The click authorizes only an existing native Claude credential read.
    /// Run Security off the main actor so the macOS consent dialog stays usable.
    func connectNativeAccount(id: String) {
        guard !self.isRefreshing, !self.isAuthorizingCredential,
              let profile = self.profile(id), self.currentUsage.supports(profile) else { return }
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
                self.isAuthorizingCredential = false
                self.statuses[id]?.busy = false
                self.statuses[id]?.error = nil
                self.refresh()
            } catch {
                guard let self else { return }
                self.isAuthorizingCredential = false
                self.statuses[id]?.busy = false
                self.statuses[id]?.error = error.localizedDescription
                self.error = error.localizedDescription
                self.onChange?()
            }
        }
        self.onChange?()
    }

    func installBridge(id: String) {
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
