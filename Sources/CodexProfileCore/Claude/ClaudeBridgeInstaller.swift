import Foundation

/// Updates only statusLine, saving its prior value so removal preserves other settings.
public struct ClaudeBridgeInstaller {
    private let root: URL
    private let bridgeURL: URL?
    private let pythonURL: URL?
    private let fileManager: FileManager

    public init(root: URL, bridgeURL: URL?, pythonURL: URL? = URL(fileURLWithPath: "/usr/bin/python3"),
                fileManager: FileManager = .default) {
        self.root = root
        self.bridgeURL = bridgeURL
        self.pythonURL = pythonURL
        self.fileManager = fileManager
    }

    public func isInstalled(profile: ClaudeProfile) -> Bool {
        guard let settings = try? self.readSettings(profile),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return self.isOurCommand(command, profile: profile)
    }

    public func install(profile: ClaudeProfile, auth: ClaudeAuthInfo?) throws {
        guard let bridgeURL, self.fileManager.fileExists(atPath: bridgeURL.path) else {
            throw ClaudeIntegrationError.bridgeMissing
        }
        guard let pythonURL, self.fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw ClaudeIntegrationError.pythonMissing
        }
        try CacheLock.withLock(at: self.root.appendingPathComponent("bridge-settings.lock")) {
            var settings = try self.readSettings(profile)
            let existing = settings["statusLine"]
            var previousCommand: String?
            let backupURL = self.originalURL(profile)
            let alreadyInstalled = self.isInstalled(profile: profile)
            if alreadyInstalled {
                let original = try self.readOriginal(profile)
                if original["hadStatusLine"] as? Bool == true {
                    previousCommand = (original["statusLine"] as? [String: Any])?["command"] as? String
                }
            } else {
                if let existing {
                    guard let object = existing as? [String: Any], object["type"] as? String == "command",
                          let command = object["command"] as? String else {
                        throw ClaudeIntegrationError.settingsUnsupported
                    }
                    previousCommand = command
                }
                var original: [String: Any] = ["schemaVersion": 1, "profileID": profile.id,
                                                "configDirectory": profile.configDirectory,
                                                "hadStatusLine": existing != nil]
                if let existing { original["statusLine"] = existing }
                // A complete backup is additionally kept, without ever restoring unrelated settings.
                let fullBackup = self.root.appendingPathComponent("backups", isDirectory: true)
                    .appendingPathComponent("\(profile.id)-\(UUID().uuidString)-settings.json")
                try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
                                           to: fullBackup)
                try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys]),
                                           to: backupURL)
            }
            let output = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
                .appendingPathComponent(ClaudeUsageReader.nativeSnapshotName)
            var arguments = [pythonURL.path, bridgeURL.path, "--profile-id", profile.id,
                             "--config-dir", profile.configDirectory, "--output", output.path]
            if let digest = ClaudeUsageReader.accountFingerprint(auth) {
                arguments += ["--auth-identity-digest", digest]
            }
            if let previousCommand, !previousCommand.isEmpty {
                arguments += ["--previous-command", previousCommand, "--previous-timeout", "10"]
            }
            var installedLine = existing as? [String: Any] ?? [:]
            installedLine["type"] = "command"
            installedLine["command"] = arguments.map(ClaudeCLIService.shellQuote).joined(separator: " ")
            settings["statusLine"] = installedLine
            let destination = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
                .appendingPathComponent("settings.json")
            try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
                                       to: destination)
        }
    }

    public func restore(profile: ClaudeProfile) throws {
        try CacheLock.withLock(at: self.root.appendingPathComponent("bridge-settings.lock")) {
            var settings = try self.readSettings(profile)
            guard let current = settings["statusLine"] as? [String: Any],
                  let command = current["command"] as? String,
                  self.isOurCommand(command, profile: profile) else {
                throw ClaudeIntegrationError.settingsUnsupported
            }
            let original = try self.readOriginal(profile)
            if original["hadStatusLine"] as? Bool == true {
                guard let saved = original["statusLine"] else { throw ClaudeIntegrationError.settingsUnsupported }
                settings["statusLine"] = saved
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            let destination = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
                .appendingPathComponent("settings.json")
            try AtomicFileWriter.write(JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
                                       to: destination)
        }
    }

    private func originalURL(_ profile: ClaudeProfile) -> URL {
        self.root.appendingPathComponent("bridge-originals", isDirectory: true)
            .appendingPathComponent("\(profile.id).json")
    }

    private func readOriginal(_ profile: ClaudeProfile) throws -> [String: Any] {
        let data = try Data(contentsOf: self.originalURL(profile))
        guard data.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1,
              json["profileID"] as? String == profile.id,
              json["configDirectory"] as? String == profile.configDirectory else {
            throw ClaudeIntegrationError.settingsUnsupported
        }
        return json
    }

    private func isOurCommand(_ command: String, profile: ClaudeProfile) -> Bool {
        command.contains("ClaudeStatuslineBridge.py") &&
        command.contains("'--profile-id' " + ClaudeCLIService.shellQuote(profile.id)) &&
        command.contains("'--config-dir' " + ClaudeCLIService.shellQuote(profile.configDirectory))
    }

    private func readSettings(_ profile: ClaudeProfile) throws -> [String: Any] {
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        // Refuse symlink settings/directories before any backup or write.
        for target in [directory, url] {
            if let attrs = try? self.fileManager.attributesOfItem(atPath: target.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ClaudeIntegrationError.settingsUnsupported
            }
        }
        guard self.fileManager.fileExists(atPath: url.path) else { return [:] }
        let attrs = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw ClaudeIntegrationError.settingsUnsupported
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeIntegrationError.settingsUnsupported
            }
            return json
        } catch { throw ClaudeIntegrationError.settingsUnsupported }
    }
}
