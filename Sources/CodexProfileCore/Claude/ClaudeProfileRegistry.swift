import Foundation

public struct ClaudeProfileRegistryState: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var profiles: [ClaudeProfile]
    public var selectedID: String
}

/// Stores metadata only. Authentication remains entirely owned by Claude Code.
public final class ClaudeProfileRegistry {
    public static let defaultID = "claude-default"
    public let root: URL
    public let registryURL: URL
    public let defaultDirectory: URL
    private let fileManager: FileManager

    public init(paths: AppPaths, fileManager: FileManager = .default) {
        self.root = paths.switcherHome.appendingPathComponent("claude", isDirectory: true)
        self.registryURL = self.root.appendingPathComponent("profiles.json")
        let claudeHome = paths.environment["CLAUDE_PROFILE_USER_HOME"].flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } ?? paths.userHome
        self.defaultDirectory = claudeHome.appendingPathComponent(".claude", isDirectory: true)
        self.fileManager = fileManager
    }

    public var defaultProfile: ClaudeProfile {
        ClaudeProfile(id: Self.defaultID, label: "Existing Claude", configDirectory: self.defaultDirectory.path,
                      isDefault: true)
    }

    public func load() throws -> ClaudeProfileRegistryState {
        guard self.fileManager.fileExists(atPath: self.registryURL.path) else {
            return ClaudeProfileRegistryState(profiles: [self.defaultProfile], selectedID: Self.defaultID)
        }
        let state: ClaudeProfileRegistryState
        do {
            let data = try Data(contentsOf: self.registryURL)
            guard data.count <= 1_048_576 else { throw ClaudeIntegrationError.invalidRegistry }
            state = try JSONDecoder().decode(ClaudeProfileRegistryState.self, from: data)
        } catch { throw ClaudeIntegrationError.invalidRegistry }
        guard state.schemaVersion == 1, !state.profiles.isEmpty,
              state.profiles.count <= 200,
              Set(state.profiles.map(\.id)).count == state.profiles.count,
              state.profiles.contains(where: { $0.id == state.selectedID }),
              state.profiles.filter(\.isDefault).count == 1 else {
            throw ClaudeIntegrationError.invalidRegistry
        }
        for profile in state.profiles {
            guard self.isValid(profile), Self.validLabel(profile.label) else {
                throw ClaudeIntegrationError.invalidRegistry
            }
        }
        return state
    }

    public func isValid(_ profile: ClaudeProfile) -> Bool {
        if profile.isDefault {
            return profile.id == Self.defaultID && profile.configDirectory == self.defaultDirectory.path
        }
        guard let uuid = UUID(uuidString: profile.id) else { return false }
        let expected = self.root.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true)
        return profile.configDirectory == expected.path
    }

    public func add(label: String) throws -> ClaudeProfileRegistryState {
        let trimmed = try Self.normalizedLabel(label)
        return try self.mutate { state in
            let id = UUID().uuidString
            let directory = self.root.appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try AtomicFileWriter.ensurePrivateDirectory(directory)
            state.profiles.append(ClaudeProfile(id: id, label: trimmed, configDirectory: directory.path))
            state.selectedID = id
        }
    }

    public func rename(id: String, label: String) throws -> ClaudeProfileRegistryState {
        let trimmed = try Self.normalizedLabel(label)
        return try self.mutate { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
                throw ClaudeIntegrationError.invalidProfile
            }
            state.profiles[index].label = trimmed
        }
    }

    /// Removes the entry only; the directory, Keychain item, history and plugins are preserved.
    public func remove(id: String) throws -> ClaudeProfileRegistryState {
        try self.mutate { state in
            guard let profile = state.profiles.first(where: { $0.id == id }) else {
                throw ClaudeIntegrationError.invalidProfile
            }
            guard !profile.isDefault else { throw ClaudeIntegrationError.defaultProfileRemoval }
            state.profiles.removeAll(where: { $0.id == id })
            if state.selectedID == id { state.selectedID = Self.defaultID }
        }
    }

    public func select(id: String) throws -> ClaudeProfileRegistryState {
        try self.mutate { state in
            guard state.profiles.contains(where: { $0.id == id }) else {
                throw ClaudeIntegrationError.invalidProfile
            }
            state.selectedID = id
        }
    }

    private func mutate(_ change: (inout ClaudeProfileRegistryState) throws -> Void) throws -> ClaudeProfileRegistryState {
        try CacheLock.withLock(at: self.root.appendingPathComponent("profiles.lock")) {
            var state = try self.load()
            try change(&state)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFileWriter.write(encoder.encode(state), to: self.registryURL)
            return state
        }
    }

    private static func normalizedLabel(_ label: String) throws -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validLabel(label) else { throw ClaudeIntegrationError.invalidLabel }
        return label
    }

    private static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 80 && label.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
