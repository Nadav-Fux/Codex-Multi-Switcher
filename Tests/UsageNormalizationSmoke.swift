@testable import CodexProfileCore
import Foundation

/// Uses in-memory windows and a fake RPC executable. No login, reset, or live account reads.
@main
struct UsageNormalizationSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    private static func window(_ used: Double, _ duration: Int? = nil, _ reset: Int? = nil) -> RPCRateLimitWindow {
        RPCRateLimitWindow(usedPercent: used, windowDurationMins: duration, resetsAt: reset)
    }

    private static func snapshot(_ primary: RPCRateLimitWindow?, _ secondary: RPCRateLimitWindow?, credits: RPCCreditsSnapshot? = nil) throws -> UsageSnapshot {
        try CLIUsageFetcher.makeSnapshot(from: RPCRateLimitSnapshot(primary: primary, secondary: secondary, credits: credits, planType: "prolite"))
    }

    private static func fetchFake(_ response: [String: Any]) async throws -> UsageSnapshot {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("usage-normalization-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let config = root.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config)
        try JSONSerialization.data(withJSONObject: response).write(to: root.appendingPathComponent("response.json"))
        let script = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys
        response = json.loads((pathlib.Path(os.environ['USAGE_FIXTURE_ROOT']) / 'response.json').read_text())
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize': result = {}
            elif method == 'account/rateLimits/read': result = response
            else: raise RuntimeError('Unexpected fixture method: ' + method)
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let auth = Data(#"{"tokens":{"access_token":"fake-access","refresh_token":"fake-refresh","account_id":"fixture-account"}}"#.utf8)
        return try await CLIUsageFetcher.fetch(profileId: "fixture", authData: auth, codexConfigURL: config,
            environment: ["CODEX_PROFILE_TEST_CLI": executable.path, "USAGE_FIXTURE_ROOT": root.path, "PATH": "/usr/bin:/bin"],
            clientVersion: "fixture")
    }

    static func main() async throws {
        let weekly = try snapshot(window(5, 10080, 2_000_000_000), nil)
        try require(!weekly.hasPrimaryWindow && weekly.hasSecondaryWindow, "Weekly-only quota must leave five-hour quota unavailable")
        try require(weekly.secondaryUsedPercent == 5 && weekly.secondaryWindowDurationMins == 10080 && weekly.primaryResetAt == nil,
                    "Weekly quota and reset metadata use the weekly slot")
        try require(weekly.secondaryResetAt == Date(timeIntervalSince1970: 2_000_000_000), "Weekly reset preserves the exact reported timestamp")
        try require(try snapshot(window(5, 10080), nil).secondaryResetAt == nil, "Missing weekly reset remains unknown")
        let five = try snapshot(nil, window(17, 300))
        try require(five.hasPrimaryWindow && !five.hasSecondaryWindow && five.primaryUsedPercent == 17, "Five-hour-only quota maps by duration")
        let swapped = try snapshot(window(31, 10080, 2_000_000_001), window(8, 300, 2_000_000_002))
        try require(swapped.primaryUsedPercent == 8 && swapped.secondaryUsedPercent == 31,
                    "Swapped wire positions map by duration")
        try require(swapped.primaryResetAt == Date(timeIntervalSince1970: 2_000_000_002), "Reset date follows its normalized window")
        let legacy = try snapshot(window(12), window(34, 60))
        try require(legacy.hasPrimaryWindow && legacy.hasSecondaryWindow && legacy.primaryUsedPercent == 12 && legacy.secondaryUsedPercent == 34,
                    "Unrecognized and missing durations retain positional compatibility")
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 101, Double.greatestFiniteMagnitude] {
            let result = try snapshot(window(invalid, 300), window(5, 10080))
            try require(!result.hasPrimaryWindow && result.hasSecondaryWindow, "Invalid percentages never become a fake quota or trap Int conversion")
        }
        try require(try snapshot(window(99.6, 300), nil).primaryUsedPercent == 100, "Valid rounding stays bounded")
        do {
            _ = try snapshot(nil, nil)
            throw Failure(description: "No quota/credits must fail instead of reporting full availability")
        } catch CLIUsageError.noRateLimitsFound { }
        let credits = try snapshot(nil, nil, credits: RPCCreditsSnapshot(hasCredits: true, unlimited: false, balance: "12"))
        try require(!credits.hasPrimaryWindow && !credits.hasSecondaryWindow && credits.creditsRemaining == 12, "Credits-only data has no quota windows")
        let oldJSON = Data(#"{"primaryUsedPercent":1,"secondaryUsedPercent":2,"fetchedAt":0}"#.utf8)
        let old = try JSONDecoder().decode(UsageSnapshot.self, from: oldJSON)
        try require(old.hasPrimaryWindow && old.hasSecondaryWindow, "Old caches without availability fields remain compatible")
        let roundtrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(weekly))
        try require(!roundtrip.hasPrimaryWindow && roundtrip.hasSecondaryWindow, "Availability flags persist through cache encoding")

        let rpcWeekly = try await fetchFake([
            "accountId": "fixture-account",
            "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            "rateLimitsByLimitId": ["codex": ["planType": "prolite", "primary": ["usedPercent": 5, "windowDurationMins": 10080], "secondary": NSNull()]],
        ])
        try require(rpcWeekly.planType == "prolite" && !rpcWeekly.hasPrimaryWindow && rpcWeekly.hasSecondaryWindow && rpcWeekly.secondaryUsedPercent == 5,
                    "Fake RPC Pro lite weekly-only Codex bucket reports 95% remaining weekly and no five-hour estimate")
        let rpcSwapped = try await fetchFake([
            "accountId": "fixture-account", "rateLimits": [
                "primary": ["usedPercent": 31, "windowDurationMins": 10080],
                "secondary": ["usedPercent": 8, "windowDurationMins": 300],
            ],
        ])
        try require(rpcSwapped.primaryUsedPercent == 8 && rpcSwapped.secondaryUsedPercent == 31, "Fake RPC normalizes swapped windows")
        print("Usage normalization checks passed (weekly-only Pro lite, swapped/missing windows, invalid percentages, old caches, fake RPC).")
    }
}
