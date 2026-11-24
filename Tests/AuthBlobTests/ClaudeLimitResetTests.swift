import CodexProfileCore
import Foundation
import Testing

struct ClaudeLimitResetTests {
    @Test
    func kindFollowsClaudeCode() {
        #expect(ClaudeLimitReset.kind(type: nil, clears: ["seven_day"], givesBackWeekly: true) == .fable)
        #expect(ClaudeLimitReset.kind(type: "full", clears: [], givesBackWeekly: false) == .full)
        #expect(ClaudeLimitReset.kind(type: nil, clears: ["five_hour"], givesBackWeekly: false) == .session)
        #expect(ClaudeLimitReset.kind(type: nil, clears: ["seven_day"], givesBackWeekly: false) == .weekly)
        #expect(ClaudeLimitReset.kind(type: nil, clears: ["five_hour", "seven_day"], givesBackWeekly: false) == .full)
        #expect(ClaudeLimitReset.kind(type: "something_new", clears: ["five_hour"], givesBackWeekly: false) == .session)
    }

    @Test
    func parsesGrantsAndSkipsMalformedOnes() throws {
        let block: [String: Any] = [
            "eligible": true,
            "grants": [
                ["id": "fable-1", "label": "Fable reset", "resets_left": 1, "resets_total": 1,
                 "gives_back_weekly": true, "clears": ["seven_day"], "ends_at": "2026-11-30T10:00:00.000Z",
                 "usable_now": true],
                ["id": "full-1", "type": "full", "resets_left": 2, "resets_total": 3, "paused": true],
                ["id": "bad", "resets_left": "two"],
                ["label": "no id", "resets_left": 1],
            ],
        ]
        let resets = try #require(ClaudeLimitReset.parse(block))
        #expect(resets.map(\.id) == ["fable-1", "full-1"])
        #expect(resets[0].kind == .fable)
        #expect(resets[0].usableNow)
        #expect(resets[0].endsAt != nil)
        #expect(resets[1].kind == .full)
        #expect(resets[1].left == 2 && resets[1].total == 3 && resets[1].paused)
    }

    @Test
    func ineligibleOrMissingBlocks() {
        #expect(ClaudeLimitReset.parse(nil) == nil)
        #expect(ClaudeLimitReset.parse(["eligible": false, "grants": [["id": "x", "resets_left": 1]]]) == [])
    }

    @Test
    func normalizedFormRoundTrips() throws {
        let original = ClaudeLimitReset(id: "fable-1", label: "Fable reset", kind: .fable, left: 1, total: 1,
                                        endsAt: Date(timeIntervalSince1970: 1_800_000_000), usableNow: true, paused: false)
        let full = ClaudeLimitReset(id: "full-1", label: "", kind: .full, left: 0, total: 1,
                                    endsAt: nil, usableNow: false, paused: false)
        let parsed = try #require(ClaudeLimitReset.parse(["eligible": true, "grants": [original.normalized, full.normalized]]))
        #expect(parsed == [original, full])
    }

    @Test
    func snapshotsWithoutResetsStillDecode() throws {
        let json = #"{"observedAt":0,"source":"oauthUsage","isStale":false,"accountVerified":true}"#
        let snapshot = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.resets == nil)
    }
}
