import CryptoKit
import Darwin
import Foundation

/// The helper returns only normalized usage and a pseudonymous account identity.
public struct ClaudeUsageHelperResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let identity: String?
    public let snapshot: ClaudeUsageSnapshot?
    public let error: ClaudeCurrentUsageError?

    public init(schemaVersion: Int = 1, identity: String? = nil,
                snapshot: ClaudeUsageSnapshot? = nil, error: ClaudeCurrentUsageError? = nil) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.snapshot = snapshot
        self.error = error
    }
}

/// A separate, stable executable owns Keychain access. The app never receives a credential.
/// Permission failures latch until an explicit Connect; refresh cannot launch authorization.
public final class ClaudeUsageHelperClient: @unchecked Sendable {
    private let executable: URL
    private let manifest: URL
    private let preferences: UserDefaults
    private let lock = NSLock()
    private var last: (String, ClaudeUsageSnapshot)?
    private static let maximumOutput = 65_536

    public init(executable: URL, manifest: URL, preferences: UserDefaults = .standard) {
        self.executable = executable
        self.manifest = manifest
        self.preferences = preferences
    }

    public static func bundled() -> ClaudeUsageHelperClient {
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        return ClaudeUsageHelperClient(executable: directory.appendingPathComponent("claude-usage-helper"),
                                      manifest: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/claude-usage-helper.json"))
    }

    public func authorize() throws {
        let digest = try self.executableDigest()
        self.preferences.set(true, forKey: self.blockKey(digest))
        // Each command is a new process. Allow-once cannot pass the second command.
        _ = try self.run("authorize", digest: digest, timeout: 120)
        _ = try self.run("verify", digest: digest, timeout: 10)
        self.preferences.removeObject(forKey: self.blockKey(digest))
    }

    public func read(identity: String) throws -> ClaudeUsageSnapshot {
        let digest = try self.executableDigest()
        guard !self.preferences.bool(forKey: self.blockKey(digest)) else {
            throw ClaudeCurrentUsageError.credentialInteractionRequired
        }
        do {
            let result = try self.run("read", digest: digest, timeout: 40)
            guard result.identity == identity, let snapshot = result.snapshot,
                  snapshot.accountVerified, snapshot.source == .oauthUsage,
                  Self.valid(snapshot) else { throw ClaudeCurrentUsageError.accountChanged }
            self.lock.lock(); self.last = (identity, snapshot); self.lock.unlock()
            return snapshot
        } catch {
            if error is CancellationError { throw error }
            let safe = error as? ClaudeCurrentUsageError ?? .requestFailed
            // Renewal-unavailable is transient: the user can renew the sign-in
            // in Claude Code at any time, so the next poll must retry rather
            // than stay latched behind an explicit Connect.
            if [.credentialInteractionRequired, .credentialUnavailable].contains(safe) {
                self.preferences.set(true, forKey: self.blockKey(digest))
            }
            throw safe
        }
    }

    public func cached(identity: String, now: Date) -> ClaudeUsageSnapshot? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let (captured, snapshot) = self.last, captured == identity else { return nil }
        return ClaudeUsageSnapshot(fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay,
            modelWeekly: snapshot.modelWeekly, fable: snapshot.fable,
            observedAt: snapshot.observedAt, source: snapshot.source,
            isStale: true,
            accountVerified: snapshot.accountVerified, resets: snapshot.resets)
    }

    private static let blockKeyPrefix = "claudeUsageHelperAccessBlocked."
    private func blockKey(_ digest: String) -> String { Self.blockKeyPrefix + digest }

    /// Removes block flags left by earlier helper builds. Each flag is keyed by
    /// the helper digest it latched for, so a flag for any other digest can
    /// never be cleared by Connect and only clutters the preferences. Returns
    /// how many were removed. The current helper's own flag is kept.
    @discardableResult
    public func clearStaleAccessBlocks() -> Int {
        let current = (try? self.executableDigest()).map(self.blockKey)
        var removed = 0
        for key in self.preferences.dictionaryRepresentation().keys
            where key.hasPrefix(Self.blockKeyPrefix) && key != current {
            self.preferences.removeObject(forKey: key)
            removed += 1
        }
        return removed
    }

    private func executableDigest() throws -> String {
        var file = stat()
        guard lstat(self.executable.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid() || file.st_uid == 0,
              file.st_mode & 0o022 == 0, file.st_size > 0, file.st_size < 268_435_456,
              FileManager.default.isExecutableFile(atPath: self.executable.path),
              let info = try? Data(contentsOf: self.manifest), info.count <= 4096,
              let document = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
              document["schemaVersion"] as? Int == 1,
              let expected = document["sha256"] as? String,
              let binary = try? Data(contentsOf: self.executable, options: [.mappedIfSafe]) else {
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw ClaudeCurrentUsageError.credentialUnavailable }
        return digest
    }

    private static func valid(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        guard snapshot.observedAt.timeIntervalSinceNow <= 60,
              snapshot.observedAt.timeIntervalSince1970.isFinite,
              snapshot.fiveHour != nil || snapshot.sevenDay != nil else { return false }
        return [snapshot.fiveHour, snapshot.sevenDay, snapshot.modelWeekly, snapshot.fable].compactMap { $0 }.allSatisfy {
            $0.usedPercentage.isFinite && (0...100).contains($0.usedPercentage)
                && ($0.resetsAt?.timeIntervalSince1970.isFinite ?? true)
        }
    }

    /// Cancellation uses SIGTERM first because the helper normally exits immediately;
    /// the bounded SIGKILL fallback keeps a wedged child from outliving its caller.
    private static func terminateForCancellation(_ process: Process) {
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Only numeric quota output is written to this private, short-lived file. Secrets never cross IPC.
    private func run(_ command: String, digest: String, timeout: TimeInterval) throws -> ClaudeUsageHelperResponse {
        guard ["read", "authorize", "verify"].contains(command), try self.executableDigest() == digest else {
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("response.json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { throw ClaudeCurrentUsageError.requestFailed }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = self.executable
        process.arguments = [command]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = handle
        do { try process.run() } catch { throw ClaudeCurrentUsageError.requestFailed }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if Task.isCancelled {
                Self.terminateForCancellation(process)
                throw CancellationError()
            }
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if ProcessInfo.processInfo.systemUptime >= deadline || size > Self.maximumOutput {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw ClaudeCurrentUsageError.requestFailed
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard let bytes = try? Data(contentsOf: output), bytes.count <= Self.maximumOutput,
              let response = try? JSONDecoder().decode(ClaudeUsageHelperResponse.self, from: bytes),
              response.schemaVersion == 1 else { throw ClaudeCurrentUsageError.invalidResponse }
        if let error = response.error { throw error }
        guard process.terminationStatus == 0 else { throw ClaudeCurrentUsageError.requestFailed }
        return response
    }
}
