import Foundation

/// Repairs a saved profile whose credential chain went stale because another
/// holder of the same login (usually Codex itself, via `~/.codex/auth.json`)
/// refreshed it. A refresh rotates the refresh token, so the copy that did not
/// take part in the refresh can no longer renew and its access token eventually
/// fails with `401 token_expired` / `refresh_token_reused`.
///
/// The healer only ever ADOPTS a copy that is strictly better: the same account
/// (`tokens.account_id` AND the id-token identity, because `account_id` alone is
/// a shared workspace id on Team plans), a newer `last_refresh`, and an access
/// token whose JWT `exp` is still in the future. It never invents credentials,
/// never touches the network, and never logs token values.
public enum StaleAuthHealer {
    public enum Source: Equatable, Sendable {
        case liveAuth
        case profile(String)

        public var diagnosticName: String {
            switch self {
            case .liveAuth: return "codex-auth-json"
            case .profile(let id): return "profile-\(id)"
            }
        }
    }

    public struct Candidate {
        public let source: Source
        public let data: Data

        public init(source: Source, data: Data) {
            self.source = source
            self.data = data
        }
    }

    public struct Outcome {
        /// The credential now stored for the profile.
        public let healedData: Data
        public let source: Source
        public let backupURL: URL?
    }

    /// Access tokens closer than this to expiry are not worth adopting: the
    /// retry would race the expiry.
    public static let minimumRemainingValidity: TimeInterval = 60

    // MARK: - Error classification

    /// Phrases Codex and the ChatGPT backend use when a credential chain is dead.
    /// Matching is case-insensitive on the redacted error description.
    private static let staleAuthTerms = [
        "401",
        "token_expired",
        "token expired",
        "refresh_token_reused",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "invalid_grant",
        "unauthorized",
        "authentication required",
        "login required",
    ]

    public static func isStaleAuthMessage(_ message: String) -> Bool {
        self.staleAuthTerms.contains { message.localizedCaseInsensitiveContains($0) }
    }

    public static func isStaleAuthError(_ error: Error) -> Bool {
        if let operation = error as? CLIUsageOperationError {
            return self.isStaleAuthError(operation.underlyingError)
        }
        if let rpc = error as? CodexRPCError {
            if rpc.isAuthRequired { return true }
            guard case .requestFailed(let message) = rpc else { return false }
            return self.isStaleAuthMessage(message)
        }
        if let renewal = error as? TokenRenewalError, case .rejected = renewal { return true }
        return false
    }

    /// The text shown instead of a raw backend JSON error when no valid copy of
    /// the login exists anywhere on this Mac.
    public static let reloginMessage =
        "Sign-in expired for this profile and no newer copy of the same login was found. Log in to this account again (Codex → Log out / Log in), then re-save the profile."

    // MARK: - Decision (pure)

    /// Returns the best candidate to adopt for `current`, or nil when none is
    /// strictly better. Rules:
    /// - same `tokens.account_id` (required, non-empty) and same identity claims;
    /// - newer `last_refresh` than `current` (a current copy without a stamp
    ///   loses to any stamped candidate);
    /// - access token JWT `exp` at least `minimumRemainingValidity` after `now`;
    /// - a different refresh token (identical chains have nothing to give).
    /// Among qualifying candidates the newest `last_refresh` wins.
    public static func bestReplacement(
        for current: Data,
        candidates: [Candidate],
        now: Date = Date()
    ) -> Candidate? {
        guard let currentCredentials = try? AuthBlob.load(from: current),
              let accountID = currentCredentials.accountId, !accountID.isEmpty else {
            return nil
        }
        var best: (candidate: Candidate, refreshedAt: Date)?
        for candidate in candidates {
            guard let credentials = try? AuthBlob.load(from: candidate.data),
                  credentials.accountId == accountID,
                  AuthBlob.identityMatches(current, candidate.data),
                  credentials.refreshToken != currentCredentials.refreshToken,
                  let refreshedAt = credentials.lastRefresh,
                  let expiry = ReadOnlyUsageAuth.accessTokenExpiration(credentials.accessToken),
                  expiry.timeIntervalSince(now) >= self.minimumRemainingValidity else {
                continue
            }
            if let currentRefresh = currentCredentials.lastRefresh, refreshedAt <= currentRefresh {
                continue
            }
            if best == nil || refreshedAt > best!.refreshedAt {
                best = (candidate, refreshedAt)
            }
        }
        return best?.candidate
    }

    /// True when the profile's own access token is expired (or unreadable), so
    /// a proactive heal before a sensitive action is warranted. A profile with a
    /// valid token of its own is left on its chain.
    public static func accessTokenNeedsHealing(_ data: Data, now: Date = Date()) -> Bool {
        guard let credentials = try? AuthBlob.load(from: data),
              let expiry = ReadOnlyUsageAuth.accessTokenExpiration(credentials.accessToken) else {
            return true
        }
        return expiry.timeIntervalSince(now) < self.minimumRemainingValidity
    }

    // MARK: - Heal (I/O)

    /// Adopts the best same-account copy into `profileID` if one is strictly
    /// newer and valid. `captured` is the credential the caller just saw fail;
    /// the write happens only if the vault still holds exactly that blob (a
    /// concurrent login, renewal or deletion always wins).
    ///
    /// The vault write is atomic for the file vault (temp file + rename, mode
    /// 0600). The replaced blob is first copied into `backupDirectory` (0700
    /// directory, 0600 file); only the newest few backups per profile are kept.
    public static func heal(
        profileID: String,
        captured: Data,
        vault: AuthVault,
        liveAuthURL: URL,
        backupDirectory: URL,
        now: Date = Date()
    ) throws -> Outcome? {
        try vault.transact {
            guard let stored = try vault.loadAuthBlob(profileID: profileID), stored == captured else {
                return nil
            }
            var candidates: [Candidate] = []
            if let live = try? Data(contentsOf: liveAuthURL) {
                candidates.append(Candidate(source: .liveAuth, data: live))
            }
            for otherID in (try? vault.listProfileIDs()) ?? [] where otherID != profileID {
                if let other = try? vault.loadAuthBlob(profileID: otherID) {
                    candidates.append(Candidate(source: .profile(otherID), data: other))
                }
            }
            guard let replacement = self.bestReplacement(for: stored, candidates: candidates, now: now) else {
                return nil
            }
            let backupURL = try self.writeBackup(
                stored, label: "profile-\(profileID)", backupDirectory: backupDirectory, now: now)
            try vault._saveAuthBlobUnlocked(replacement.data, profileID: profileID)
            CoreLogger.info("Healed stale profile credential", metadata: [
                "profile": profileID, "source": replacement.source.diagnosticName,
            ])
            return Outcome(healedData: replacement.data, source: replacement.source, backupURL: backupURL)
        }
    }

    // MARK: - Backups

    public static let backupsKeptPerLabel = 5

    @discardableResult
    public static func writeBackup(
        _ data: Data, label: String, backupDirectory: URL, now: Date = Date()
    ) throws -> URL {
        let directory = backupDirectory.appendingPathComponent("auth-heal", isDirectory: true)
        try AtomicFileWriter.ensurePrivateDirectory(directory)
        let stamp = Self.backupStampFormatter.string(from: now)
        let url = directory.appendingPathComponent("\(label)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try AtomicFileWriter.write(data, to: url)
        self.pruneBackups(in: directory, label: label)
        return url
    }

    private static func pruneBackups(in directory: URL, label: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let matching = entries.filter { $0.lastPathComponent.hasPrefix("\(label)-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in matching.dropFirst(self.backupsKeptPerLabel) {
            try? fm.removeItem(at: stale)
        }
    }

    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}
