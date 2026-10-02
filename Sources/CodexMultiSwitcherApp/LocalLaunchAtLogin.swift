import Darwin
import Foundation

/// Local builds use an ordinary per-user LaunchAgent, without a signing account.
/// This helper only edits regular, user-owned plists launching this exact bundle.
enum LocalLaunchAtLogin {
    private static let label = "com.codexmultiswitcher.local.login"
    private static let historicalLabel = "me.nadavfux.codex-multi-switcher.local.login"
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    private static let plistURL = Self.directory.appendingPathComponent("\(Self.label).plist")
    private static let historicalURL = Self.directory.appendingPathComponent("\(Self.historicalLabel).plist")
    private static var bundleURL: URL { Bundle.main.bundleURL.standardizedFileURL }
    private static var domain: String { "gui/\(getuid())" }
    private static var arguments: [String] {
        ["/usr/bin/open", "-a", Self.bundleURL.path, "--args", "--launch-at-login"]
    }

    static var state: LaunchAtLogin.State {
        guard Self.isEligible else { return .unavailable }
        if Self.itemExists(at: Self.plistURL) {
            return Self.validatedData(at: Self.plistURL, label: Self.label) == nil ? .unavailable : .enabled
        }
        return Self.validatedData(at: Self.historicalURL, label: Self.historicalLabel) == nil ? .disabled : .enabled
    }

    static func enable() throws {
        guard Self.isEligible else { throw LaunchAtLogin.OperationError.unavailable }
        try Self.prepareDirectory()
        let existingData = Self.validatedData(at: Self.plistURL, label: Self.label)
        if Self.itemExists(at: Self.plistURL), existingData == nil {
            throw Self.failure("The existing local login item is unexpected; it was left untouched.")
        }

        let data: Data
        if let existingData {
            data = existingData
        } else {
            data = try PropertyListSerialization.data(fromPropertyList: [
                "Label": Self.label,
                "ProgramArguments": Self.arguments,
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ], format: .xml, options: 0)
            try data.write(to: Self.plistURL, options: .withoutOverwriting)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.plistURL.path)
            } catch {
                if Self.validatedData(at: Self.plistURL, label: Self.label) == data {
                    try? FileManager.default.removeItem(at: Self.plistURL)
                }
                throw error
            }
        }

        do {
            if !Self.isLoaded(label: Self.label) {
                try Self.launchctl(["bootstrap", Self.domain, Self.plistURL.path])
            }
        } catch {
            if existingData == nil,
               Self.validatedData(at: Self.plistURL, label: Self.label) == data {
                try? FileManager.default.removeItem(at: Self.plistURL)
            }
            throw error
        }

        // Register the replacement before removing an owned historical item.
        try Self.removeOwnedItem(at: Self.historicalURL, label: Self.historicalLabel, ignoreUnexpected: true)
    }

    static func disable() throws {
        guard Self.isEligible else { throw LaunchAtLogin.OperationError.unavailable }
        try Self.removeOwnedItem(at: Self.plistURL, label: Self.label, ignoreUnexpected: false)
        try Self.removeOwnedItem(at: Self.historicalURL, label: Self.historicalLabel, ignoreUnexpected: true)
    }

    static func migrateLegacyIfNeeded() {
        guard Self.isEligible, Self.itemExists(at: Self.historicalURL) else { return }
        guard Self.validatedData(at: Self.historicalURL, label: Self.historicalLabel) != nil else {
            AppLogger.warning("Historical local login item is unexpected; leaving it untouched")
            return
        }
        do {
            try Self.enable()
            AppLogger.info("Migrated local Launch at Login to the app-owned item")
        } catch {
            AppLogger.warning("Local Launch at Login migration could not finish",
                              metadata: ["error": error.localizedDescription])
        }
    }

    private static var isEligible: Bool {
        guard AppInfo.isLocalBuild, !AppInfo.isPreview,
              Bundle.main.bundleIdentifier == "com.codexmultiswitcher.local",
              Self.bundleURL.pathExtension == "app",
              Self.bundleURL.resolvingSymlinksInPath().standardizedFileURL == Self.bundleURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: Self.bundleURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func prepareDirectory() throws {
        if !Self.itemExists(at: Self.directory) {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        }
        guard Self.isOwnedDirectory else {
            throw Self.failure("The LaunchAgents directory is not a regular directory owned by your user.")
        }
    }

    private static var isOwnedDirectory: Bool {
        var info = stat()
        return lstat(Self.directory.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && (info.st_mode & 0o022) == 0
            && Self.directory.resolvingSymlinksInPath().standardizedFileURL == Self.directory.standardizedFileURL
    }

    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func validatedData(at url: URL, label: String) -> Data? {
        guard Self.isOwnedDirectory,
              let data = Self.readOwnedRegularFile(at: url),
              Self.hasExpectedContents(data, label: label, bundleURL: Self.bundleURL) else { return nil }
        return data
    }

    /// Kept separate from file access so ownership rules can be checked in isolation.
    static func hasExpectedContents(_ data: Data, label: String, bundleURL: URL) -> Bool {
        let expectedArguments = ["/usr/bin/open", "-a", bundleURL.standardizedFileURL.path, "--args", "--launch-at-login"]
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["Label", "ProgramArguments", "RunAtLoad", "LimitLoadToSessionType"]),
              dictionary["Label"] as? String == label,
              dictionary["ProgramArguments"] as? [String] == expectedArguments,
              let runAtLoad = dictionary["RunAtLoad"] as? NSNumber,
              CFGetTypeID(runAtLoad) == CFBooleanGetTypeID(), runAtLoad.boolValue,
              dictionary["LimitLoadToSessionType"] == nil || dictionary["LimitLoadToSessionType"] as? String == "Aqua" else {
            return false
        }
        return true
    }

    private static func readOwnedRegularFile(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0,
              info.st_size >= 0, info.st_size <= 64 * 1024 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }

    private static func removeOwnedItem(at url: URL, label: String, ignoreUnexpected: Bool) throws {
        guard Self.itemExists(at: url) else { return }
        guard let data = Self.validatedData(at: url, label: label) else {
            if ignoreUnexpected {
                AppLogger.warning("Unexpected historical local login item was left untouched")
                return
            }
            throw Self.failure("The local login item is unexpected; it was left untouched.")
        }
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent(".\(label).migration-\(UUID().uuidString).plist")
        try FileManager.default.moveItem(at: url, to: quarantine)
        do {
            guard Self.validatedData(at: quarantine, label: label) == data else {
                throw Self.failure("The local login item changed while it was being checked.")
            }
            if Self.isLoaded(label: label) {
                try Self.launchctl(["bootout", "\(Self.domain)/\(label)"])
            }
            guard !Self.itemExists(at: url), Self.validatedData(at: quarantine, label: label) == data else {
                throw Self.failure("The local login item changed while it was being disabled.")
            }
            try FileManager.default.removeItem(at: quarantine)
        } catch {
            if !Self.itemExists(at: url), Self.validatedData(at: quarantine, label: label) == data {
                try? FileManager.default.moveItem(at: quarantine, to: url)
            }
            throw error
        }
    }

    private static func isLoaded(label: String) -> Bool {
        (try? Self.launchctl(["print", "\(Self.domain)/\(label)"])) != nil
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Self.failure(message.isEmpty ? "macOS could not update Launch at Login." : message)
        }
    }

    private static func failure(_ message: String) -> LaunchAtLogin.OperationError {
        .failed(message)
    }
}
