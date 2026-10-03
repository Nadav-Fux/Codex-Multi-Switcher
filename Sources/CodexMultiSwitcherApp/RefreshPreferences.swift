import Combine
import Foundation

enum RefreshInterval: String, CaseIterable, Identifiable {
    case manual = "manual"
    case oneMinute = "1-minute"
    case twoMinutes = "2-minutes"
    case fiveMinutes = "5-minutes"
    case fifteenMinutes = "15-minutes"

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        }
    }

    var timerInterval: TimeInterval? {
        switch self {
        case .manual:
            return nil
        case .oneMinute:
            return 60
        case .twoMinutes:
            return 120
        case .fiveMinutes:
            return 300
        case .fifteenMinutes:
            return 900
        }
    }
}

@MainActor
final class RefreshPreferences: ObservableObject {
    static let activeAccountRefreshInterval: TimeInterval = 30

    @Published var interval: RefreshInterval {
        didSet {
            self.defaults.set(self.interval.rawValue, forKey: Self.intervalKey)
        }
    }

    @Published var refreshWhenMenuOpens: Bool {
        didSet {
            self.defaults.set(self.refreshWhenMenuOpens, forKey: Self.menuOpenKey)
        }
    }

    @Published var refreshActiveAccountAutomatically: Bool {
        didSet {
            self.defaults.set(self.refreshActiveAccountAutomatically, forKey: Self.activeAccountKey)
        }
    }

    private static let activeAccountKey = UsageFreshness.activeAccountKey
    private static let intervalKey = "refreshInterval"
    private static let menuOpenKey = "refreshWhenMenuOpens"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedInterval = RefreshInterval(
            rawValue: defaults.string(forKey: Self.intervalKey) ?? "") ?? .fiveMinutes
        self.interval = savedInterval
        self.refreshWhenMenuOpens = defaults.object(forKey: Self.menuOpenKey) == nil
            ? true : defaults.bool(forKey: Self.menuOpenKey)
        self.refreshActiveAccountAutomatically = UsageFreshness.activeAccountRefreshEnabled(defaults: defaults)
    }
}

/// Shared age policy for the menu icon, account cards, and Settings quota cards.
enum UsageFreshness {
    static let activeAccountKey = "refreshActiveAccountAutomatically"

    static func activeAccountRefreshEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: Self.activeAccountKey) != nil {
            return defaults.bool(forKey: Self.activeAccountKey)
        }
        let interval = RefreshInterval(rawValue: defaults.string(forKey: "refreshInterval") ?? "") ?? .fiveMinutes
        return interval != .manual
    }

    static func isCached(fetchedAt: Date, isActive: Bool, now: Date = Date(),
                         defaults: UserDefaults = .standard) -> Bool {
        let threshold: TimeInterval = isActive && Self.activeAccountRefreshEnabled(defaults: defaults) ? 90 : 300
        return now.timeIntervalSince(fetchedAt) > threshold
    }
}
