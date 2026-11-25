import Foundation

/// Saves credentials rotated by an isolated Codex subprocess without replacing
/// a newer login or a concurrent renewal. No network or subprocess work runs
/// while the vault transaction lock is held.
public enum AuthCredentialUpdate {
    public struct Outcome: Equatable {
        public let savedProfileIDs: [String]
        public let liveAuthUpdated: Bool
    }

    public enum UpdateError: LocalizedError {
        case invalidReplacement

        public var errorDescription: String? {
            "Codex returned credentials that do not belong to the captured account."
        }
    }

    /// `beforeLiveWrite` is a test seam: it runs inside the vault transaction
    /// after the live-file check and backup, once the replacement temp file is
    /// prepared and right before the live file is re-read and renamed into
    /// place, simulating Codex Desktop saving a login in between.
    @discardableResult
    public static func persistIfUnchanged(
        originalData: Data,
        updatedData: Data,
        profileIDs: [String],
        vault: AuthVault,
        liveAuthURL: URL? = nil,
        backupDirectory: URL? = nil,
        beforeLiveWrite: (() -> Void)? = nil
    ) throws -> Outcome {
        guard AuthBlob.isPlausibleAuthBlob(updatedData),
              AuthBlob.identityMatches(originalData, updatedData),
              let original = try? AuthBlob.load(from: originalData),
              let replacement = try? AuthBlob.load(from: updatedData) else {
            throw UpdateError.invalidReplacement
        }

        return try vault.transact {
            var savedProfileIDs: [String] = []
            for id in Set(profileIDs).sorted() {
                guard let currentData = try vault.loadAuthBlob(profileID: id),
                      Self.canReplace(currentData, captured: original, replacement: replacement) else {
                    continue
                }
                guard currentData != updatedData else { continue }
                try vault._saveAuthBlobUnlocked(updatedData, profileID: id)
                savedProfileIDs.append(id)
            }

            // Keep Codex's own copy on the same chain. When the rotated
            // credential came from the chain `~/.codex/auth.json` still holds,
            // that copy's refresh token was just invalidated by this rotation;
            // writing the successor back is the only way Codex keeps working
            // without a re-login. Re-read immediately before writing; external
            // Codex processes do not take our vault lock.
            var liveAuthUpdated = false
            if let liveAuthURL,
               let currentData = try? Data(contentsOf: liveAuthURL),
               currentData != updatedData,
               Self.canWriteBackToLive(currentData, captured: original, replacementData: updatedData) {
                if let backupDirectory {
                    try StaleAuthHealer.writeBackup(
                        currentData, label: "codex-auth-json", backupDirectory: backupDirectory)
                }
                // Codex Desktop does not take our vault lock: the temp file is
                // prepared first, then the live file is re-read and the rename
                // happens only when it still holds `currentData` — a login it
                // saved meanwhile always wins over this write-back.
                if try AtomicFileWriter.writeIfUnchanged(
                    updatedData, to: liveAuthURL, expected: currentData,
                    beforeCommit: beforeLiveWrite) {
                    liveAuthUpdated = true
                    CoreLogger.info("Wrote rotated credential back to Codex auth.json")
                } else {
                    CoreLogger.info("Skipped the Codex auth.json write-back: the file changed after the check")
                }
            }
            return Outcome(savedProfileIDs: savedProfileIDs, liveAuthUpdated: liveAuthUpdated)
        }
    }

    /// Live `auth.json` may be overwritten only when it is the same account
    /// and the same person (a shared user-level claim — `account_id` alone is
    /// a workspace id on Team plans), still holds the refresh token the
    /// rotation consumed (so it is now dead), and the replacement is not older
    /// than it.
    static func canWriteBackToLive(
        _ liveData: Data,
        captured: AuthCredentials,
        replacementData: Data
    ) -> Bool {
        guard let live = try? AuthBlob.load(from: liveData),
              let replacement = try? AuthBlob.load(from: replacementData),
              let accountID = live.accountId, !accountID.isEmpty,
              replacement.accountId == accountID,
              captured.accountId == accountID,
              AuthBlob.identityMatchesUser(liveData, replacementData),
              live.refreshToken == captured.refreshToken,
              replacement.refreshToken != live.refreshToken || replacement.accessToken != live.accessToken else {
            return false
        }
        switch (live.lastRefresh, replacement.lastRefresh) {
        case let (live?, replacement?): return replacement >= live
        case (.some, .none): return false
        default: return true
        }
    }

    private static func canReplace(
        _ currentData: Data,
        captured: AuthCredentials,
        replacement: AuthCredentials
    ) -> Bool {
        guard let current = try? AuthBlob.load(from: currentData),
              current.accessToken == captured.accessToken,
              current.refreshToken == captured.refreshToken,
              current.idToken == captured.idToken,
              current.accountId == captured.accountId,
              current.lastRefresh == captured.lastRefresh else {
            return false
        }
        switch (current.lastRefresh, replacement.lastRefresh) {
        case let (current?, replacement?): return replacement >= current
        case (.some, .none): return false
        default: return true
        }
    }
}
