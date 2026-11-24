@testable import CodexProfileCore
import Foundation
import Testing

@Suite("Codex rate-limit snapshots")
struct CodexRateLimitsTests {

    // Since 674376b ("correct weekly-only Codex quotas") the window duration,
    // not the RPC field, picks the display slot: a weekly-only plan shows in
    // the weekly slot and leaves the 5-hour slot empty.
    @Test("places a weekly-only primary window in the weekly slot")
    func capturesWeeklyPrimaryWindow() throws {
        let json = """
        {
          "rateLimits": {
            "primary": {
              "usedPercent": 18,
              "windowDurationMins": 10080,
              "resetsAt": 1784487871
            },
            "secondary": null,
            "credits": {
              "hasCredits": false,
              "unlimited": false,
              "balance": null
            },
            "planType": "team"
          }
        }
        """

        let response = try JSONDecoder().decode(RPCRateLimitsResponse.self, from: Data(json.utf8))
        let snapshot = try CLIUsageFetcher.makeSnapshot(from: response.rateLimits)

        #expect(snapshot.primaryUsedPercent == 0)
        #expect(snapshot.primaryWindowDurationMins == nil)
        #expect(snapshot.secondaryUsedPercent == 18)
        #expect(snapshot.secondaryWindowDurationMins == 10_080)
    }

    @Test("decodes snapshots cached before window durations were recorded")
    func decodesLegacySnapshot() throws {
        let json = """
        {
          "planType": "team",
          "creditsRemaining": null,
          "primaryUsedPercent": 18,
          "primaryResetAt": "2026-07-19T20:00:00Z",
          "secondaryUsedPercent": 0,
          "secondaryResetAt": null,
          "fetchedAt": "2026-07-14T20:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.primaryWindowDurationMins == nil)
        #expect(snapshot.secondaryWindowDurationMins == nil)
    }
}
