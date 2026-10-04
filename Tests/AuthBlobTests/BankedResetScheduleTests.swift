import CodexProfileCore
import Foundation
import Testing

struct BankedResetScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(mode: BankedResetScheduleMode = .atDate) -> BankedResetSchedule {
        BankedResetSchedule(profileID: "1", creditID: "credit-a", accountFingerprint: "account-a",
            mode: mode, scheduledAt: self.now, hoursBeforeExpiry: 24, idempotencyKey: "durable-request",
            creditExpiresAt: self.now.addingTimeInterval(24 * 3600))
    }

    @Test func dateScheduleRunsAtItsBoundary() {
        let record = self.record()
        #expect(!record.isDue(expiresAt: nil, now: self.now.addingTimeInterval(-1)))
        #expect(record.isDue(expiresAt: nil, now: self.now))
        #expect(record.isDue(expiresAt: nil, now: self.now.addingTimeInterval(3600)))
    }

    @Test func expiryScheduleSurvivesMissingCache() {
        let record = self.record(mode: .beforeExpiry)
        #expect(record.triggerDate(expiresAt: nil) == self.now)
        #expect(record.isDue(expiresAt: nil, now: self.now))
        #expect(record.triggerDate(expiresAt: self.now.addingTimeInterval(48 * 3600)) == self.now.addingTimeInterval(24 * 3600))
    }

    @Test func minuteOffsetsPreserveExpirySeconds() {
        let expiry = self.now.addingTimeInterval(3600 + 25)
        let record = BankedResetSchedule(profileID: "fixture", creditID: "fixture-credit",
            accountFingerprint: "fixture-account", mode: .beforeExpiry, scheduledAt: self.now,
            hoursBeforeExpiry: 1, minutesBeforeExpiry: 4, creditExpiresAt: expiry)
        let target = expiry.addingTimeInterval(-64 * 60)
        #expect(record.triggerDate(expiresAt: nil) == target)
        #expect(!record.isDue(expiresAt: nil, now: target.addingTimeInterval(-0.001)))
        #expect(record.isDue(expiresAt: nil, now: target))
    }

    @Test func disabledCompletedAndBackedOffRequestsDoNotRun() {
        var record = self.record()
        record.enabled = false
        #expect(!record.isDue(expiresAt: nil, now: self.now))
        record.enabled = true
        record.completedAt = self.now
        #expect(!record.isDue(expiresAt: nil, now: self.now))
        record.completedAt = nil
        record.retryAfter = self.now.addingTimeInterval(300)
        #expect(!record.isDue(expiresAt: nil, now: self.now))
        #expect(record.isDue(expiresAt: nil, now: self.now.addingTimeInterval(300)))
    }

    @Test func expiryCannotBeInventedAndHoursAreBounded() {
        var record = self.record(mode: .beforeExpiry)
        record.creditExpiresAt = nil
        #expect(record.triggerDate(expiresAt: nil) == nil)
        #expect(!record.isDue(expiresAt: nil, now: self.now))
        let low = BankedResetSchedule(profileID: "1", creditID: "c", accountFingerprint: "a", mode: .beforeExpiry,
            scheduledAt: self.now, hoursBeforeExpiry: -50)
        let high = BankedResetSchedule(profileID: "1", creditID: "c", accountFingerprint: "a", mode: .beforeExpiry,
            scheduledAt: self.now, hoursBeforeExpiry: 9000)
        #expect(low.hoursBeforeExpiry == 1)
        #expect(high.hoursBeforeExpiry == 720)
    }

    @Test func accountBindingAcceptsAddedClaimsAndRejectsChangedAccount() {
        let original = Data(#"{"tokens":{"access_token":"fixture","refresh_token":"fixture","account_id":"a"}}"#.utf8)
        let enriched = Data(#"{"tokens":{"access_token":"fixture-new","refresh_token":"fixture-new","account_id":"a","id_token":"e30.eyJzdWIiOiJmaXh0dXJlLXVzZXIifQ.fixture"}}"#.utf8)
        let other = Data(#"{"tokens":{"access_token":"fixture","refresh_token":"fixture","account_id":"b"}}"#.utf8)
        var record = self.record()
        record.accountClaimFingerprints = AuthBlob.identityClaimFingerprints(from: original)
        #expect(record.matchesAccount(authData: enriched))
        #expect(!record.matchesAccount(authData: other))
        #expect(record.accountClaimFingerprints?.values.allSatisfy { $0.count == 64 } == true)
    }

    @Test func journalPreservesCreditAndRequestAcrossRelaunch() throws {
        var record = self.record()
        record.lastAttemptAt = self.now
        record.retryAfter = self.now.addingTimeInterval(300)
        record.lastError = "Offline"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(BankedResetSchedule.self, from: encoder.encode(record))
        #expect(restored == record)
        #expect(restored.id == "1:credit-a")
        #expect(restored.idempotencyKey == "durable-request")
        #expect(restored.accountFingerprint == "account-a")
    }
}
