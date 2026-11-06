import CodexProfileCore
import Foundation
import Testing

private final class HealerTestVault: AuthVault, @unchecked Sendable {
    let authLockURL: URL
    var blobs: [String: Data]

    init(root: URL, blobs: [String: Data]) {
        self.authLockURL = root.appendingPathComponent("auth.lock")
        self.blobs = blobs
    }

    func listProfileIDs() throws -> [String] { Array(self.blobs.keys).sorted() }
    func loadAuthBlob(profileID: String) throws -> Data? { self.blobs[profileID] }
    func hasAuthBlob(profileID: String) throws -> Bool { self.blobs[profileID] != nil }
    func _saveAuthBlobUnlocked(_ data: Data, profileID: String) throws { self.blobs[profileID] = data }
    func _deleteAuthBlobUnlocked(profileID: String) throws { self.blobs.removeValue(forKey: profileID) }
}

struct StaleAuthHealerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func jwt(_ claims: [String: Any]) -> String {
        "\(self.base64URL(["alg": "none"])).\(self.base64URL(claims)).sig"
    }

    /// `expiresIn` is relative to `now`; `refreshedAgo` sets `last_refresh`.
    private func auth(
        account: String = "account-a",
        user: String = "user-1",
        chain: String,
        expiresIn: TimeInterval,
        refreshedAgo: TimeInterval?
    ) -> Data {
        var json: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": self.jwt(["exp": self.now.addingTimeInterval(expiresIn).timeIntervalSince1970]),
                "refresh_token": "refresh-\(chain)",
                "id_token": self.jwt(["sub": user]),
                "account_id": account,
            ],
        ]
        if let refreshedAgo {
            let formatter = ISO8601DateFormatter()
            json["last_refresh"] = formatter.string(from: self.now.addingTimeInterval(-refreshedAgo))
        }
        return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-auth-healer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private let day: TimeInterval = 86_400

    // MARK: - Newer wins

    @Test
    func newerValidCopyWins() {
        let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
        let fresh = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: self.day)
        let picked = StaleAuthHealer.bestReplacement(
            for: stale, candidates: [.init(source: .liveAuth, data: fresh)], now: self.now)
        #expect(picked?.source == .liveAuth)
        #expect(picked?.data == fresh)
    }

    @Test
    func newestOfSeveralValidCopiesWins() {
        let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
        let newer = self.auth(chain: "b", expiresIn: self.day, refreshedAgo: 3 * self.day)
        let newest = self.auth(chain: "c", expiresIn: self.day, refreshedAgo: 1 * self.day)
        let picked = StaleAuthHealer.bestReplacement(for: stale, candidates: [
            .init(source: .profile("2"), data: newer),
            .init(source: .liveAuth, data: newest),
        ], now: self.now)
        #expect(picked?.source == .liveAuth)
    }

    @Test
    func olderOrEqualCopyNeverReplacesCurrent() {
        let current = self.auth(chain: "cur", expiresIn: -self.day, refreshedAgo: 2 * self.day)
        let older = self.auth(chain: "older", expiresIn: self.day, refreshedAgo: 5 * self.day)
        let same = self.auth(chain: "same", expiresIn: self.day, refreshedAgo: 2 * self.day)
        #expect(StaleAuthHealer.bestReplacement(for: current, candidates: [
            .init(source: .liveAuth, data: older),
            .init(source: .profile("2"), data: same),
        ], now: self.now) == nil)
    }

    @Test
    func newerCopyWithExpiredAccessTokenIsRejected() {
        let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
        let newerButExpired = self.auth(chain: "new", expiresIn: -60, refreshedAgo: self.day)
        let nearlyExpired = self.auth(chain: "near", expiresIn: 10, refreshedAgo: self.day)
        #expect(StaleAuthHealer.bestReplacement(for: stale, candidates: [
            .init(source: .liveAuth, data: newerButExpired),
            .init(source: .profile("2"), data: nearlyExpired),
        ], now: self.now) == nil)
    }

    @Test
    func identicalChainHasNothingToGive() {
        let current = self.auth(chain: "same", expiresIn: -self.day, refreshedAgo: 3 * self.day)
        let sameChainNewerStamp = self.auth(chain: "same", expiresIn: self.day, refreshedAgo: self.day)
        #expect(StaleAuthHealer.bestReplacement(
            for: current, candidates: [.init(source: .liveAuth, data: sameChainNewerStamp)], now: self.now) == nil)
    }

    // MARK: - Same account only

    @Test
    func differentAccountIsNeverAdopted() {
        let stale = self.auth(account: "account-a", chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
        let otherAccount = self.auth(account: "account-b", chain: "new", expiresIn: self.day, refreshedAgo: self.day)
        #expect(StaleAuthHealer.bestReplacement(
            for: stale, candidates: [.init(source: .liveAuth, data: otherAccount)], now: self.now) == nil)
    }

    @Test
    func sameWorkspaceDifferentUserIsNeverAdopted() {
        // Team plans share `account_id` across members; the id-token user must match too.
        let stale = self.auth(user: "user-1", chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
        let teammate = self.auth(user: "user-2", chain: "new", expiresIn: self.day, refreshedAgo: self.day)
        #expect(StaleAuthHealer.bestReplacement(
            for: stale, candidates: [.init(source: .liveAuth, data: teammate)], now: self.now) == nil)
    }

    @Test
    func profileWithoutAccountIDIsNeverHealed() {
        let noAccount = Data("""
        {"tokens":{"access_token":"a","refresh_token":"r"},"last_refresh":"2020-01-01T00:00:00Z"}
        """.utf8)
        let fresh = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: self.day)
        #expect(StaleAuthHealer.bestReplacement(
            for: noAccount, candidates: [.init(source: .liveAuth, data: fresh)], now: self.now) == nil)
    }

    // MARK: - Heal I/O

    @Test
    func healAdoptsLiveCopyAtomicallyAndBacksUpTheStaleOne() throws {
        try self.withScratch { root in
            let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
            let fresh = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: self.day)
            let foreign = self.auth(account: "account-b", chain: "x", expiresIn: self.day, refreshedAgo: 0)
            let liveURL = root.appendingPathComponent("auth.json")
            try fresh.write(to: liveURL)
            let vault = HealerTestVault(root: root, blobs: ["1": stale, "2": foreign])
            let backups = root.appendingPathComponent("backups")

            let outcome = try StaleAuthHealer.heal(
                profileID: "1", captured: stale, vault: vault, liveAuthURL: liveURL,
                backupDirectory: backups, now: self.now)

            #expect(outcome?.source == .liveAuth)
            #expect(vault.blobs["1"] == fresh)
            #expect(vault.blobs["2"] == foreign)
            let backupURL = try #require(outcome?.backupURL)
            #expect(try Data(contentsOf: backupURL) == stale)
            let mode = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test
    func healAdoptsSiblingProfileCopy() throws {
        try self.withScratch { root in
            let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
            let sibling = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: self.day)
            let vault = HealerTestVault(root: root, blobs: ["1": stale, "2": sibling])
            let outcome = try StaleAuthHealer.heal(
                profileID: "1", captured: stale, vault: vault,
                liveAuthURL: root.appendingPathComponent("missing-auth.json"),
                backupDirectory: root.appendingPathComponent("backups"), now: self.now)
            #expect(outcome?.source == .profile("2"))
            #expect(vault.blobs["1"] == sibling)
        }
    }

    @Test
    func healLeavesProfileAloneWhenItChangedConcurrently() throws {
        try self.withScratch { root in
            let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
            let concurrentLogin = self.auth(chain: "login", expiresIn: self.day, refreshedAgo: 0)
            let fresh = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: self.day)
            let liveURL = root.appendingPathComponent("auth.json")
            try fresh.write(to: liveURL)
            let vault = HealerTestVault(root: root, blobs: ["1": concurrentLogin])
            let outcome = try StaleAuthHealer.heal(
                profileID: "1", captured: stale, vault: vault, liveAuthURL: liveURL,
                backupDirectory: root.appendingPathComponent("backups"), now: self.now)
            #expect(outcome == nil)
            #expect(vault.blobs["1"] == concurrentLogin)
        }
    }

    @Test
    func healReturnsNilWhenNoValidCopyExists() throws {
        try self.withScratch { root in
            let stale = self.auth(chain: "old", expiresIn: -self.day, refreshedAgo: 11 * self.day)
            let liveURL = root.appendingPathComponent("auth.json")
            try self.auth(account: "account-b", chain: "x", expiresIn: self.day, refreshedAgo: 0).write(to: liveURL)
            let vault = HealerTestVault(root: root, blobs: ["1": stale])
            #expect(try StaleAuthHealer.heal(
                profileID: "1", captured: stale, vault: vault, liveAuthURL: liveURL,
                backupDirectory: root.appendingPathComponent("backups"), now: self.now) == nil)
            #expect(vault.blobs["1"] == stale)
        }
    }

    // MARK: - Error classification

    @Test
    func classifiesBackendStaleAuthErrors() {
        let observed = #"GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; body={"error":{"code":"token_expired"}}"#
        #expect(StaleAuthHealer.isStaleAuthError(CodexRPCError.requestFailed(observed)))
        #expect(StaleAuthHealer.isStaleAuthError(CodexRPCError.requestFailed("refresh_token_reused")))
        #expect(!StaleAuthHealer.isStaleAuthError(CodexRPCError.requestFailed("HTTP 503 upstream unavailable")))
        #expect(!StaleAuthHealer.isStaleAuthError(CodexRPCError.timeout(method: "account/rateLimits/read")))
        #expect(!StaleAuthHealer.reloginMessage.contains("{"))
    }

    // MARK: - Reverse direction: write rotated tokens back to live auth.json

    @Test
    func rotationIsWrittenBackToLiveAuthHoldingTheConsumedChain() throws {
        try self.withScratch { root in
            let original = self.auth(chain: "old", expiresIn: 60 * 60, refreshedAgo: 2 * self.day)
            let rotated = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: 0)
            let liveURL = root.appendingPathComponent("auth.json")
            try original.write(to: liveURL)
            let vault = HealerTestVault(root: root, blobs: ["1": original])
            let backups = root.appendingPathComponent("backups")
            let outcome = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: rotated, profileIDs: ["1"], vault: vault,
                liveAuthURL: liveURL, backupDirectory: backups)
            #expect(outcome.liveAuthUpdated)
            #expect(try Data(contentsOf: liveURL) == rotated)
            let backupFiles = try FileManager.default.contentsOfDirectory(
                atPath: backups.appendingPathComponent("auth-heal").path)
            #expect(backupFiles.contains { $0.hasPrefix("codex-auth-json-") })
        }
    }

    @Test
    func liveAuthOnAnotherChainOrAccountIsNotOverwritten() throws {
        try self.withScratch { root in
            let original = self.auth(chain: "old", expiresIn: 60 * 60, refreshedAgo: 2 * self.day)
            let rotated = self.auth(chain: "new", expiresIn: self.day, refreshedAgo: 0)
            let liveOtherChain = self.auth(chain: "codex-own", expiresIn: self.day, refreshedAgo: self.day)
            let liveOtherAccount = self.auth(account: "account-b", chain: "old", expiresIn: self.day, refreshedAgo: 3 * self.day)
            let liveURL = root.appendingPathComponent("auth.json")
            for live in [liveOtherChain, liveOtherAccount] {
                try live.write(to: liveURL)
                let vault = HealerTestVault(root: root, blobs: ["1": original])
                let outcome = try AuthCredentialUpdate.persistIfUnchanged(
                    originalData: original, updatedData: rotated, profileIDs: ["1"], vault: vault,
                    liveAuthURL: liveURL)
                #expect(!outcome.liveAuthUpdated)
                #expect(try Data(contentsOf: liveURL) == live)
            }
        }
    }
}
