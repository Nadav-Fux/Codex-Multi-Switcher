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

    @discardableResult
    public static func persistIfUnchanged(
        originalData: Data,
        updatedData: Data,
        profileIDs: [String],
        vault: AuthVault,
        liveAuthURL: URL? = nil
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

            // Normally only saved profile sessions are queried. This fallback
            // is for a signed app reading an unsaved live credential. Re-read
            // immediately before writing; external Codex processes do not take
            // our vault lock, so never use this to synchronize arbitrary auth.
            var liveAuthUpdated = false
            if let liveAuthURL,
               let currentData = try? Data(contentsOf: liveAuthURL),
               currentData != updatedData,
               Self.canReplace(currentData, captured: original, replacement: replacement) {
                try AtomicFileWriter.write(updatedData, to: liveAuthURL)
                liveAuthUpdated = true
            }
            return Outcome(savedProfileIDs: savedProfileIDs, liveAuthUpdated: liveAuthUpdated)
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
