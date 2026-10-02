import CodexProfileCore
import Foundation

/// Standalone checks for the reset transport. Only the fake executable below
/// receives requests; this runner never resolves the real Codex installation.
@main
struct BankedResetSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: message) }
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let config: URL
        let trace: URL
        let auth: Data

        init(mode: String) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("banked-reset-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: self.root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            self.executable = self.root.appendingPathComponent("fake-codex")
            self.config = self.root.appendingPathComponent("config.toml")
            self.trace = self.root.appendingPathComponent("trace.jsonl")
            self.auth = Data("""
            {"tokens":{"access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"fixture-account"}}
            """.utf8)
            try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: self.config)
            try Data(Self.fake.utf8).write(to: self.executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.executable.path)
            try Data(mode.utf8).write(to: self.root.appendingPathComponent("mode"))
        }

        var environment: [String: String] {
            [
                "CODEX_PROFILE_TEST_CLI": self.executable.path,
                "RESET_FIXTURE_ROOT": self.root.path,
                "PATH": "/usr/bin:/bin",
                "OPENAI_API_KEY": "fixture-global-key",
                "CODEX_API_KEY": "fixture-global-key",
            ]
        }

        func requests() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: self.trace.path) else { return [] }
            return try String(contentsOf: self.trace, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: self.root) }

        private static let fake = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys
        root = pathlib.Path(os.environ['RESET_FIXTURE_ROOT'])
        mode = (root / 'mode').read_text()
        home = pathlib.Path(os.environ['CODEX_HOME'])
        reads = 0
        selected = {'id':'opaque-selected','status':'available','resetType':'codexRateLimits','grantedAt':1700000000,'expiresAt':2000000000,'title':'Full reset','description':'Fixture only'}
        historical = {'id':'opaque-used','status':'redeemed','resetType':'codexRateLimits','grantedAt':1690000000,'expiresAt':1800000000,'title':None,'description':None}
        def rotate(wrong=False):
            value = json.loads((home / 'auth.json').read_text())
            value['tokens']['refresh_token'] = 'fixture-refreshed'
            if wrong: value['tokens']['account_id'] = 'different-fixture-account'
            (home / 'auth.json').write_text(json.dumps(value))
        def reply(request, result=None, error=None):
            value = {'id': request['id']}
            value['error' if error else 'result'] = {'code':-32000,'message':error} if error else result
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            request['fixtureHome'] = str(home)
            request['fixtureFileAuth'] = 'cli_auth_credentials_store="file"' in sys.argv
            request['fixtureNoShellKeys'] = not os.environ.get('OPENAI_API_KEY') and not os.environ.get('CODEX_API_KEY')
            with (root / 'trace.jsonl').open('a') as trace: trace.write(json.dumps(request)+'\n')
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize': reply(request, {})
            elif method == 'account/rateLimits/read':
                reads += 1
                if mode == 'rotate-failure':
                    rotate()
                    reply(request, error='HTTP 401 Unauthorized')
                    continue
                if mode == 'refresh-failure' and reads > 1:
                    reply(request, error='Fixture offline after known reset')
                    continue
                if mode == 'wrong-identity': rotate(wrong=True)
                missing = mode == 'already-redeemed' or reads > 1
                credits = [] if missing else [selected, historical]
                reply(request, {
                    'accountId':'wrong-fixture-account' if mode == 'wrong-usage-account' else 'fixture-account',
                    'rateLimits': {'primary': {'usedPercent':99,'windowDurationMins':60},'secondary':None},
                    'rateLimitsByLimitId': {'codex':{'primary':{'usedPercent':0 if reads > 1 else 45,'windowDurationMins':300},'secondary':{'usedPercent':70,'windowDurationMins':10080}}},
                    'rateLimitResetCredits':{'availableCount':0 if missing else 4,'credits':credits}
                })
            elif method == 'account/rateLimitResetCredit/consume':
                rotate()
                reply(request, {'outcome':'alreadyRedeemed' if mode == 'already-redeemed' else 'reset'})
            else: reply(request, error='Unexpected fixture method')
        """#
    }

    static func main() async throws {
        let key = "02000000-0000-4000-8000-000000000001"

        let inventory = try Fixture(mode: "inventory")
        defer { inventory.cleanup() }
        let fetched = try await CLIUsageFetcher.fetchResult(
            profileId: "fixture", authData: inventory.auth, codexConfigURL: inventory.config,
            environment: inventory.environment, clientVersion: "fixture")
        try self.require(fetched.snapshot.primaryUsedPercent == 45, "Prefer the included Codex bucket")
        try self.require(fetched.snapshot.bankedResetCount == 4, "Count remains authoritative with capped detail rows")
        try self.require(fetched.snapshot.bankedResetCredits?.count == 2, "Preserve rich rows and their status")
        try self.require(fetched.snapshot.bankedResetExpirations?.count == 1, "Exclude redeemed dates from availability")
        let credit = fetched.snapshot.bankedResetCredits?.first
        try self.require(credit?.id == "opaque-selected" && credit?.isAvailable == true, "Preserve opaque credit identity")
        try self.require(credit?.title == "Full reset" && credit?.description == "Fixture only", "Preserve backend labels")
        try self.require(credit?.grantedAt == Date(timeIntervalSince1970: 1_700_000_000), "Decode grant date")
        try self.require(credit?.isRedeemable(now: Date(timeIntervalSince1970: 1_900_000_000)) == true, "Available future credit redeemable")
        try self.require(credit?.isRedeemable(now: Date(timeIntervalSince1970: 2_000_000_000)) == false, "Expiry boundary not redeemable")

        let legacyJSON = Data("""
        {"primaryUsedPercent":1,"secondaryUsedPercent":2,"fetchedAt":0,"bankedResetCount":4,"bankedResetExpirations":[null]}
        """.utf8)
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: legacyJSON)
        try self.require(legacy.bankedResetCredits == nil && legacy.bankedResetCount == 4, "Old snapshots decode without rich details")

        for mode in ["success", "refresh-failure", "already-redeemed"] {
            let fixture = try Fixture(mode: mode)
            defer { fixture.cleanup() }
            let result = try await CLIUsageFetcher.consumeReset(
                profileId: "fixture", authData: fixture.auth, codexConfigURL: fixture.config,
                creditId: "opaque-selected", idempotencyKey: key,
                environment: fixture.environment, clientVersion: "fixture")
            try self.require(result.outcome.completedRedemption, "Preserve known successful redemption for \(mode)")
            try self.require(result.updatedAuthData != nil, "Preserve rotated credentials for \(mode)")
            if mode == "refresh-failure" {
                try self.require(result.snapshot == nil && result.refreshError != nil, "Do not erase success when refresh fails")
            } else {
                try self.require(result.snapshot != nil && result.refreshError == nil, "Refresh usage after consuming")
            }
            let requests = try fixture.requests()
            let consumes = requests.filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }
            try self.require(consumes.count == 1, "Exactly one explicit redemption request")
            let params = consumes.first?["params"] as? [String: Any]
            try self.require(params?["creditId"] as? String == "opaque-selected", "Send selected opaque ID")
            try self.require(params?["idempotencyKey"] as? String == key, "Send caller's persistent idempotency key")
            try self.require(requests.filter { $0["method"] as? String == "account/rateLimits/read" }.count == 2, "Read before and after redemption")
            try self.require(requests.allSatisfy { $0["fixtureFileAuth"] as? Bool == true }, "Force isolated file auth even if source config uses keyring")
            try self.require(requests.allSatisfy { $0["fixtureNoShellKeys"] as? Bool == true }, "Shell API keys cannot override the selected profile")
            if let isolated = requests.first?["fixtureHome"] as? String {
                try self.require(!FileManager.default.fileExists(atPath: isolated), "Remove isolated credentials after child exits")
            }
        }

        let failed = try Fixture(mode: "rotate-failure")
        defer { failed.cleanup() }
        do {
            _ = try await CLIUsageFetcher.fetchResult(
                profileId: "fixture", authData: failed.auth, codexConfigURL: failed.config,
                environment: failed.environment, clientVersion: "fixture")
            throw Failure(description: "Fixture failure should throw")
        } catch let error as CLIUsageOperationError {
            try self.require(error.isAuthRequired, "Preserve original auth error classification")
            try self.require(AuthBlob.identityMatches(failed.auth, error.updatedAuthData), "Expose valid same-account rotation even after failure")
        }

        let wrongIdentity = try Fixture(mode: "wrong-identity")
        defer { wrongIdentity.cleanup() }
        let wrong = try await CLIUsageFetcher.fetchResult(
            profileId: "fixture", authData: wrongIdentity.auth, codexConfigURL: wrongIdentity.config,
            environment: wrongIdentity.environment, clientVersion: "fixture")
        try self.require(wrong.updatedAuthData == nil, "Never expose replacement credentials for a different account")

        let wrongUsage = try Fixture(mode: "wrong-usage-account")
        defer { wrongUsage.cleanup() }
        do {
            _ = try await CLIUsageFetcher.consumeReset(
                profileId: "fixture", authData: wrongUsage.auth, codexConfigURL: wrongUsage.config,
                creditId: "opaque-selected", idempotencyKey: key,
                environment: wrongUsage.environment, clientVersion: "fixture")
            throw Failure(description: "Misrouted usage must be rejected")
        } catch is CLIUsageError {
            let requests = try wrongUsage.requests()
            try self.require(!requests.contains { $0["method"] as? String == "account/rateLimitResetCredit/consume" }, "Verify account before any redemption request")
        }

        let invalid = try Fixture(mode: "invalid")
        defer { invalid.cleanup() }
        do {
            _ = try await CLIUsageFetcher.consumeReset(
                profileId: "fixture", authData: invalid.auth, codexConfigURL: invalid.config,
                creditId: " ", idempotencyKey: key,
                environment: invalid.environment, clientVersion: "fixture")
            throw Failure(description: "Whitespace ID must be rejected")
        } catch is CLIUsageError {
            try self.require(try invalid.requests().isEmpty, "Validate input before spawning any executable")
        }
        print("PASS: banked-reset inventory, isolated RPC, exact-credit retries, token rotation, and known-outcome handling")
    }
}
