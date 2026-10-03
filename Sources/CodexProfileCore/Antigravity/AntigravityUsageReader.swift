import Darwin
import CoreFoundation
import CryptoKit
import Foundation

/// Reads Antigravity's live quota snapshot through the official read-only CLI command.
/// It reads only the known CLI ID-token identity claims for account binding, changes no local
/// auth/settings state, and never falls back to a model prompt.
public struct AntigravityUsageReader: Sendable {
    private static let minimumSafeCLI = [1, 2, 11]
    private static let maximumOutputBytes = 1_048_576

    private let explicitExecutableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 8) {
        self.explicitExecutableURL = executableURL
        self.timeout = min(max(timeout, 1), 30)
    }

    /// Performs a fresh `/usage` fetch. Antigravity's CLI refreshes quota state for this command.
    public func read() async throws -> AntigravityUsageSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.readSynchronously(executableURL: self.explicitExecutableURL,
                                       timeout: self.timeout)
        }.value
    }

    private static func readSynchronously(executableURL: URL?, timeout: TimeInterval) throws -> AntigravityUsageSnapshot {
        guard let executable = executableURL ?? Self.resolveExecutable() else {
            throw AntigravityUsageError.cliMissing
        }
        guard let identityBefore = Self.currentAccountIdentity() else {
            throw AntigravityUsageError.accountUnavailable
        }

        let versionData: Data
        do {
            versionData = try Self.run(executable: executable, arguments: ["--version"], timeout: timeout)
        } catch AntigravityUsageError.timedOut {
            throw AntigravityUsageError.timedOut
        } catch {
            throw AntigravityUsageError.commandFailed
        }
        guard let versionText = String(data: versionData, encoding: .utf8),
              let version = Self.version(in: versionText),
              Self.isSafeVersion(version) else {
            // Older builds may treat `/usage` as a user prompt. Do not invoke them.
            throw AntigravityUsageError.unsupportedCLIVersion
        }

        let response: Data
        do {
            response = try Self.run(executable: executable,
                                    arguments: ["-p", "/usage", "--output-format", "json"],
                                    timeout: timeout)
        } catch AntigravityUsageError.timedOut {
            throw AntigravityUsageError.timedOut
        } catch {
            throw AntigravityUsageError.commandFailed
        }
        guard let identityAfter = Self.currentAccountIdentity() else {
            throw AntigravityUsageError.accountChanged
        }
        guard identityBefore == identityAfter else { throw AntigravityUsageError.accountChanged }
        return try Self.parse(response, observedAt: Date(), accountIdentity: identityAfter)
    }

    /// Reads only the known Antigravity CLI token's ID-token issuer and subject. Token material,
    /// email, and all other claims remain in memory and are never returned or logged.
    private static func currentAccountIdentity() -> String? {
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let values = try? tokenURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0, size <= Self.maximumOutputBytes,
              let data = try? Data(contentsOf: tokenURL), data.count <= Self.maximumOutputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = root["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let payloadData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let issuer = claims["iss"] as? String, !issuer.isEmpty,
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((issuer + "\u{0}" + subject).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "sha256:" + digest
    }

    private static func resolveExecutable() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            URL(fileURLWithPath: "/usr/bin/agy"),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates.append(contentsOf: path.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("agy")
        })
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    private static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AntigravityUsageError.commandFailed
        }

        let timeoutFlag = TimeoutFlag()
        let timer = DispatchWorkItem {
            guard process.isRunning else { return }
            timeoutFlag.set()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        var data = Data()
        var outputExceededLimit = false
        while true {
            let chunk: Data?
            do {
                chunk = try output.fileHandleForReading.read(upToCount: 16_384)
            } catch {
                process.terminate()
                process.waitUntilExit()
                timer.cancel()
                throw AntigravityUsageError.commandFailed
            }
            guard let chunk, !chunk.isEmpty else { break }
            guard data.count + chunk.count <= Self.maximumOutputBytes else {
                outputExceededLimit = true
                process.terminate()
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        timer.cancel()

        guard !outputExceededLimit else { throw AntigravityUsageError.invalidResponse }
        if timeoutFlag.value { throw AntigravityUsageError.timedOut }
        guard process.terminationStatus == 0 else { throw AntigravityUsageError.commandFailed }
        return data
    }

    private static func version(in value: String) -> [Int]? {
        let pattern = #"(?:^|\s)v?(\d+)\.(\d+)\.(\d+)(?:$|\s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges == 4 else { return nil }
        return (1...3).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
    }

    private static func isSafeVersion(_ value: [Int]) -> Bool {
        for index in 0..<minimumSafeCLI.count {
            let current = index < value.count ? value[index] : 0
            if current != minimumSafeCLI[index] { return current > minimumSafeCLI[index] }
        }
        return true
    }

    private static func parse(_ data: Data, observedAt: Date,
                              accountIdentity: String) throws -> AntigravityUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let numTurns = root["num_turns"] as? Int, numTurns == 0,
              let command = root["command"] as? [String: Any],
              command["name"] as? String == "usage",
              let commandData = command["data"] as? [String: Any],
              let groups = commandData["groups"] as? [[String: Any]] else {
            throw AntigravityUsageError.invalidResponse
        }

        var buckets: [AntigravityQuotaBucket] = []
        var seenIDs = Set<String>()
        for group in groups {
            guard let familyLabel = group["name"] as? String, !familyLabel.isEmpty,
                  let rawBuckets = group["buckets"] as? [[String: Any]] else {
                throw AntigravityUsageError.invalidResponse
            }
            let family: AntigravityQuotaFamily = familyLabel.localizedCaseInsensitiveContains("gemini")
                ? .gemini : .nonGemini
            let description = group["description"] as? String
            for bucket in rawBuckets {
                guard let id = bucket["id"] as? String, !id.isEmpty,
                      seenIDs.insert(id).inserted,
                      let windowLabel = bucket["name"] as? String, !windowLabel.isEmpty,
                      let window = bucket["window"] as? String, !window.isEmpty,
                      let fractionNumber = bucket["remaining_fraction"] as? NSNumber,
                      CFGetTypeID(fractionNumber) != CFBooleanGetTypeID(),
                      fractionNumber.doubleValue.isFinite,
                      (0...1).contains(fractionNumber.doubleValue),
                      let resetText = bucket["reset_time"] as? String,
                      let resetsAt = Self.parseDate(resetText) else {
                    throw AntigravityUsageError.invalidResponse
                }
                buckets.append(AntigravityQuotaBucket(
                    id: id,
                    familyLabel: familyLabel,
                    family: family,
                    modelDescription: description,
                    windowLabel: windowLabel,
                    window: window,
                    remainingFraction: fractionNumber.doubleValue,
                    resetsAt: resetsAt
                ))
            }
        }
        guard !buckets.isEmpty else { throw AntigravityUsageError.noQuotaData }
        return AntigravityUsageSnapshot(buckets: buckets, observedAt: observedAt,
                                        accountIdentity: accountIdentity, accountVerified: true)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeout = false
    func set() {
        self.lock.lock()
        self.didTimeout = true
        self.lock.unlock()
    }
    var value: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.didTimeout
    }
}
