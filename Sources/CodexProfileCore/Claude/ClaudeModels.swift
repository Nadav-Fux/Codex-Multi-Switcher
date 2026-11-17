import Foundation

public struct ClaudeProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var label: String
    public let configDirectory: String
    public let isDefault: Bool

    public init(id: String, label: String, configDirectory: String, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.configDirectory = configDirectory
        self.isDefault = isDefault
    }
}

public struct ClaudeAuthInfo: Equatable, Sendable {
    public let loggedIn: Bool?
    public let email: String?
    public let organization: String?
    public let subscription: String?
    public let authenticationMethod: String?
    public let accountID: String?
    public let organizationID: String?

    public init(loggedIn: Bool?, email: String? = nil, organization: String? = nil,
                subscription: String? = nil, authenticationMethod: String? = nil,
                accountID: String? = nil, organizationID: String? = nil) {
        self.loggedIn = loggedIn
        self.email = email
        self.organization = organization
        self.subscription = subscription
        self.authenticationMethod = authenticationMethod
        self.accountID = accountID
        self.organizationID = organizationID
    }
}

public struct ClaudeUsageWindow: Codable, Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?
    public var remainingPercentage: Double { max(0, 100 - self.usedPercentage) }

    public init(usedPercentage: Double, resetsAt: Date? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

public enum ClaudeUsageSource: String, Codable, Equatable, Sendable {
    case nativeBridge
    case legacyStatusline
    case oauthUsage
}

/// A limit reset Claude grants the account (Claude Code's `/limit-reset`).
/// Read-only here: the app shows what is available and never spends one.
public struct ClaudeLimitReset: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case session, weekly, fable, full
    }
    public let id: String
    public let label: String
    public let kind: Kind
    public let left: Int
    public let total: Int
    public let endsAt: Date?
    public let usableNow: Bool
    public let paused: Bool

    public init(id: String, label: String, kind: Kind, left: Int, total: Int,
                endsAt: Date?, usableNow: Bool, paused: Bool) {
        self.id = id; self.label = label; self.kind = kind; self.left = left
        self.total = total; self.endsAt = endsAt; self.usableNow = usableNow; self.paused = paused
    }

    /// Mirrors Claude Code: a grant that gives back weekly usage is the Fable
    /// reset; otherwise the server type, else what the grant clears.
    public static func kind(type: String?, clears: [String], givesBackWeekly: Bool) -> Kind {
        if givesBackWeekly { return .fable }
        if let type, let kind = Kind(rawValue: type) { return kind }
        let session = clears.contains("five_hour")
        let other = clears.contains { $0 != "five_hour" }
        return session && !other ? .session : other && !session ? .weekly : .full
    }

    /// Parses the `cedar_ember` block of the usage response. Malformed grants are skipped.
    public static func parse(_ block: Any?) -> [ClaudeLimitReset]? {
        guard let block = block as? [String: Any] else { return nil }
        guard block["eligible"] as? Bool == true else { return [] }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        func int(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue < 10_000 else { return nil }
            return number.intValue
        }
        return (block["grants"] as? [[String: Any]] ?? []).compactMap { grant in
            guard let id = grant["id"] as? String, !id.isEmpty, id.count <= 64,
                  let left = int(grant["resets_left"]) else { return nil }
            let clears = grant["clears"] as? [String] ?? []
            return ClaudeLimitReset(
                id: id, label: (grant["label"] as? String).map { String($0.prefix(80)) } ?? "",
                kind: kind(type: grant["type"] as? String, clears: clears,
                           givesBackWeekly: grant["gives_back_weekly"] as? Bool ?? false),
                left: left, total: int(grant["resets_total"]) ?? left,
                endsAt: date(grant["ends_at"]),
                usableNow: grant["usable_now"] as? Bool ?? false,
                paused: grant["paused"] as? Bool ?? false)
        }
    }

    /// Back to the response shape, for the normalized local cache.
    public var normalized: [String: Any] {
        var value: [String: Any] = ["id": id, "label": label, "resets_left": left, "resets_total": total,
                                    "usable_now": usableNow, "paused": paused]
        switch kind {
        case .fable: value["gives_back_weekly"] = true
        default: value["type"] = kind.rawValue
        }
        if let endsAt { value["ends_at"] = ISO8601DateFormatter().string(from: endsAt) }
        return value
    }
}

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let modelWeekly: ClaudeUsageWindow?
    public let observedAt: Date
    public let source: ClaudeUsageSource
    public let isStale: Bool
    /// OAuth observations match a token-linked profile and CLI identity before/after the request.
    /// Bridge observations match installation identity; older sessions cannot attest credentials.
    public let accountVerified: Bool
    /// Limit resets available to the account; nil when the source cannot tell.
    public let resets: [ClaudeLimitReset]?
    public var accountMatched: Bool { self.accountVerified }

    public init(fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?,
                modelWeekly: ClaudeUsageWindow? = nil, observedAt: Date,
                source: ClaudeUsageSource, isStale: Bool, accountVerified: Bool = false,
                resets: [ClaudeLimitReset]? = nil) {
        self.resets = resets
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.modelWeekly = modelWeekly
        self.observedAt = observedAt
        self.source = source
        self.isStale = isStale
        self.accountVerified = accountVerified
    }
}

public struct ClaudeProfileStatus: Equatable, Sendable {
    public var auth: ClaudeAuthInfo?
    public var usage: ClaudeUsageSnapshot?
    public var error: String?
    public var busy: Bool
    public var bridgeInstalled: Bool

    public init(auth: ClaudeAuthInfo? = nil, usage: ClaudeUsageSnapshot? = nil,
                error: String? = nil, busy: Bool = false, bridgeInstalled: Bool = false) {
        self.auth = auth
        self.usage = usage
        self.error = error
        self.busy = busy
        self.bridgeInstalled = bridgeInstalled
    }
}

public enum ClaudeIntegrationError: LocalizedError {
    case invalidRegistry
    case invalidProfile
    case invalidLabel
    case defaultProfileRemoval
    case cliMissing
    case timeout
    case invalidStatus
    case settingsUnsupported
    case bridgeMissing
    case pythonMissing
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRegistry: return "Claude profile metadata is invalid. The existing file was preserved."
        case .invalidProfile: return "Claude profile was not found or its directory is invalid."
        case .invalidLabel: return "Enter a Claude profile name of 1–80 characters."
        case .defaultProfileRemoval: return "The existing Claude profile cannot be removed."
        case .cliMissing: return "Claude Code CLI was not found. Install Claude Code, then refresh."
        case .timeout: return "Claude authentication status timed out."
        case .invalidStatus: return "Claude authentication status could not be read."
        case .settingsUnsupported: return "Claude settings cannot be safely updated. The existing settings were preserved."
        case .bridgeMissing: return "The native Claude usage bridge is missing from this app build."
        case .pythonMissing: return "Python 3 is required for the native Claude usage bridge."
        case .launchFailed: return "Terminal could not open the new Claude session."
        }
    }
}
