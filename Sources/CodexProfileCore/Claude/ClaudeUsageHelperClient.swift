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
            let safe = error as? ClaudeCurrentUsageError ?? .requestFailed
            if [.credentialInteractionRequired, .credentialUnavailable, .credentialRenewalUnavailable].contains(safe) {
                self.preferences.set(true, forKey: self.blockKey(digest))
            }
            throw safe
        }
    }

    public func cached(identity: String, now: Date) -> ClaudeUsageSnapshot? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let (captured, snapshot) = self.last, captured == identity else { return nil }
        return ClaudeUsageSnapshot(fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay,
            modelWeekly: snapshot.modelWeekly, observedAt: snapshot.observedAt, source: snapshot.source,
            isStale: true,
            accountVerified: snapshot.accountVerified)
    }

    private func blockKey(_ digest: String) -> String { "claudeUsageHelperAccessBlocked." + digest }

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
        return [snapshot.fiveHour, snapshot.sevenDay, snapshot.modelWeekly].compactMap { $0 }.allSatisfy {
            $0.usedPercentage.isFinite && (0...100).contains($0.usedPercentage)
                && ($0.resetsAt?.timeIntervalSince1970.isFinite ?? true)
        }
    }

    /// Only numeric quota output is written to this private, short-lived file. Secrets never cross IPC.
    private func run(_ command: String, digest: String, timeout: TimeInterval) throws -> ClaudeUsageHelperResponse {
        guard ["read", "authorize", "verify"].contains(command), try self.executableDigest() == digest else {
            throw ClaudeCurrentUsageError.credentialUnavailable
        }
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
