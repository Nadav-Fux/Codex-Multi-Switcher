import Cocoa
import CodexProfileCore
import CryptoKit
import Foundation

/// Active quota queries use a fake Codex executable and temp-only file vaults.
@main
struct ActiveUsageSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func jwt(expiration: TimeInterval, plan: String) throws -> String {
        let claims: [String: Any] = ["exp": expiration, "sub": "fixture-user", "plan": plan]
        let data = try JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).fixture-signature"
    }

    static func auth(access: String, refresh: String, account: String = "fixture-account", extras: Bool = false) throws -> Data {
        var tokens: [String: Any] = ["access_token": access, "refresh_token": refresh, "account_id": account]
        if extras { tokens["legacy_refresh"] = refresh }
        var object: [String: Any] = ["tokens": tokens, "last_refresh": "2026-09-30T00:00:00Z"]
        if extras { object["refresh_token"] = refresh }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("active-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try AtomicFileWriter.ensurePrivateDirectory(root)
        let now = Date()
        let liveJWT = try jwt(expiration: now.addingTimeInterval(3600).timeIntervalSince1970, plan: "pro_lite")
        let savedJWT = try jwt(expiration: now.addingTimeInterval(3600).timeIntervalSince1970, plan: "plus")
        let liveRefresh = "fixture-live-real-refresh-never-reaches-child"
        let live = try auth(access: liveJWT, refresh: liveRefresh, extras: true)
        let saved = try auth(access: savedJWT, refresh: "fixture-independent-saved-refresh")
        let query = ReadOnlyUsageAuth.prepare(from: live, now: now)!
        let queryCredentials = try AuthBlob.load(from: query)
        try require(queryCredentials.accessToken == liveJWT && queryCredentials.refreshToken == ReadOnlyUsageAuth.disabledRefreshToken,
                    "Live query preserves access token and replaces actual refresh token")
        try require(!String(data: query, encoding: .utf8)!.contains(liveRefresh), "Unknown credential-copy fields are not forwarded")
        try require(AuthBlob.identityMatches(live, query), "Query preserves current account identity")
        let expired = try auth(access: jwt(expiration: now.addingTimeInterval(-1).timeIntervalSince1970, plan: "pro_lite"), refresh: liveRefresh)
        let opaque = try auth(access: "opaque-fixture-access", refresh: liveRefresh)
        try require(ReadOnlyUsageAuth.prepare(from: expired, now: now) == nil && ReadOnlyUsageAuth.prepare(from: opaque) == nil,
                    "Expired or unknown JWT expiration cannot use active read-only auth")

        let executable = root.appendingPathComponent("fake-codex")
        try AtomicFileWriter.write(Data(fake.utf8), to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = ["CODEX_PROFILE_HOME": root.path, "CODEX_PROFILE_TEST_CLI": executable.path,
                           "ACTIVE_USAGE_FIXTURE_ROOT": root.path, "PATH": "/usr/bin:/bin"]
        let paths = AppPaths(environment: environment)
        let vault = FileAuthVault(root: paths.devAuthStoreURL, authLockURL: paths.authLockURL)
        try vault.saveAuthBlob(saved, profileID: "1")
        try vault.saveAuthBlob(saved, profileID: "2")
        try AtomicFileWriter.write(live, to: paths.liveAuthURL)
        let config = AppConfig(profiles: [ProfileConfig(id: "1", label: "Active"), ProfileConfig(id: "2", label: "Independent")],
                               activeProfile: "1")
        try AtomicFileWriter.write(JSONEncoder().encode(config), to: paths.configURL)
        let store = ProfileStore(authVault: vault, environment: environment)
        store.setLiveProfileId("1")
        let source = store.usageAuthSource()
        let active = try await UsageProvider.loadAuthData(source: source, profileID: "1", isLive: true)!
        let inactive = try await UsageProvider.loadAuthData(source: source, profileID: "2", isLive: false)!
        try require(active.isReadOnlyLive && active.data == live &&
                    (try AuthBlob.load(from: active.queryData)).refreshToken == ReadOnlyUsageAuth.disabledRefreshToken,
                    "Current active identity prefers the newer live plan using a read-only query copy")
        try require(!inactive.isReadOnlyLive && inactive.data == saved && inactive.queryData == saved,
                    "Inactive profiles use only their independently saved credentials")
        let groups = await UsageProvider.groupContexts([
            UsageProvider.RefreshContext(id: "1", cached: nil, isLive: true),
            UsageProvider.RefreshContext(id: "2", cached: nil, isLive: false),
        ], source: source)
        try require(groups.count == 2 && groups.allSatisfy({ $0.contexts.count == 1 }),
                    "Active read-only group cannot share an inactive account's saved fetch")
        let mismatch = try auth(access: liveJWT, refresh: liveRefresh, account: "other-account")
        try AtomicFileWriter.write(mismatch, to: paths.liveAuthURL)
        let mismatchLoaded = try await UsageProvider.loadAuthData(source: source, profileID: "1", isLive: true)!
        try require(!mismatchLoaded.isReadOnlyLive && mismatchLoaded.data == saved, "Different live account never borrowed")
        try AtomicFileWriter.write(expired, to: paths.liveAuthURL)
        let expiredLoaded = try await UsageProvider.loadAuthData(source: source, profileID: "1", isLive: true)!
        try require(!expiredLoaded.isReadOnlyLive && expiredLoaded.data == saved, "Expired active token falls back to saved session")
        try require(try await UsageProvider.loadAuthData(source: source, profileID: "missing", isLive: true) == nil,
                    "Missing saved identity cannot borrow the current live account")
        try AtomicFileWriter.write(live, to: paths.liveAuthURL)
        let condemned = SHA256.hash(data: Data("fixture-independent-saved-refresh".utf8)).map { String(format: "%02x", $0) }.joined()
        let rejection = RenewalState(action: "rejected", reason: "fixture saved session expired", timestamp: now,
                                     credentialFingerprint: String(condemned.prefix(12)))
        store.recordRenewalState(rejection, for: "1")
        let provider = UsageProvider(store: store)
        provider.refreshAll(force: true)
        let deadline = Date().addingTimeInterval(15)
        while provider.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(!provider.isRefreshing, "Fake usage refresh completes")
        guard case let .available(snapshot) = store.statuses["1"] else {
            throw Failure(description: "Active current quota remains available despite independent saved-session rejection")
        }
        try require(snapshot.planType == "pro_lite" && !snapshot.hasPrimaryWindow && snapshot.hasSecondaryWindow &&
                    snapshot.secondaryUsedPercent == 37,
                    "Fresh upgraded weekly-only plan quota displayed without inventing a 5-hour quota")
        try require(store.isUsingLiveUsage("1") && !store.isUsingLiveUsage("2"), "UI exposes current Desktop usage source separately")
        try require(store.cache.renewalStates["1"]?.renewalAction == .rejected &&
                    store.cache.renewalStates["1"]?.credentialFingerprint == rejection.credentialFingerprint,
                    "Fresh live quota does not clear rejected saved-session health")
        try require(!store.authCanBeActivated(for: "1"), "Rejected stored credentials remain unactivatable")
        try require(try vault.loadAuthBlob(profileID: "1") == saved && vault.loadAuthBlob(profileID: "2") == saved,
                    "Neither active nor inactive saved credentials are replaced by live usage queries")
        try require(try Data(contentsOf: paths.liveAuthURL) == live, "Desktop auth remains byte-identical after child attempted credential writes")
        let records = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        try require(records.contains(where: { $0["source"] as? String == "read-only-live" }) &&
                    records.contains(where: { $0["source"] as? String == "saved" }), "Fake child exercised separate active and inactive sources")
        // The active slot metadata deliberately stays unchanged while Desktop
        // credentials change during a fetch. Finalize must revalidate provenance.
        let ready = root.appendingPathComponent("fetch-started")
        try AtomicFileWriter.write(Data("switch".utf8), to: root.appendingPathComponent("mode"))
        provider.refreshAll(force: true)
        let startDeadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: ready.path) && Date() < startDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(fm.fileExists(atPath: ready.path), "Delayed fake live fetch starts")
        try AtomicFileWriter.write(mismatch, to: paths.liveAuthURL)
        let finishDeadline = Date().addingTimeInterval(10)
        while provider.isRefreshing && Date() < finishDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(!provider.isRefreshing && !store.isUsingLiveUsage("1") &&
                    store.refreshDiagnostics["1"]?.lastDecision == "live-read-only-source-changed",
                    "Externally changed live account cannot receive an in-flight prior-account snapshot")
        if case .available = store.statuses["1"] {
            throw Failure(description: "Changed live account was still presented as freshly available")
        }
        try require(try Data(contentsOf: paths.liveAuthURL) == mismatch, "A source change cannot trigger any late Desktop auth write")
        print("Active usage checks passed (matched fresh JWT, refresh removal, independent inactive auth, no auth writes, saved rejection retained).")
    }

    static let fake = #"""
    #!/usr/bin/python3
    import json, os, pathlib, time, sys
    root = pathlib.Path(os.environ['ACTIVE_USAGE_FIXTURE_ROOT'])
    home = pathlib.Path(os.environ['CODEX_HOME'])
    original = json.loads((home / 'auth.json').read_text())
    read_only = original['tokens']['refresh_token'] == 'codex-multi-switcher-read-only'
    def reply(request, result):
        print(json.dumps({'id':request['id'], 'result':result}), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request: continue
        if request['method'] == 'initialize': reply(request, {})
        elif request['method'] == 'account/rateLimits/read':
            with (root / 'trace.jsonl').open('a') as stream:
                stream.write(json.dumps({'source':'read-only-live' if read_only else 'saved'})+'\n')
            if read_only:
                if (root / 'mode').exists():
                    (root / 'fetch-started').write_text('ready')
                    time.sleep(0.3)
                original['tokens']['refresh_token'] = 'fixture-child-rotated-output-must-be-discarded'
                (home / 'auth.json').write_text(json.dumps(original))
            reply(request, {'accountId':'fixture-account', 'rateLimits':{
                'planType':'pro_lite' if read_only else 'plus',
                'primary':{'usedPercent':37 if read_only else 75, 'windowDurationMins':10080 if read_only else 300, 'resetsAt':int(time.time())+3600},
                'secondary':None if read_only else {'usedPercent':20, 'windowDurationMins':10080, 'resetsAt':int(time.time())+7200}}})
        else: reply(request, {})
    """#
}
