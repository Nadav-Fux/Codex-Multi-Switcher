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
    var onChange: (() -> Void)?

    private let registry: ClaudeProfileRegistry
    private let cli: ClaudeCLIService
    private let installer: ClaudeBridgeInstaller
    private let scriptsRoot: URL
    private var refreshTask: Task<Void, Never>?
    private var pendingBridgeOperations: Set<String> = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         bridgeURL: URL? = Bundle.main.url(forResource: "ClaudeStatuslineBridge", withExtension: "py")) {
        let paths = AppPaths(environment: environment)
        self.registry = ClaudeProfileRegistry(paths: paths)
        self.cli = ClaudeCLIService(environment: environment, userHome: self.registry.defaultDirectory.deletingLastPathComponent())
        self.installer = ClaudeBridgeInstaller(root: self.registry.root, bridgeURL: bridgeURL)
        self.scriptsRoot = self.registry.root.appendingPathComponent("launchers", isDirectory: true)
        do { self.apply(try self.registry.load()) }
        catch {
            self.profiles = [self.registry.defaultProfile]
            self.error = error.localizedDescription
        }
    }

    func refresh() {
        guard !self.isRefreshing else { return }
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
        self.refreshTask = Task { [weak self] in
            // Bound CLI concurrency so a large registry cannot spawn arbitrary processes.
            await withTaskGroup(of: (String, ClaudeProfileStatus).self) { group in
                var pending = profiles.makeIterator()
                func enqueue(_ profile: ClaudeProfile) {
                    group.addTask {
                        var status = ClaudeProfileStatus()
                        do { status.auth = try cli.authStatus(profile: profile) }
                        catch { status.error = error.localizedDescription }
                        let usage = ClaudeUsageReader.read(profile: profile, auth: status.auth)
                        status.usage = usage.snapshot
                        if let warning = usage.warning { status.error = warning }
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
                let auth = try await Task.detached { try cli.authStatus(profile: profile) }.value
                guard self.profiles.contains(where: { $0.id == id }) else { return }
                guard auth.loggedIn == true else {
                    self.error = "Sign in to this Claude profile before installing its usage bridge."
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
