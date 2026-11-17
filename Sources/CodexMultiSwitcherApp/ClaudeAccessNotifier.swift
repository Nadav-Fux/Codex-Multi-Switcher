@preconcurrency import UserNotifications
import CodexProfileCore
import Foundation

/// Background Claude refreshes never open a Keychain dialog, so when silent
/// access is blocked the usage simply stops updating. This raises one clear
/// notification per blocked spell (and at most once a day across relaunches)
/// instead of letting the menu bar sit on "?" without explanation.
@MainActor
enum ClaudeAccessNotifier {
    private static let lastNotifiedKey = "claudeAccessBlockedNotifiedAt"
    private static var notifiedThisSpell = false

    static func update(blocked: Bool, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard blocked else {
            self.notifiedThisSpell = false
            defaults.removeObject(forKey: self.lastNotifiedKey)
            return
        }
        guard self.shouldNotify(defaults: defaults, now: now) else { return }
        self.notifiedThisSpell = true
        defaults.set(now, forKey: self.lastNotifiedKey)
        CoreLogger.warning("Claude usage paused: background access needs Connect in Settings")
        // UNUserNotificationCenter traps outside an app bundle (tests, CLI smoke).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Claude usage is paused"
            content.body = "macOS blocked the silent read. Open Codex Multi Switcher → Settings → Claude Code and click Connect Claude Account."
            center.add(UNNotificationRequest(identifier: "claude-access-blocked", content: content, trigger: nil))
        }
    }

    static func shouldNotify(defaults: UserDefaults, now: Date) -> Bool {
        guard !self.notifiedThisSpell else { return false }
        if let last = defaults.object(forKey: self.lastNotifiedKey) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 { return false }
        return true
    }
}
