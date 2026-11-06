import CodexProfileCore
import Darwin
import Foundation

/// The menu app owns polling, so updating its policy does not replace the helper
/// executable that macOS has already authorized. Only numeric observations and
/// an account digest are persisted; no authentication material is stored here.
actor ClaudeQuotaRefreshPolicy {
    struct Observation: Sendable {
        let snapshot: ClaudeUsageSnapshot?
        let failure: ClaudeCurrentUsageError?
        let nextRefreshAt: Date
    }

    private struct Record: Codable {
        var schemaVersion = 1
        let identity: String
        let attempt: String
        var nextRefreshAt: Date
        var rateLimitCount: Int
        var failure: ClaudeCurrentUsageError?
        var snapshot: ClaudeUsageSnapshot?
    }

    private let stateURL: URL
    private let lockURL: URL
    static let normalInterval: TimeInterval = 300

    init(root: URL) {
        self.stateURL = root.appendingPathComponent("quota-refresh-state.json")
        self.lockURL = root.appendingPathComponent("quota-refresh-state.lock")
    }

    func read(identity: String, seed: ClaudeUsageSnapshot? = nil, now: Date = Date(),
              fetch: @Sendable () async throws -> ClaudeUsageSnapshot) async -> Observation {
        let reservation: Record
        do {
            let prepared = try CacheLock.withLock(at: self.lockURL) { () -> (Record, Bool) in
                let existing = try self.load()
                if let existing, existing.identity == identity, existing.nextRefreshAt > now {
                    return (existing, false)
                }
                let sameAccount = existing?.identity == identity
                let record = Record(identity: identity, attempt: UUID().uuidString,
                    nextRefreshAt: now.addingTimeInterval(Self.normalInterval),
                    rateLimitCount: sameAccount ? existing?.rateLimitCount ?? 0 : 0,
                    failure: nil, snapshot: sameAccount ? existing?.snapshot ?? seed : seed)
                // Reserve before any await. Another app instance or a relaunch
                // must not immediately issue the same quota request.
                try self.save(record)
                return (record, true)
            }
            reservation = prepared.0
            if !prepared.1 { return self.observation(reservation, now: now) }
        } catch {
            return Observation(snapshot: Self.historical(seed, now: now), failure: .requestFailed,
                nextRefreshAt: now.addingTimeInterval(Self.normalInterval))
        }

        var completed = reservation
        CoreLogger.info("Claude quota refresh attempt", metadata: ["scope": "menu", "normal_interval_seconds": "300"])
        do {
            let snapshot = try await fetch()
            guard Self.valid(snapshot, now: now), snapshot.accountVerified else {
                throw ClaudeCurrentUsageError.invalidResponse
            }
            completed.snapshot = snapshot
            completed.rateLimitCount = 0
            completed.failure = nil
        } catch {
            let failure = error as? ClaudeCurrentUsageError ?? .requestFailed
            completed.failure = failure
            if failure == .accountChanged { completed.snapshot = nil }
            if failure == .rateLimited {
                completed.rateLimitCount = min(4, completed.rateLimitCount + 1)
                // The observed provider sends Retry-After: 0 for this endpoint.
                // Never treat that as permission for a tight retry loop.
                let delay = min(3600.0, 600 * pow(2, Double(completed.rateLimitCount - 1)))
                completed.nextRefreshAt = now.addingTimeInterval(delay)
                CoreLogger.warning("Claude quota request delayed", metadata: [
                    "category": "rateLimited", "retry_at": ISO8601DateFormatter().string(from: completed.nextRefreshAt),
                    "delay_seconds": String(Int(delay)),
                ])
            }
        }
        do {
            try CacheLock.withLock(at: self.lockURL) {
                guard let current = try self.load(), current.identity == identity,
                      current.attempt == reservation.attempt else { throw ClaudeCurrentUsageError.accountChanged }
                try self.save(completed)
            }
        } catch {
            return Observation(snapshot: nil, failure: .accountChanged, nextRefreshAt: completed.nextRefreshAt)
        }
        return self.observation(completed, now: now)
    }

    private func observation(_ record: Record, now: Date) -> Observation {
        let snapshot = record.snapshot.flatMap { snapshot -> ClaudeUsageSnapshot? in
            guard Self.valid(snapshot, now: now) else { return nil }
            return ClaudeUsageSnapshot(fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay,
                modelWeekly: snapshot.modelWeekly, observedAt: snapshot.observedAt, source: snapshot.source,
                isStale: record.failure != nil || snapshot.isStale
                    || now.timeIntervalSince(snapshot.observedAt) > ClaudeCurrentUsageService.cacheFreshness,
                accountVerified: snapshot.accountVerified)
        }
        return Observation(snapshot: snapshot, failure: record.failure, nextRefreshAt: record.nextRefreshAt)
    }

    private func load() throws -> Record? {
        guard FileManager.default.fileExists(atPath: self.stateURL.path) else { return nil }
        let bytes = try Self.privateData(self.stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(Record.self, from: bytes)
        guard record.schemaVersion == 1, record.nextRefreshAt.timeIntervalSince1970.isFinite,
              (0...4).contains(record.rateLimitCount) else { throw ClaudeCurrentUsageError.invalidResponse }
        return record
    }

    private func save(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(encoder.encode(record), to: self.stateURL)
    }

    private static func privateData(_ url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw ClaudeCurrentUsageError.invalidResponse }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 65_536 else { throw ClaudeCurrentUsageError.invalidResponse }
        return bytes
    }

    private static func valid(_ snapshot: ClaudeUsageSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.observedAt)
        return snapshot.accountVerified && age.isFinite && age >= -60 && age <= 86400
            && (snapshot.fiveHour != nil || snapshot.sevenDay != nil)
            && [snapshot.fiveHour, snapshot.sevenDay, snapshot.modelWeekly].compactMap { $0 }.allSatisfy {
                $0.usedPercentage.isFinite && (0...100).contains($0.usedPercentage)
                    && ($0.resetsAt?.timeIntervalSince1970.isFinite ?? true)
            }
    }

    private static func historical(_ snapshot: ClaudeUsageSnapshot?, now: Date) -> ClaudeUsageSnapshot? {
        guard let snapshot, Self.valid(snapshot, now: now) else { return nil }
        return ClaudeUsageSnapshot(fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay,
            modelWeekly: snapshot.modelWeekly, observedAt: snapshot.observedAt, source: snapshot.source,
            isStale: true, accountVerified: true)
    }

    /// Imports only an already verified numeric observation for this exact
    /// account and config directory. It is historical, never evidence of login.
    static func priorObservation(at url: URL, profile: ClaudeProfile, identity: String,
                                 now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let bytes = try? self.privateData(url),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              root["schemaVersion"] as? Int == 1,
              root["profileID"] as? String == profile.id,
              root["configDirectory"] as? String == profile.configDirectory,
              root["authIdentityDigest"] as? String == identity,
              let fetchedAt = root["fetchedAt"] as? Double,
              let usage = root["usage"] as? [String: Any] else { return nil }
        func window(_ key: String) -> ClaudeUsageWindow? {
            guard let value = usage[key] as? [String: Any], let number = value["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  (0...100).contains(number.doubleValue) else { return nil }
            let date = (value["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return ClaudeUsageWindow(usedPercentage: number.doubleValue, resetsAt: date)
        }
        let snapshot = ClaudeUsageSnapshot(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
            modelWeekly: window("seven_day_sonnet"), observedAt: Date(timeIntervalSince1970: fetchedAt),
            source: .oauthUsage, isStale: true, accountVerified: true)
        return Self.valid(snapshot, now: now) ? snapshot : nil
    }
}
