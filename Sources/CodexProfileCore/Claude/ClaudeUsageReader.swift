import CryptoKit
import Foundation

public struct ClaudeUsageReadResult: Sendable {
    public var snapshot: ClaudeUsageSnapshot?
    public var warning: String?
}

public enum ClaudeUsageReader {
    public static let nativeSnapshotName = "codex-multi-switcher-usage.json"
    public static let staleAfter: TimeInterval = 300

    public static func accountFingerprint(_ auth: ClaudeAuthInfo?) -> String? {
        guard let auth, auth.loggedIn == true,
              auth.email != nil || auth.accountID != nil else { return nil }
        let identity = ["email": auth.email?.lowercased() ?? "",
                        "accountID": auth.accountID ?? "", "organizationID": auth.organizationID ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func read(profile: ClaudeProfile, auth: ClaudeAuthInfo? = nil,
                            now: Date = Date(), fileManager: FileManager = .default) -> ClaudeUsageReadResult {
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true)
        let native = directory.appendingPathComponent(Self.nativeSnapshotName)
        if fileManager.fileExists(atPath: native.path) {
            guard let payload = self.json(at: native), payload["schemaVersion"] as? Int == 1,
                  payload["profileID"] as? String == profile.id,
                  payload["configDirectory"] as? String == directory.path,
                  let fetchedAt = self.date(payload["fetchedAt"]),
                  fetchedAt.timeIntervalSince(now) <= 60 else {
                return ClaudeUsageReadResult(warning: "The native Claude usage snapshot is invalid or belongs to another profile.")
            }
            let fingerprint = self.accountFingerprint(auth)
            let capturedFingerprint = payload["authIdentityDigest"] as? String
            if let fingerprint, let capturedFingerprint, fingerprint != capturedFingerprint {
                return ClaudeUsageReadResult(warning: "Claude account changed. Install the usage bridge for this account and send a response to update usage.")
            }
            if auth?.loggedIn == false {
                return ClaudeUsageReadResult(warning: "Sign in to Claude before showing usage for this profile.")
            }
            let five = self.window(payload["fiveHour"], native: true)
            let seven = self.window(payload["sevenDay"], native: true)
            guard five != nil || seven != nil else { return ClaudeUsageReadResult() }
            let verified = fingerprint != nil && fingerprint == capturedFingerprint
            return ClaudeUsageReadResult(snapshot: ClaudeUsageSnapshot(
                fiveHour: five, sevenDay: seven,
                modelWeekly: self.window(payload["modelWeekly"], native: true),
                observedAt: fetchedAt, source: .nativeBridge,
                isStale: now.timeIntervalSince(fetchedAt) > Self.staleAfter,
                accountVerified: verified))
        }
        // This pre-existing OAuth cache has no account identity. Read only the default,
        // and always report it as unverified historical data, even if recently modified.
        guard profile.isDefault else { return ClaudeUsageReadResult() }
        let legacy = directory.appendingPathComponent("statusline-usage-cache.json")
        guard let payload = self.json(at: legacy),
              let attrs = try? fileManager.attributesOfItem(atPath: legacy.path),
              let modified = attrs[.modificationDate] as? Date else { return ClaudeUsageReadResult() }
        let usage = payload["usage"] as? [String: Any] ?? payload
        let five = self.window(usage["five_hour"], native: false)
        let seven = self.window(usage["seven_day"], native: false)
        guard five != nil || seven != nil else { return ClaudeUsageReadResult() }
        return ClaudeUsageReadResult(snapshot: ClaudeUsageSnapshot(
            fiveHour: five, sevenDay: seven, observedAt: modified,
            source: .legacyStatusline, isStale: true, accountVerified: false))
    }

    private static func json(at url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func window(_ value: Any?, native: Bool) -> ClaudeUsageWindow? {
        guard let window = value as? [String: Any],
              let percentage = window[native ? "usedPercent" : "utilization"] as? NSNumber,
              CFGetTypeID(percentage) != CFBooleanGetTypeID(),
              percentage.doubleValue.isFinite, (0...100).contains(percentage.doubleValue) else { return nil }
        return ClaudeUsageWindow(usedPercentage: percentage.doubleValue,
                                 resetsAt: self.date(window[native ? "resetAt" : "resets_at"]))
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
