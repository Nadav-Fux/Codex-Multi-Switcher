import CodexProfileCore
import CryptoKit
import Foundation

enum ClaudeUsageHelperChecks {
    static func run(root: URL) throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw ClaudeCurrentUsageChecks.Failure(message: message) }
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let directory = root.appendingPathComponent("helper-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture-helper")
        let manifest = directory.appendingPathComponent("manifest.json")
        let calls = directory.appendingPathComponent("calls")
        let readResponse = directory.appendingPathComponent("read.json")
        let authorizeResponse = directory.appendingPathComponent("authorize.json")
        let verifyResponse = directory.appendingPathComponent("verify.json")
        let script = """
        #!/bin/sh
        echo "$1" >> \(quote(calls.path))
        case "$1" in
          read) cat \(quote(readResponse.path));;
          authorize) cat \(quote(authorizeResponse.path));;
          verify) cat \(quote(verifyResponse.path));;
          *) exit 1;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let hash = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sha256": hash]).write(to: manifest)
        let suite = "claude-helper-fixture-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = ClaudeUsageHelperClient(executable: executable, manifest: manifest, preferences: preferences)
        let denied = ClaudeUsageHelperResponse(error: .credentialInteractionRequired)
        try JSONEncoder().encode(denied).write(to: readResponse)
        try JSONEncoder().encode(ClaudeUsageHelperResponse()).write(to: authorizeResponse)
        try JSONEncoder().encode(ClaudeUsageHelperResponse(identity: "fixture")).write(to: verifyResponse)
        do { _ = try client.read(identity: "fixture"); throw ClaudeCurrentUsageChecks.Failure(message: "Denied read must fail") }
        catch ClaudeCurrentUsageError.credentialInteractionRequired {}
        let snapshot = ClaudeUsageSnapshot(fiveHour: ClaudeUsageWindow(usedPercentage: 21), sevenDay: nil,
            observedAt: Date(), source: .oauthUsage, isStale: false, accountVerified: true)
        try JSONEncoder().encode(ClaudeUsageHelperResponse(identity: "fixture", snapshot: snapshot)).write(to: readResponse)
        let secondClient = ClaudeUsageHelperClient(executable: executable, manifest: manifest, preferences: preferences)
        do { _ = try secondClient.read(identity: "fixture"); throw ClaudeCurrentUsageChecks.Failure(message: "Permission latch must survive client recreation") }
        catch ClaudeCurrentUsageError.credentialInteractionRequired {}
        try check(try String(contentsOf: calls, encoding: .utf8) == "read\n", "Blocked refresh must not launch another child")
        try client.authorize()
        let actual = try client.read(identity: "fixture")
        try check(actual.fiveHour?.usedPercentage == 21, "Helper quota decoded")
        try check(try String(contentsOf: calls, encoding: .utf8) == "read\nauthorize\nverify\nread\n", "Connect requires separate authorization and silent verification processes")
        try check(client.cached(identity: "other", now: Date()) == nil, "Cache cannot cross accounts")
        try check(client.cached(identity: "fixture", now: Date())?.isStale == true, "Failure fallback is explicitly historical")
        try JSONEncoder().encode(denied).write(to: verifyResponse)
        do { try client.authorize(); throw ClaudeCurrentUsageChecks.Failure(message: "Allow-once cannot confirm Connect") }
        catch ClaudeCurrentUsageError.credentialInteractionRequired {}
        let countAfterFailure = try String(contentsOf: calls, encoding: .utf8)
        do { _ = try client.read(identity: "fixture"); throw ClaudeCurrentUsageChecks.Failure(message: "Failed silent verification stays blocked") }
        catch ClaudeCurrentUsageError.credentialInteractionRequired {}
        try check(try String(contentsOf: calls, encoding: .utf8) == countAfterFailure, "Failed Connect never starts background authorization")
        try Data((script + "\n# changed executable\n").utf8).write(to: executable)
        do { try client.authorize(); throw ClaudeCurrentUsageChecks.Failure(message: "Tampered helper must not execute") }
        catch ClaudeCurrentUsageError.credentialUnavailable {}
        try check(try String(contentsOf: calls, encoding: .utf8) == countAfterFailure, "Hash mismatch prevents process launch")
        print("PASS: Claude helper quiet access, durable verification, identity and executable binding")
    }
}
