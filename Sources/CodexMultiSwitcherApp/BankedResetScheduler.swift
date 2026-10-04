import Combine
import Foundation
import CodexProfileCore

@MainActor
final class BankedResetScheduler: ObservableObject {
    @Published private(set) var schedules: [String: BankedResetSchedule] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var lastMessage: String?
    private let store: ProfileStore
    private let schedulesURL: URL
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var storageReadFailed = false
    private var lastTimerTick: Date?
    private var lastHeartbeat: Date?
    private var lastGate: String?
    private var diagnosticIDs: [String: String] = [:]
    var canRun: () -> Bool = { true }
    var diagnosticContext: () -> [String: String] = { [:] }
    var diagnosticBlockReason: () -> String? = { nil }
    var onCompletion: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
        self.schedulesURL = store.usageAuthSource().paths.switcherHome
            .appendingPathComponent("reset-schedules.json")
        if FileManager.default.fileExists(atPath: self.schedulesURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let data = try Data(contentsOf: self.schedulesURL)
                let decoded = try decoder.decode([String: BankedResetSchedule].self, from: data)
                guard decoded.allSatisfy({ key, value in key == value.id && !value.creditID.isEmpty
                    && !value.accountFingerprint.isEmpty && !value.idempotencyKey.isEmpty
                    && value.hasValidBeforeExpiryOffset }) else { throw ResetError.storageUnreadable }
                self.schedules = decoded
            }
            catch {
                self.storageReadFailed = true
                self.lastMessage = "Reset schedules could not be read. Automatic resets are paused."
            }
        }
    }

    func start() {
        guard !AppInfo.isPreview else { return }
        self.timer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDueSchedules(reason: "timer") }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.trace("started", metadata: ["interval_seconds": "10", "run_loop": "common"])
        self.checkDueSchedules(reason: "startup")
    }

    func schedule(for profileID: String, creditID: String) -> BankedResetSchedule? {
        self.schedules["\(profileID):\(creditID)"]
    }

    func saveSchedule(profileID: String, credit: BankedResetCredit,
                      mode: BankedResetScheduleMode, date: Date, hours: Int, minutes: Int = 0) async throws {
        guard !AppInfo.isPreview, !self.isRunning, self.operation == nil else { throw ResetError.busy }
        if mode == .beforeExpiry {
            guard (0...720).contains(hours), (0...59).contains(minutes),
                  (1...(720 * 60)).contains(hours * 60 + minutes) else { throw ResetError.invalidOffset }
        }
        let source = self.store.usageAuthSource()
        let data = try await Task.detached { try source.vault.loadAuthBlob(profileID: profileID) }.value
        guard let data, let fingerprint = AuthBlob.identityFingerprint(from: data) else { throw AuthError.notFound }
        guard !self.isRunning, self.operation == nil else { throw ResetError.busy }
        guard credit.isRedeemable(), !credit.id.isEmpty else { throw ResetError.unavailable }
        guard !self.schedules.values.contains(where: {
            $0.profileID != profileID && $0.creditID == credit.id
                && $0.matchesAccount(authData: data) && $0.enabled
        }) else { throw ResetError.duplicate }
        if mode == .beforeExpiry, credit.expiresAt == nil { throw ResetError.noExpiry }
        if mode == .atDate {
            guard date > Date(), credit.expiresAt.map({ date < $0 }) ?? true else { throw ResetError.invalidDate }
        }
        if let previous = self.schedule(for: profileID, creditID: credit.id), previous.lastAttemptAt != nil, previous.completedAt == nil {
            throw ResetError.pendingAttempt
        }
        let storedHours = mode == .beforeExpiry || ((0...720).contains(hours) && (0...59).contains(minutes)
            && (1...(720 * 60)).contains(hours * 60 + minutes)) ? hours : 24
        let storedMinutes = storedHours == hours ? minutes : 0
        let record = BankedResetSchedule(profileID: profileID, creditID: credit.id,
            accountFingerprint: fingerprint, mode: mode, scheduledAt: date, hoursBeforeExpiry: storedHours,
            minutesBeforeExpiry: storedMinutes, creditExpiresAt: credit.expiresAt,
            accountClaimFingerprints: AuthBlob.identityClaimFingerprints(from: data))
        try self.persist(record)
        self.trace("saved", record: record)
        self.lastMessage = "Reset schedule saved."
        self.checkDueSchedules(reason: "schedule_saved")
    }

    func cancelSchedule(profileID: String, creditID: String) throws {
        guard !self.isRunning, self.operation == nil else { throw ResetError.busy }
        guard var record = self.schedule(for: profileID, creditID: creditID) else { return }
        record.enabled = false
        record.lastError = nil
        try self.persist(record)
        self.trace("cancelled", record: record)
    }

    func useNow(profileID: String, credit: BankedResetCredit) async throws {
        guard !AppInfo.isPreview, !self.isRunning, self.operation == nil, self.canRun(),
              !self.store.isAuthMutationInProgress() else { throw ResetError.busy }
        let source = self.store.usageAuthSource()
        let data = try await Task.detached { try source.vault.loadAuthBlob(profileID: profileID) }.value
        guard let data, let fingerprint = AuthBlob.identityFingerprint(from: data) else { throw AuthError.notFound }
        guard !self.isRunning, self.operation == nil, self.canRun() else { throw ResetError.busy }
        var record = self.schedule(for: profileID, creditID: credit.id)
            ?? BankedResetSchedule(profileID: profileID, creditID: credit.id,
                accountFingerprint: fingerprint, mode: .atDate, scheduledAt: Date(), creditExpiresAt: credit.expiresAt, automaticallyRetryNoOp: false, accountClaimFingerprints: AuthBlob.identityClaimFingerprints(from: data))
        // Preserve a previous uncertain attempt's key. A credit is never substituted.
        if record.completedAt != nil { throw ResetError.unavailable }
        guard record.matchesAccount(authData: data) else { throw ResetError.accountChanged }
        guard !self.schedules.values.contains(where: {
            $0.profileID != profileID && $0.creditID == credit.id
                && $0.matchesAccount(authData: data) && $0.enabled
        }) else { throw ResetError.duplicate }
        guard record.lastAttemptAt != nil || credit.isRedeemable() else { throw ResetError.unavailable }
        record.enabled = true
        record.retryAfter = nil
        try self.persist(record)
        self.trace("manual_requested", record: record)
        await self.execute(record)
    }

    func checkDueSchedules(reason: String = "unspecified") {
        let now = Date()
        let gate: String?
        if AppInfo.isPreview { gate = "preview" }
        else if self.storageReadFailed { gate = "storage_unreadable" }
        else if self.isRunning || self.operation != nil { gate = "reset_in_progress" }
        else if self.store.isAuthMutationInProgress() { gate = "auth_mutation" }
        else if !self.canRun() { gate = self.diagnosticBlockReason() ?? "provider_busy" }
        else { gate = nil }
        let pending = self.schedules.values.filter { $0.enabled && $0.completedAt == nil }
        let next = pending.min {
            (self.trigger(for: $0) ?? .distantFuture) < (self.trigger(for: $1) ?? .distantFuture)
        }
        if reason == "timer" {
            let gap = self.lastTimerTick.map { now.timeIntervalSince($0) }
            self.lastTimerTick = now
            if self.lastHeartbeat == nil || now.timeIntervalSince(self.lastHeartbeat!) >= 60 || (gap ?? 0) > 25 {
                self.lastHeartbeat = now
                self.trace("heartbeat", record: next, metadata: ["source": reason,
                    "gate": gate ?? "none", "pending": String(pending.count),
                    "tick_gap_seconds": gap.map { String(format: "%.3f", $0) } ?? "first"])
            }
        }
        if self.lastGate != gate {
            if let gate { self.trace("blocked", record: next, metadata: ["gate": gate, "source": reason]) }
            else if let previous = self.lastGate { self.trace("unblocked", record: next, metadata: ["previous_gate": previous, "source": reason]) }
            self.lastGate = gate
        }
        guard gate == nil else { return }
        let due = self.schedules.values.filter { record in
            let credit = self.store.statuses[record.profileID]?.snapshot?.bankedResetCredits?
                .first(where: { $0.id == record.creditID })
            return record.isDue(expiresAt: credit?.expiresAt, now: now)
                || (record.enabled && record.completedAt == nil && record.lastAttemptAt != nil
                    && (record.retryAfter.map { $0 <= now } ?? true))
        }.sorted { $0.scheduledAt < $1.scheduledAt }
        guard let record = due.first else { return }
        self.trace("due_observed", record: record, metadata: ["source": reason])
        self.operation = Task { [weak self] in
            guard let self else { return }
            await self.execute(record)
            self.operation = nil
            self.checkDueSchedules(reason: "previous_operation_finished")
        }
    }

    private func execute(_ initial: BankedResetSchedule) async {
        guard !self.isRunning, self.canRun(), !self.store.isAuthMutationInProgress() else {
            self.trace("execution_deferred", record: initial, metadata: ["gate": self.isRunning
                ? "reset_in_progress" : self.store.isAuthMutationInProgress()
                ? "auth_mutation" : self.diagnosticBlockReason() ?? "provider_busy"])
            return
        }
        self.isRunning = true
        self.store.beginAuthMutation()
        defer {
            self.store.endAuthMutation()
            self.isRunning = false
            self.onCompletion?()
        }
        var record = initial
        self.trace("execution_started", record: record)
        var capturedAuth: Data?
        let source = self.store.usageAuthSource()
        let lease = LeaseReservation(token: UUID().uuidString, home: "",
            expiresAt: Date().addingTimeInterval(180), createdAt: Date())
        guard await UsageProvider.claimLease(profileIDs: [record.profileID], reservation: lease, paths: source.paths) else {
            record.retryAfter = Date().addingTimeInterval(60)
            record.lastError = "Profile is in use; will retry."
            try? self.persist(record)
            self.trace("lease_busy", record: record)
            return
        }
        self.trace("lease_acquired", record: record)
        do {
            let profileID = record.profileID
            guard var auth = try await Task.detached(operation: {
                try source.vault.loadAuthBlob(profileID: profileID)
            }).value else { throw AuthError.notFound }
            capturedAuth = auth
            guard record.matchesAccount(authData: auth) else { throw ResetError.accountChanged }
            if record.lastAttemptAt == nil {
                self.trace("preflight_started", record: record)
                let preflight = try await CLIUsageFetcher.fetchResult(profileId: record.profileID,
                    authData: auth, codexConfigURL: self.store.codexConfigURL(),
                    environment: source.paths.environment, clientVersion: AppInfo.version)
                if let updated = preflight.updatedAuthData {
                    if try await Self.persistAuth(original: auth, updated: updated, record: record, source: source) {
                        record.accountFingerprint = AuthBlob.identityFingerprint(from: updated) ?? record.accountFingerprint
                        record.accountClaimFingerprints = AuthBlob.identityClaimFingerprints(from: updated)
                    }
                    auth = updated
                    capturedAuth = auth
                }
                self.store.updateStatus(record.profileID, .available(preflight.snapshot))
                guard let credit = preflight.snapshot.bankedResetCredits?.first(where: { $0.id == record.creditID }),
                      credit.isRedeemable() else {
                    throw ResetError.unavailable
                }
                self.trace("preflight_finished", record: record)
            }
            // Journal BEFORE the network operation. Crash/timeout retries use this key.
            record.lastAttemptAt = Date()
            record.retryAfter = Date().addingTimeInterval(300)
            record.lastError = nil
            try self.persist(record)
            self.trace("request_journaled", record: record)
            let result = try await CLIUsageFetcher.consumeReset(profileId: record.profileID,
                authData: auth, codexConfigURL: self.store.codexConfigURL(),
                creditId: record.creditID, idempotencyKey: record.idempotencyKey,
                environment: source.paths.environment, clientVersion: AppInfo.version)
            self.trace("operation_returned", record: record, metadata: ["outcome": result.outcome.rawValue])
            if let updated = result.updatedAuthData {
                do {
                    if try await Self.persistAuth(original: auth, updated: updated, record: record, source: source) {
                        record.accountFingerprint = AuthBlob.identityFingerprint(from: updated) ?? record.accountFingerprint
                        record.accountClaimFingerprints = AuthBlob.identityClaimFingerprints(from: updated)
                    }
                }
                catch { record.lastError = "Reset response received, but updated sign-in could not be saved: \(LogRedactor.redact(error.localizedDescription))" }
            }
            if let snapshot = result.snapshot { self.store.updateStatus(record.profileID, .available(snapshot)) }
            record.lastOutcome = result.outcome.rawValue
            if let refreshError = result.refreshError { record.lastError = refreshError }
            switch result.outcome {
            case .reset, .alreadyRedeemed:
                record.completedAt = Date()
                record.enabled = false
                record.retryAfter = nil
                self.lastMessage = "Reset used for \(self.label(for: record.profileID))."
            case .nothingToReset:
                // This was a definite no-op. A future retry is a new logical
                // attempt; uncertain network failures always keep the old key.
                record.idempotencyKey = UUID().uuidString
                record.lastAttemptAt = nil
                record.enabled = record.automaticallyRetryNoOp == true
                record.retryAfter = record.enabled ? Date().addingTimeInterval(900) : nil
                self.lastMessage = "Nothing to reset for \(self.label(for: record.profileID)); no credit was used."
            case .noCredit:
                record.enabled = false
                record.retryAfter = nil
                self.lastMessage = "This reset is no longer available for \(self.label(for: record.profileID))."
            }
            try self.persist(record)
            self.trace(record.completedAt == nil ? "not_consumed" : "confirmed", record: record,
                metadata: ["outcome": result.outcome.rawValue])
        } catch {
            if let operationError = error as? CLIUsageOperationError,
               let original = capturedAuth {
                // The Core helper will still refuse another account or a newer credential.
                if (try? await Self.persistAuth(original: original, updated: operationError.updatedAuthData, record: record, source: source)) == true {
                    record.accountFingerprint = AuthBlob.identityFingerprint(from: operationError.updatedAuthData) ?? record.accountFingerprint
                    record.accountClaimFingerprints = AuthBlob.identityClaimFingerprints(from: operationError.updatedAuthData)
                }
            }
            record.lastError = LogRedactor.redact(error.localizedDescription)
            record.retryAfter = Date().addingTimeInterval(300)
            if error is ResetError || error is AuthError
                || (error as? CLIUsageOperationError)?.isAuthRequired == true
                || (error as? CodexRPCError)?.isAuthRequired == true {
                record.enabled = false
                record.retryAfter = nil
            }
            self.lastMessage = record.lastError
            try? self.persist(record)
            self.trace("failed", record: record, metadata: ["error_type": String(describing: type(of: error)),
                "retry": record.enabled ? "scheduled" : "disabled"])
            AppLogger.warning("Reset operation deferred", metadata: ["profile": record.profileID, "error": record.lastError ?? "unknown"])
        }
        await UsageProvider.removeLease(profileIDs: [record.profileID], expectedToken: lease.token, paths: source.paths)
        self.store.flushCacheIfDirty()
    }

    private func trigger(for record: BankedResetSchedule) -> Date? {
        let expiry = self.store.statuses[record.profileID]?.snapshot?.bankedResetCredits?
            .first(where: { $0.id == record.creditID })?.expiresAt
        return record.triggerDate(expiresAt: expiry)
    }

    /// Local bounded log; omit account names, credit IDs, credentials and request keys.
    private func trace(_ event: String, record: BankedResetSchedule? = nil,
                       metadata: [String: String] = [:]) {
        var fields = self.diagnosticContext().merging(metadata) { _, new in new }
        if let record {
            if self.diagnosticIDs[record.id] == nil {
                self.diagnosticIDs[record.id] = "r\(self.diagnosticIDs.count + 1)"
            }
            fields["schedule"] = self.diagnosticIDs[record.id]
            fields["mode"] = record.mode.rawValue
            if let trigger = self.trigger(for: record) {
                fields["due_at"] = trigger.ISO8601Format()
                fields["lag_seconds"] = String(format: "%.3f", Date().timeIntervalSince(trigger))
            }
            if let retry = record.retryAfter { fields["retry_at"] = retry.ISO8601Format() }
        }
        AppLogger.info("Reset diagnostic \(event)", metadata: fields)
    }

    @discardableResult
    private nonisolated static func persistAuth(original: Data, updated: Data,
        record: BankedResetSchedule, source: ProfileStore.UsageAuthSource) async throws -> Bool {
        try await Task.detached {
            let outcome = try AuthCredentialUpdate.persistIfUnchanged(originalData: original,
                updatedData: updated, profileIDs: Array(Set([record.profileID] + (try source.vault.listProfileIDs()))), vault: source.vault)
            if outcome.savedProfileIDs.contains(record.profileID) { return true }
            return try source.vault.loadAuthBlob(profileID: record.profileID) == updated
        }.value
    }

    private func persist(_ record: BankedResetSchedule) throws {
        guard !self.storageReadFailed else { throw ResetError.storageUnreadable }
        var updated = self.schedules
        updated[record.id] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(updated), to: self.schedulesURL)
        self.schedules = updated
    }

    private func label(for profileID: String) -> String {
        self.store.config.profiles.first(where: { $0.id == profileID })?.label ?? "Profile \(profileID)"
    }

    enum ResetError: LocalizedError {
        case busy, unavailable, noExpiry, invalidDate, invalidOffset, accountChanged, duplicate, storageUnreadable, pendingAttempt
        var errorDescription: String? {
            switch self {
            case .busy: return "A refresh or profile operation is running. Try again shortly."
            case .unavailable: return "This reset has expired or is no longer available."
            case .noExpiry: return "This reset has no expiry date. Choose a specific date."
            case .invalidDate: return "Choose a future date before this reset expires."
            case .invalidOffset: return "Choose between 1 minute and 720 hours before expiry."
            case .accountChanged: return "This profile now belongs to a different account. Save a new schedule for that account."
            case .duplicate: return "This reset is already scheduled for another profile of the same account."
            case .pendingAttempt: return "An earlier reset request is still awaiting confirmation. Retry that request to confirm its outcome before replacing the schedule."
            case .storageUnreadable: return "Reset schedules could not be read. The existing file was preserved."
            }
        }
    }
}
