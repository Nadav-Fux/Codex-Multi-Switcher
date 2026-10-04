import Foundation

public enum CodexRPCError: LocalizedError {
    case cliNotFound
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Codex CLI not found"
        case .startFailed(let message):
            return "Failed to start Codex CLI: \(message)"
        case .requestFailed(let message):
            return message
        case .malformed(let message):
            return message
        case .timeout(let method):
            return "Codex CLI timed out on \(method)"
        }
    }

    public var isAuthRequired: Bool {
        guard case .requestFailed(let message) = self else { return false }
        let terms = [
            "authentication required",
            "log in",
            "login required",
            "unauthorized",
            "token expired",
            "expired token",
            "invalid_grant",
            "refresh token",
        ]
        return terms.contains { message.localizedCaseInsensitiveContains($0) }
    }
}

public enum CLIUsageError: LocalizedError {
    case noRateLimitsFound
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noRateLimitsFound:
            return "Codex CLI returned no usage data"
        case .invalidResponse(let message):
            return message
        }
    }
}

struct RPCRateLimitsResponse: Decodable {
    let accountId: String?
    let rateLimits: RPCRateLimitSnapshot
    let rateLimitsByLimitId: [String: RPCRateLimitSnapshot]?
    let rateLimitResetCredits: RPCRateLimitResetCredits?

    /// The legacy view can mirror another quota alias on newer Codex versions.
    /// Prefer the included Codex bucket when the multi-bucket view supplies it.
    var codexRateLimits: RPCRateLimitSnapshot {
        self.rateLimitsByLimitId?["codex"] ?? self.rateLimits
    }
}

struct RPCRateLimitResetCredits: Decodable {
    let availableCount: Int
    let credits: [RPCRateLimitResetCredit]?
}

struct RPCRateLimitResetCredit: Decodable {
    let id: String?
    let status: String
    let resetType: String?
    let grantedAt: Int?
    let expiresAt: Int?
    let title: String?
    let description: String?
}

private struct RPCConsumeResetResponse: Decodable {
    let outcome: BankedResetOutcome
}

struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType = "planType"
    }
}

struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct RPCCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

public enum CodexCLIResolver {
    private static let fileManager = FileManager.default

    public static func resolvePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = (environment["CODEX_PROFILE_TEST_CLI"] ?? environment["CODEX_CLI"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return self.fileManager.isExecutableFile(atPath: override) ? override : nil
        }

        if let bundledCLI = try? CodexDesktopLifecycle(environment: environment).resolveBundledCLI(),
           self.fileManager.isExecutableFile(atPath: bundledCLI) {
            return bundledCLI
        }

        if let fromPath = self.whichCodex(environment: environment) {
            return fromPath
        }

        return nil
    }

    private static func whichCodex(environment: [String: String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["codex"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        var env = environment
        env["PATH"] = self.effectivePATH(environment: environment)
        proc.environment = env

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func effectivePATH(environment: [String: String]) -> String {
        let home = self.fileManager.homeDirectoryForCurrentUser.path
        let defaults = [
            environment["PATH"],
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var seen = Set<String>()
        var parts: [String] = []
        for chunk in defaults.compactMap({ $0 }) {
            for item in chunk.split(separator: ":").map(String.init) where !item.isEmpty {
                if seen.insert(item).inserted {
                    parts.append(item)
                }
            }
        }
        return parts.joined(separator: ":")
    }
}

private final class CodexRPCStderrTail: @unchecked Sendable {
    private static let maxBytes = 2 * 1024
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false
    private var isClosed = false
    private var closeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func append(_ newData: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }

        if newData.count > Self.maxBytes {
            self.data = Data(newData.suffix(Self.maxBytes))
            self.wasTruncated = true
            return
        }
        if newData.count == Self.maxBytes {
            self.wasTruncated = self.wasTruncated || !self.data.isEmpty
            self.data = newData
            return
        }

        self.data.append(newData)
        if self.data.count > Self.maxBytes {
            self.data.removeFirst(self.data.count - Self.maxBytes)
            self.wasTruncated = true
        }
    }

    func close() {
        self.lock.lock()
        guard !self.isClosed else {
            self.lock.unlock()
            return
        }
        self.isClosed = true
        let waiters = Array(self.closeWaiters.values)
        self.closeWaiters.removeAll()
        self.lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilClosed() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if self.isClosed || Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume()
                } else {
                    self.closeWaiters[id] = continuation
                    self.lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        self.lock.lock()
        let waiter = self.closeWaiters.removeValue(forKey: id)
        self.lock.unlock()
        waiter?.resume()
    }

    func redactedExcerpt() -> String {
        self.lock.lock()
        let snapshot = self.data
        let wasTruncated = self.wasTruncated
        self.lock.unlock()

        var safeSnapshot = snapshot
        if wasTruncated {
            guard let newline = safeSnapshot.firstIndex(of: 0x0A) else {
                return "...<stderr tail>"
            }
            safeSnapshot.removeSubrange(...newline)
        }

        let redacted = LogRedactor.redact(String(decoding: safeSnapshot, as: UTF8.self))
            .replacingOccurrences(of: "\n", with: "\\n")
        let maxLength = 2_000
        let isExcerpted = redacted.count > maxLength
        let excerpt = isExcerpted ? String(redacted.suffix(maxLength)) : redacted
        return wasTruncated || isExcerpted ? "...<stderr tail> \(excerpt)" : excerpt
    }
}

final class CodexRPCLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()
    private static let maxBufferBytes = 4 * 1024 * 1024 // 4 MB cap

    /// Returns complete newline-delimited lines drained from the buffer.
    /// If the buffer exceeds maxBufferBytes without a newline, it is cleared and
    /// `nil` is returned to signal a malformed-stream condition.
    func appendAndDrainLines(_ data: Data) -> (lines: [Data], overflow: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.buffer.append(data)

        if self.buffer.count > CodexRPCLineBuffer.maxBufferBytes {
            let overflowBytes = self.buffer.count
            self.buffer.removeAll(keepingCapacity: false)
            CoreLogger.warning(
                "CodexRPCLineBuffer: buffer exceeded 4 MB cap; clearing",
                metadata: ["bytes": "\(overflowBytes)"])
            return ([], true)
        }

        var out: [Data] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let line = Data(self.buffer[..<newline])
            self.buffer.removeSubrange(...newline)
            if !line.isEmpty {
                out.append(line)
            }
        }
        return (out, false)
    }
}

private final class CodexRPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private let stderrTail = CodexRPCStderrTail()
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private var nextID = 1
    private var stdoutLineIterator: AsyncStream<Data>.Iterator

    init(
        executablePath: String,
        environment: [String: String],
        initializeTimeoutSeconds: TimeInterval = 8,
        requestTimeoutSeconds: TimeInterval = 3) throws {
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds

        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation = $0 }
        self.stdoutLineContinuation = continuation
        self.stdoutLineIterator = self.stdoutLineStream.makeAsyncIterator()

        self.process.executableURL = URL(fileURLWithPath: executablePath)
        // No `--ask-for-approval`: account RPC calls do not execute agent turns,
        // and accepted approval values change between Codex CLI releases.
        // Force file auth in the isolated CODEX_HOME so token refreshes are read
        // back reliably and the child cannot write to a user's real Keychain.
        self.process.arguments = [
            "-s", "read-only", "-c", "cli_auth_credentials_store=\"file\"", "app-server",
        ]
        self.process.environment = environment
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw CodexRPCError.startFailed(error.localizedDescription)
        }

        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stdoutBuffer = CodexRPCLineBuffer()
        let stdoutContinuation = self.stdoutLineContinuation
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }

            let result = stdoutBuffer.appendAndDrainLines(data)
            if result.overflow {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }
            for line in result.lines {
                stdoutContinuation.yield(line)
            }
        }

        let stderrHandle = self.stderrPipe.fileHandleForReading
        let stderrTail = self.stderrTail
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrTail.close()
                return
            }
            stderrTail.append(data)
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]],
            timeout: self.initializeTimeoutSeconds)
        try self.sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        // Recent app-servers give the reset-inventory lookup up to five seconds
        // in addition to reading usage. Let that complete or fall back to count.
        let message = try await self.request(method: "account/rateLimits/read", timeout: 15)
        return try self.decodeResult(from: message)
    }

    func consumeReset(creditId: String, idempotencyKey: String) async throws -> BankedResetOutcome {
        let message = try await self.request(
            method: "account/rateLimitResetCredit/consume",
            params: ["creditId": creditId, "idempotencyKey": idempotencyKey],
            timeout: 30)
        let response: RPCConsumeResetResponse = try self.decodeResult(from: message)
        return response.outcome
    }

    func shutdown() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard self.process.isRunning else { return }
        self.process.terminate()

        // Wait up to ~2 s for the process to exit before allowing the caller's
        // defer to delete the temp CODEX_HOME the child may still be using.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while self.process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if self.process.isRunning {
            kill(self.process.processIdentifier, SIGKILL)
            // One short final wait so the OS can reclaim the PID.
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        let resolvedTimeout = timeout ?? self.requestTimeoutSeconds
        let wrapped = try await self.withTimeout(seconds: resolvedTimeout, method: method) {
            while true {
                let message = try await self.readNextMessage()

                if message["id"] == nil {
                    continue
                }

                guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }

                if let error = message["error"] as? [String: Any],
                   let messageText = error["message"] as? String {
                    throw CodexRPCError.requestFailed(messageText)
                }

                return SendableMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.terminateForTimeout()
                throw CodexRPCError.timeout(method: method)
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CodexRPCError.timeout(method: method)
            }
            group.cancelAll()
            return result
        }
    }

    private func terminateForTimeout() {
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        try self.sendPayload(["jsonrpc": "2.0", "method": method, "params": params ?? [:]])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        try self.sendPayload(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readNextMessage() async throws -> [String: Any] {
        while let lineData = await self.stdoutLineIterator.next() {
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        await self.stderrTail.waitUntilClosed()
        try Task.checkCancellation()
        let excerpt = self.stderrTail.redactedExcerpt()
        let detail = excerpt.isEmpty ? "" : ": \(excerpt)"
        throw CodexRPCError.malformed("codex app-server closed stdout\(detail)")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw CodexRPCError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

public enum CLIUsageFetcher {
    public static func fetch(
        profileId: String,
        authData: Data,
        codexConfigURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clientName: String = "CodexMultiSwitcher",
        clientVersion: String) async throws -> UsageSnapshot {
        try await self.fetchResult(
            profileId: profileId, authData: authData, codexConfigURL: codexConfigURL,
            environment: environment, clientName: clientName, clientVersion: clientVersion).snapshot
    }

    public static func fetchResult(
        profileId: String,
        authData: Data,
        codexConfigURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clientName: String = "CodexMultiSwitcher",
        clientVersion: String) async throws -> CLIUsageResult {
        let executablePath = CodexCLIResolver.resolvePath(environment: environment)
        guard let executablePath else { throw CodexRPCError.cliNotFound }

        let tempHome = try self.makeTemporaryCodexHome(profileId: profileId)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try self.seedTemporaryHome(tempHome, authData: authData, codexConfigURL: codexConfigURL)

        let env = self.isolatedEnvironment(tempHome: tempHome, environment: environment)

        let rpc = try CodexRPCClient(executablePath: executablePath, environment: env)
        defer { rpc.shutdown() }

        do {
            try await rpc.initialize(clientName: clientName, clientVersion: clientVersion)
            let response = try await rpc.fetchRateLimits()
            try self.validateAccount(response, originalAuth: authData)
            let snapshot = try self.makeSnapshot(
                from: response.codexRateLimits,
                resetCredits: response.rateLimitResetCredits)
            rpc.shutdown()
            return CLIUsageResult(
                snapshot: snapshot,
                updatedAuthData: self.updatedAuth(in: tempHome, original: authData))
        } catch {
            rpc.shutdown()
            throw self.preservingRotatedAuth(error, tempHome: tempHome, original: authData)
        }
    }

    /// Redeems exactly one identified credit in a throwaway profile home, without
    /// switching the running desktop account. Persist the idempotency key before
    /// calling this and reuse it after an uncertain network failure.
    public static func consumeReset(
        profileId: String,
        authData: Data,
        codexConfigURL: URL,
        creditId: String,
        idempotencyKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clientName: String = "CodexMultiSwitcher",
        clientVersion: String) async throws -> CLIBankedResetResult {
        guard !creditId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIUsageError.invalidResponse("Reset credit ID and idempotency key must be non-empty")
        }
        let executablePath = CodexCLIResolver.resolvePath(environment: environment)
        guard let executablePath else { throw CodexRPCError.cliNotFound }

        let tempHome = try self.makeTemporaryCodexHome(profileId: profileId)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        try self.seedTemporaryHome(tempHome, authData: authData, codexConfigURL: codexConfigURL)

        let env = self.isolatedEnvironment(tempHome: tempHome, environment: environment)
        let rpc = try CodexRPCClient(executablePath: executablePath, environment: env)
        defer { rpc.shutdown() }

        do {
            try await rpc.initialize(clientName: clientName, clientVersion: clientVersion)
            // Check the supported type when a detail row is still available.
            // Do not reject a missing row here: a prior attempt may have used
            // it successfully but lost its response. The backend must resolve
            // that retry with the original ID and idempotency key.
            let current = try await rpc.fetchRateLimits()
            try self.validateAccount(current, originalAuth: authData)
            if let selected = current.rateLimitResetCredits?.credits?.first(where: { $0.id == creditId }),
               selected.resetType != "codexRateLimits" {
                throw CLIUsageError.invalidResponse("The selected reset type is unsupported")
            }

            CoreLogger.info("Reset diagnostic rpc_dispatch")
            let outcome = try await rpc.consumeReset(creditId: creditId, idempotencyKey: idempotencyKey)
            CoreLogger.info("Reset diagnostic rpc_reply", metadata: ["outcome": outcome.rawValue])
            var snapshot: UsageSnapshot?
            var refreshError: String?
            do {
                let updated = try await rpc.fetchRateLimits()
                try self.validateAccount(updated, originalAuth: authData)
                snapshot = try self.makeSnapshot(
                    from: updated.codexRateLimits, resetCredits: updated.rateLimitResetCredits)
            } catch {
                refreshError = LogRedactor.redact(error.localizedDescription)
            }
            rpc.shutdown()
            return CLIBankedResetResult(
                outcome: outcome, snapshot: snapshot,
                updatedAuthData: self.updatedAuth(in: tempHome, original: authData),
                refreshError: refreshError)
        } catch {
            rpc.shutdown()
            throw self.preservingRotatedAuth(error, tempHome: tempHome, original: authData)
        }
    }

    private static func seedTemporaryHome(_ tempHome: URL, authData: Data, codexConfigURL: URL) throws {
        try AtomicFileWriter.write(authData, to: tempHome.appendingPathComponent("auth.json"))
        if FileManager.default.fileExists(atPath: codexConfigURL.path) {
            try? self.copyFile(from: codexConfigURL, to: tempHome.appendingPathComponent("config.toml"))
        }
    }

    private static func isolatedEnvironment(tempHome: URL, environment: [String: String]) -> [String: String] {
        var env = environment
        env["CODEX_HOME"] = tempHome.path
        env["PATH"] = CodexCLIResolver.effectivePATH(environment: environment)
        // The provided profile blob is the sole auth source. Shell API keys
        // must not silently replace the selected subscription's account.
        env["OPENAI_API_KEY"] = nil
        env["CODEX_API_KEY"] = nil
        return env
    }

    private static func validateAccount(_ response: RPCRateLimitsResponse, originalAuth: Data) throws {
        guard let returnedAccount = response.accountId,
              let expectedAccount = try? AuthBlob.load(from: originalAuth).accountId else { return }
        guard returnedAccount == expectedAccount else {
            throw CLIUsageError.invalidResponse("Codex returned usage for a different account")
        }
    }

    private static func updatedAuth(in tempHome: URL, original: Data) -> Data? {
        guard let replacement = try? Data(contentsOf: tempHome.appendingPathComponent("auth.json")),
              replacement != original,
              AuthBlob.isPlausibleAuthBlob(replacement),
              AuthBlob.identityMatches(original, replacement) else { return nil }
        return replacement
    }

    private static func preservingRotatedAuth(_ error: Error, tempHome: URL, original: Data) -> Error {
        guard let replacement = self.updatedAuth(in: tempHome, original: original) else { return error }
        return CLIUsageOperationError(underlyingError: error, updatedAuthData: replacement)
    }

    private static func makeTemporaryCodexHome(profileId: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-multi-switcher-\(profileId)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func copyFile(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try AtomicFileWriter.write(data, to: destination)
    }

    static func makeSnapshot(
        from rateLimits: RPCRateLimitSnapshot,
        resetCredits: RPCRateLimitResetCredits? = nil
    ) throws -> UsageSnapshot {
        let creditsRemaining = rateLimits.credits.flatMap { credits -> Double? in
            guard let balance = credits.balance,
                  let value = Double(balance.replacingOccurrences(of: ",", with: "")),
                  value.isFinite else { return nil }
            return value
        }

        let reported = [rateLimits.primary, rateLimits.secondary].map { window -> RPCRateLimitWindow? in
            guard let window, window.usedPercent.isFinite,
                  (0...100).contains(window.usedPercent) else { return nil }
            return window
        }
        var primary: RPCRateLimitWindow?
        var secondary: RPCRateLimitWindow?
        // Newer plans can report just a weekly window in the primary RPC field.
        // Duration identifies the display slot; wire position is only a fallback
        // for old CLI versions that return another or unknown duration.
        for window in reported.compactMap({ $0 }) {
            if window.windowDurationMins == 300, primary == nil { primary = window }
            if window.windowDurationMins == 10080, secondary == nil { secondary = window }
        }
        if let window = reported[0], window.windowDurationMins != 300,
           window.windowDurationMins != 10080, primary == nil { primary = window }
        if let window = reported[1], window.windowDurationMins != 300,
           window.windowDurationMins != 10080, secondary == nil { secondary = window }
        let primaryResetAt = primary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let secondaryResetAt = secondary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let primaryUsedPercent = primary.map { Int($0.usedPercent.rounded()) } ?? 0
        let secondaryUsedPercent = secondary.map { Int($0.usedPercent.rounded()) } ?? 0

        if primary == nil, secondary == nil, creditsRemaining == nil {
            throw CLIUsageError.noRateLimitsFound
        }

        return UsageSnapshot(
            planType: rateLimits.planType,
            creditsRemaining: creditsRemaining,
            primaryUsedPercent: primaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryResetAt: secondaryResetAt,
            fetchedAt: Date(),
            primaryWindowDurationMins: primary?.windowDurationMins,
            secondaryWindowDurationMins: secondary?.windowDurationMins,
            bankedResetCount: resetCredits.map { max(0, $0.availableCount) },
            bankedResetExpirations: resetCredits?.credits.map { credits in
                credits.filter { $0.status == "available" }
                    .map { $0.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
                    .sorted { lhs, rhs in
                        switch (lhs, rhs) {
                        case let (.some(a), .some(b)): return a < b
                        case (.some, .none): return true
                        case (.none, .some), (.none, .none): return false
                        }
                    }
            },
            bankedResetCredits: resetCredits?.credits.map { credits in
                credits.compactMap { credit in
                    guard let id = credit.id,
                          !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return BankedResetCredit(
                        id: id, status: credit.status, resetType: credit.resetType ?? "unknown",
                        grantedAt: credit.grantedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        expiresAt: credit.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        title: credit.title, description: credit.description)
                }
            },
            primaryWindowAvailable: primary != nil,
            secondaryWindowAvailable: secondary != nil)
    }
}
