import Cocoa
import CodexProfileCore
import Foundation

@main
struct AppFeatureSmoke {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        try Self.require(IconRenderer.render(primaryRemainingPercent: 74, secondaryRemainingPercent: 4).size.height == 23,
            "Menu bar digits enlarged without unbounded height")
        let mixed = IconRenderer.render(primaryRemainingPercent: 74, secondaryRemainingPercent: 4,
            primaryShowsUsed: true, secondaryShowsUsed: false)
        try Self.require(mixed.accessibilityDescription?.contains("26 percent used") == true, "Independent used mode")
        try Self.require(mixed.accessibilityDescription?.contains("4 percent remaining") == true, "Independent remaining mode")
        try Self.require(!mixed.isTemplate && mixed.size.width < 55, "Colored compact badge")
        try Self.require(IconRenderer.color(for: 50) == IconRenderer.highQuotaColor, "50 percent threshold")
        try Self.require(IconRenderer.color(for: 20) == IconRenderer.midQuotaColor, "20 percent threshold")
        try Self.require(IconRenderer.color(for: 19) == IconRenderer.lowQuotaColor, "Low quota threshold")
        let missingCodex = IconRenderer.render(primaryRemainingPercent: nil, secondaryRemainingPercent: 95)
        try Self.require(missingCodex.accessibilityDescription?.contains("5 hours unavailable") == true &&
            missingCodex.accessibilityDescription?.contains("week 95 percent remaining") == true,
            "Weekly-only Codex quota never fabricates five-hour availability")
        let weeklyReset = Date().addingTimeInterval(6 * 86400 + 20 * 3600)
        let weeklyBadge = IconRenderer.render(primaryRemainingPercent: nil, secondaryRemainingPercent: 95,
            weeklyOnly: true, weeklyResetAt: weeklyReset)
        let weeklyCompact = IconRenderer.render(primaryRemainingPercent: nil, secondaryRemainingPercent: 95,
            weeklyOnly: true, weeklyResetAt: weeklyReset, showResetCountdown: false)
        try Self.require(weeklyBadge.size.height == 23 && weeklyBadge.size.width < 130 &&
            weeklyBadge.accessibilityDescription?.contains("week 95 percent remaining") == true &&
            weeklyBadge.accessibilityDescription?.contains("5 hours") == false,
            "Weekly-only badge is a single bounded number without a five-hour label")
        try Self.require(weeklyCompact.size.width < weeklyBadge.size.width &&
            weeklyCompact.accessibilityDescription?.contains("resets") == false,
            "Weekly reset countdown can be hidden")
        try Self.require(IconRenderer.render(primaryRemainingPercent: nil, secondaryRemainingPercent: 95,
            secondaryShowsUsed: true, weeklyOnly: true).accessibilityDescription?.contains("week 5 percent used") == true,
            "Weekly-only badge respects its independent used preference")
        let claudeUsage = ClaudeUsageSnapshot(fiveHour: ClaudeUsageWindow(usedPercentage: 25),
            sevenDay: nil, observedAt: Date(), source: .nativeBridge, isStale: false, accountVerified: true)
        let claudeBadge = ClaudeIconRenderer.render(snapshot: claudeUsage, primaryShowsUsed: false, secondaryShowsUsed: true)
        try Self.require(claudeBadge.size.height == 23 && claudeBadge.size.width < 70 && !claudeBadge.isTemplate,
            "Claude badge stays compact and colored")
        try Self.require(claudeBadge.accessibilityDescription?.contains("75 percent remaining") == true &&
            claudeBadge.accessibilityDescription?.contains("week unavailable") == true,
            "Claude missing weekly quota stays unavailable")
        let staleClaude = ClaudeUsageSnapshot(fiveHour: claudeUsage.fiveHour, sevenDay: nil,
            observedAt: Date().addingTimeInterval(-1000), source: .nativeBridge, isStale: true, accountVerified: true)
        try Self.require(ClaudeIconRenderer.render(snapshot: staleClaude, primaryShowsUsed: false, secondaryShowsUsed: false)
            .accessibilityDescription?.contains("5 hours unavailable") == true, "Stale Claude badge never implies current quota")
        let expiredClaude = ClaudeUsageSnapshot(fiveHour: ClaudeUsageWindow(usedPercentage: 25, resetsAt: Date().addingTimeInterval(-1)),
            sevenDay: ClaudeUsageWindow(usedPercentage: 30, resetsAt: Date().addingTimeInterval(3600)),
            observedAt: Date(), source: .nativeBridge, isStale: false, accountVerified: true)
        let expiredBadge = ClaudeIconRenderer.render(snapshot: expiredClaude, primaryShowsUsed: false, secondaryShowsUsed: false)
        try Self.require(expiredBadge.accessibilityDescription?.contains("5 hours unavailable") == true &&
            expiredBadge.accessibilityDescription?.contains("week 70 percent remaining") == true,
            "Expired window stays unavailable without hiding a current independent window")
        try Self.require(QuotaDisplayPreferences.value(usedPercent: 101, showsUsed: false) == 0, "Clamp remaining")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Label":"fixture.login",
            "ProgramArguments":["/usr/bin/open","-a","/fixture/Test.app","--args","--launch-at-login"],
            "RunAtLoad":true], format: .xml, options: 0)
        try Self.require(LocalLaunchAtLogin.hasExpectedContents(plist, label: "fixture.login",
            bundleURL: URL(fileURLWithPath: "/fixture/Test.app")), "Validate owned login item shape")
        try Self.require(!LocalLaunchAtLogin.hasExpectedContents(plist, label: "another.login",
            bundleURL: URL(fileURLWithPath: "/fixture/Test.app")), "Reject another app's login item")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        try Data(Self.fake.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = ["CODEX_PROFILE_HOME": root.path, "CODEX_PROFILE_TEST_CLI": executable.path,
            "RESET_APP_FIXTURE_ROOT": root.path, "PATH":"/usr/bin:/bin"]
        let paths = AppPaths(environment: environment)
        let vault = FileAuthVault(root: paths.devAuthStoreURL, authLockURL: paths.authLockURL)
        let auth = Data(#"{"tokens":{"access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"fixture-account"}}"#.utf8)
        try vault.saveAuthBlob(auth, profileID: "1")
        let store = ProfileStore(authVault: vault, environment: environment)
        let scheduleURL = paths.switcherHome.appendingPathComponent("reset-schedules.json")
        let traceURL = root.appendingPathComponent("trace.jsonl")
        let modeURL = root.appendingPathComponent("mode")
        let credit = BankedResetCredit(id: "fixture-credit", status: "available", resetType: "codexRateLimits",
            expiresAt: Date().addingTimeInterval(48 * 3600))
        let scheduler = BankedResetScheduler(store: store)
        try Self.require(scheduler.schedules.isEmpty, "No automatic schedules by default")
        try Data("uncertain".utf8).write(to: modeURL)
        try await scheduler.useNow(profileID: "1", credit: credit)
        let uncertain = scheduler.schedule(for: "1", creditID: credit.id)!
        try Self.require(uncertain.enabled && uncertain.lastAttemptAt != nil && uncertain.lastError != nil,
            "Uncertain response remains journaled for retry")
        let restarted = BankedResetScheduler(store: store)
        try await restarted.useNow(profileID: "1", credit: credit)
        let completed = restarted.schedule(for: "1", creditID: credit.id)!
        try Self.require(!completed.enabled && completed.completedAt != nil && completed.lastOutcome == "alreadyRedeemed",
            "Relaunch resolves accepted request without another credit")
        try Self.require(completed.idempotencyKey == uncertain.idempotencyKey, "Retry preserves durable request")
        let trace = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let consumes = trace.filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }
        try Self.require(consumes.count == 2, "One first attempt and one exact retry")
        for request in consumes {
            let params = request["params"] as! [String: Any]
            try Self.require(params["creditId"] as? String == credit.id, "Never substitute next credit")
            try Self.require(params["idempotencyKey"] as? String == uncertain.idempotencyKey, "Same request after restart")
        }
        try FileManager.default.removeItem(at: scheduleURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("accepted"))
        try vault.saveAuthBlob(auth, profileID: "1")
        try Data("rotate-uncertain".utf8).write(to: modeURL)
        let rotating = BankedResetScheduler(store: store)
        try await rotating.useNow(profileID: "1", credit: credit)
        let rotated = try vault.loadAuthBlob(profileID: "1")!
        try Self.require(AuthBlob.identityFingerprint(from: rotated) != AuthBlob.identityFingerprint(from: auth),
            "Fixture rotation added identity claims")
        try Self.require(rotating.schedule(for: "1", creditID: credit.id)?.accountFingerprint == AuthBlob.identityFingerprint(from: rotated),
            "Journal follows validated same-account rotation")
        let afterRotation = BankedResetScheduler(store: store)
        try await afterRotation.useNow(profileID: "1", credit: credit)
        try Self.require(afterRotation.schedule(for: "1", creditID: credit.id)?.completedAt != nil,
            "Additional identity claims do not block exact retry after relaunch")
        try FileManager.default.removeItem(at: scheduleURL)
        try Data("noop".utf8).write(to: modeURL)
        let manual = BankedResetScheduler(store: store)
        try await manual.useNow(profileID: "1", credit: credit)
        try Self.require(manual.schedule(for: "1", creditID: credit.id)?.enabled == false,
            "Manual nothing-to-reset does not enable future automatic consumption")
        try FileManager.default.removeItem(at: scheduleURL)
        let scheduled = BankedResetScheduler(store: store)
        try await scheduled.saveSchedule(profileID: "1", credit: credit, mode: .beforeExpiry,
            date: Date().addingTimeInterval(3600), hours: 24)
        try Self.require(scheduled.schedule(for: "1", creditID: credit.id)?.triggerDate(expiresAt: nil) != nil,
            "Persist expiry so cache loss does not lose trigger")
        try vault.saveAuthBlob(auth, profileID: "2")
        do {
            try await scheduled.saveSchedule(profileID: "2", credit: credit, mode: .atDate,
                date: Date().addingTimeInterval(3600), hours: 24)
            throw Failure(message: "Duplicate account/credit schedule accepted")
        } catch BankedResetScheduler.ResetError.duplicate {}
        let expired = BankedResetCredit(id: "expired", status: "available", resetType: "codexRateLimits",
            expiresAt: Date().addingTimeInterval(-1))
        do {
            try await scheduled.useNow(profileID: "1", credit: expired)
            throw Failure(message: "Expired manual reset accepted")
        } catch BankedResetScheduler.ResetError.unavailable {}
        let wrong = Data(#"{"tokens":{"access_token":"other-access","refresh_token":"other-refresh","account_id":"another-account"}}"#.utf8)
        try vault.saveAuthBlob(wrong, profileID: "1")
        do {
            try await scheduled.useNow(profileID: "1", credit: credit)
            throw Failure(message: "Changed account accepted")
        } catch BankedResetScheduler.ResetError.accountChanged {}
        let corrupt = Data("broken schedule journal".utf8)
        try corrupt.write(to: scheduleURL)
        let broken = BankedResetScheduler(store: store)
        do {
            try await broken.useNow(profileID: "1", credit: credit)
            throw Failure(message: "Corrupt schedule storage overwritten")
        } catch BankedResetScheduler.ResetError.storageUnreadable {}
        try Self.require(try Data(contentsOf: scheduleURL) == corrupt, "Preserve unreadable journal")
        print("PASS: app display modes, login-item validation, durable reset retry, manual no-op, expiry/account guards, duplicate prevention, and corrupt-storage preservation")
    }

    private static let fake = #"""
    #!/usr/bin/python3
    import json, os, pathlib, sys, time
    root = pathlib.Path(os.environ['RESET_APP_FIXTURE_ROOT'])
    mode = (root/'mode').read_text()
    marker = root/'accepted'
    def reply(r, result): print(json.dumps({'id':r['id'],'result':result}), flush=True)
    for line in sys.stdin:
        r=json.loads(line)
        with (root/'trace.jsonl').open('a') as f: f.write(json.dumps(r)+'\n')
        if 'id' not in r: continue
        if r['method']=='initialize': reply(r,{})
        elif r['method']=='account/rateLimits/read':
            missing = mode in ('uncertain','rotate-uncertain') and marker.exists()
            if mode=='rotate-uncertain':
                authpath=pathlib.Path(os.environ['CODEX_HOME'])/'auth.json'
                auth=json.loads(authpath.read_text())
                auth['tokens']['id_token']='e30.eyJzdWIiOiJmaXh0dXJlLXVzZXIifQ.fixture'
                authpath.write_text(json.dumps(auth))
            credit={'id':'fixture-credit','status':'available','resetType':'codexRateLimits','expiresAt':int(time.time()+172800)}
            reply(r,{'accountId':'fixture-account','rateLimits':{'primary':{'usedPercent':25,'windowDurationMins':300},'secondary':{'usedPercent':80,'windowDurationMins':10080}},'rateLimitResetCredits':{'availableCount':0 if missing else 1,'credits':[] if missing else [credit]}})
        elif r['method']=='account/rateLimitResetCredit/consume':
            journal=json.loads((root/'.codex-multi-switcher'/'reset-schedules.json').read_text())
            entry=journal['1:fixture-credit']
            assert entry['lastAttemptAt'] and entry['idempotencyKey']==r['params']['idempotencyKey']
            assert r['params']['creditId']=='fixture-credit'
            if mode in ('uncertain','rotate-uncertain') and not marker.exists():
                marker.write_text('accepted')
                sys.exit(0)
            reply(r,{'outcome':'nothingToReset' if mode=='noop' else 'alreadyRedeemed'})
        else: raise RuntimeError('Unexpected fake request')
    """#
}
