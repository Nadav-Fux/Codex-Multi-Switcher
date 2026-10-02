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

public struct ClaudeUsageWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?
    public var remainingPercentage: Double { max(0, 100 - self.usedPercentage) }

    public init(usedPercentage: Double, resetsAt: Date? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

public enum ClaudeUsageSource: String, Equatable, Sendable {
    case nativeBridge
    case legacyStatusline
    case oauthUsage
}

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let modelWeekly: ClaudeUsageWindow?
    public let observedAt: Date
    public let source: ClaudeUsageSource
    public let isStale: Bool
    /// OAuth observations match a token-linked profile and CLI identity before/after the request.
    /// Bridge observations match installation identity; older sessions cannot attest credentials.
    public let accountVerified: Bool
    public var accountMatched: Bool { self.accountVerified }

    public init(fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?,
                modelWeekly: ClaudeUsageWindow? = nil, observedAt: Date,
                source: ClaudeUsageSource, isStale: Bool, accountVerified: Bool = false) {
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
