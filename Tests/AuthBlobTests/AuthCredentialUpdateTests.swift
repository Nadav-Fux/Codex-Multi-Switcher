import CodexProfileCore
import Foundation
import Testing

private final class CredentialUpdateTestVault: AuthVault, @unchecked Sendable {
    let authLockURL: URL
    var blobs: [String: Data]

    init(root: URL, blobs: [String: Data]) {
        self.authLockURL = root.appendingPathComponent("auth.lock")
        self.blobs = blobs
    }

    func listProfileIDs() throws -> [String] { Array(self.blobs.keys) }
    func loadAuthBlob(profileID: String) throws -> Data? { self.blobs[profileID] }
    func hasAuthBlob(profileID: String) throws -> Bool { self.blobs[profileID] != nil }
    func _saveAuthBlobUnlocked(_ data: Data, profileID: String) throws { self.blobs[profileID] = data }
    func _deleteAuthBlobUnlocked(profileID: String) throws { self.blobs.removeValue(forKey: profileID) }
}

struct AuthCredentialUpdateTests {
    private func auth(account: String = "account-a", token: String, timestamp: String) -> Data {
        Data("""
        {"tokens":{"access_token":"access-\(token)","refresh_token":"refresh-\(token)","account_id":"\(account)"},"last_refresh":"\(timestamp)"}
        """.utf8)
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test
    func savesRotationToEveryUnchangedCapturedProfile() throws {
        try self.withScratch { root in
            let original = self.auth(token: "old", timestamp: "2026-01-01T00:00:00Z")
            let rotated = self.auth(token: "new", timestamp: "2026-01-02T00:00:00Z")
            let vault = CredentialUpdateTestVault(root: root, blobs: ["1": original, "2": original])
            let outcome = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: rotated, profileIDs: ["2", "1", "1"], vault: vault)
            #expect(outcome.savedProfileIDs == ["1", "2"])
            #expect(!outcome.liveAuthUpdated)
            #expect(vault.blobs["1"] == rotated)
            #expect(vault.blobs["2"] == rotated)
        }
    }

    @Test
    func preservesConcurrentLoginRenewalAndDeletion() throws {
        try self.withScratch { root in
            let original = self.auth(token: "old", timestamp: "2026-01-01T00:00:00Z")
            let rotated = self.auth(token: "new", timestamp: "2026-01-02T00:00:00Z")
            let concurrent = self.auth(token: "concurrent", timestamp: "2026-01-03T00:00:00Z")
            let newAccount = self.auth(account: "account-b", token: "login", timestamp: "2026-01-03T00:00:00Z")
            let vault = CredentialUpdateTestVault(root: root, blobs: ["1": concurrent, "2": newAccount])
            let outcome = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: rotated, profileIDs: ["1", "2", "3"], vault: vault)
            #expect(outcome.savedProfileIDs.isEmpty)
            #expect(vault.blobs["1"] == concurrent)
            #expect(vault.blobs["2"] == newAccount)
            #expect(vault.blobs["3"] == nil)
        }
    }

    @Test
    func rejectsDifferentAccountReplacement() throws {
        try self.withScratch { root in
            let original = self.auth(token: "old", timestamp: "2026-01-01T00:00:00Z")
            let wrong = self.auth(account: "account-b", token: "new", timestamp: "2026-01-02T00:00:00Z")
            let vault = CredentialUpdateTestVault(root: root, blobs: ["1": original])
            #expect(throws: AuthCredentialUpdate.UpdateError.self) {
                try AuthCredentialUpdate.persistIfUnchanged(
                    originalData: original, updatedData: wrong, profileIDs: ["1"], vault: vault)
            }
            #expect(vault.blobs["1"] == original)
        }
    }

    @Test
    func refusesTimestampRegressionEvenWhenCapturedCredentialMatches() throws {
        try self.withScratch { root in
            let original = self.auth(token: "old", timestamp: "2026-01-02T00:00:00Z")
            let outdated = self.auth(token: "new", timestamp: "2026-01-01T00:00:00Z")
            let vault = CredentialUpdateTestVault(root: root, blobs: ["1": original])
            let outcome = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: outdated, profileIDs: ["1"], vault: vault)
            #expect(outcome.savedProfileIDs.isEmpty)
            #expect(vault.blobs["1"] == original)
        }
    }

    @Test
    func onlyUpdatesLiveFallbackWhenCapturedCredentialStillMatches() throws {
        try self.withScratch { root in
            let original = self.auth(token: "old", timestamp: "2026-01-01T00:00:00Z")
            let rotated = self.auth(token: "new", timestamp: "2026-01-02T00:00:00Z")
            let concurrent = self.auth(token: "concurrent", timestamp: "2026-01-03T00:00:00Z")
            let liveAuth = root.appendingPathComponent("fake-live-auth.json")
            let vault = CredentialUpdateTestVault(root: root, blobs: [:])
            try original.write(to: liveAuth)
            let applied = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: rotated, profileIDs: [], vault: vault, liveAuthURL: liveAuth)
            #expect(applied.liveAuthUpdated)
            #expect(try Data(contentsOf: liveAuth) == rotated)
            try concurrent.write(to: liveAuth)
            let skipped = try AuthCredentialUpdate.persistIfUnchanged(
                originalData: original, updatedData: rotated, profileIDs: [], vault: vault, liveAuthURL: liveAuth)
            #expect(!skipped.liveAuthUpdated)
            #expect(try Data(contentsOf: liveAuth) == concurrent)
        }
    }
}
