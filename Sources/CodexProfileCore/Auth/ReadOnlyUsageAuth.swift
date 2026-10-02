import Foundation

/// A short-lived query copy of the current Desktop credential. The real refresh
/// token never reaches the helper, so querying usage cannot rotate that session.
public enum ReadOnlyUsageAuth {
    public static let disabledRefreshToken = "codex-multi-switcher-read-only"

    public static func prepare(from original: Data, now: Date = Date()) -> Data? {
        guard let credentials = try? AuthBlob.load(from: original), !credentials.refreshToken.isEmpty,
              self.accessTokenExpiration(credentials.accessToken).map({ $0 > now }) == true else { return nil }
        var tokens: [String: String] = ["access_token": credentials.accessToken,
                                        "refresh_token": self.disabledRefreshToken]
        if let idToken = credentials.idToken { tokens["id_token"] = idToken }
        if let accountID = credentials.accountId { tokens["account_id"] = accountID }
        // A recent last_refresh also prevents an age-based eager refresh. If a
        // child still requests renewal, it has only the invalid sentinel token.
        // Build an allowlisted object: unknown live fields may contain credential
        // copies and do not belong in a disposable usage-query authentication file.
        let query: [String: Any] = ["auth_mode": "chatgpt", "tokens": tokens,
                                    "last_refresh": ISO8601DateFormatter().string(from: now)]
        return try? JSONSerialization.data(withJSONObject: query, options: [.sortedKeys])
    }

    public static func accessTokenExpiration(_ token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let expiration = json["exp"] as? NSNumber,
              CFGetTypeID(expiration) != CFBooleanGetTypeID(),
              expiration.doubleValue.isFinite, expiration.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: expiration.doubleValue)
    }
}
