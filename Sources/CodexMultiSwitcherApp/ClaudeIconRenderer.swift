import Cocoa
import CodexProfileCore

/// A separate badge keeps Claude account selection independent of Codex.
enum ClaudeIconRenderer {
    static func render(snapshot: ClaudeUsageSnapshot?, primaryShowsUsed: Bool,
                       secondaryShowsUsed: Bool) -> NSImage {
        let usable = snapshot.map { !$0.isStale && $0.accountVerified } ?? false
        let now = Date()
        let windows = [usable ? snapshot?.fiveHour : nil, usable ? snapshot?.sevenDay : nil].map { window -> ClaudeUsageWindow? in
            guard let window, window.usedPercentage.isFinite,
                  window.resetsAt.map({ $0 > now }) ?? true else { return nil }
            return window
        }
        let modes = [primaryShowsUsed, secondaryShowsUsed]
        let rows = windows.enumerated().map { index, window -> NSAttributedString in
            let value = window.map { modes[index] ? $0.usedPercentage : $0.remainingPercentage }
            let display = value.map { String(format: "%02d", Int(min(100, max(0, $0)).rounded())) } ?? "—"
            let color = window.map { IconRenderer.color(for: Int($0.remainingPercentage.rounded())) } ?? .secondaryLabelColor
            return NSAttributedString(string: display, attributes: IconRenderer.quotaTextAttributes(
                font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), color: color))
        }
        let prefix = NSAttributedString(string: "CL", attributes: IconRenderer.quotaTextAttributes(
            font: NSFont.systemFont(ofSize: 8, weight: .semibold), color: .labelColor))
        let labels = ["5h", "w"].map { NSAttributedString(string: $0, attributes: IconRenderer.quotaTextAttributes(
            font: NSFont.systemFont(ofSize: 8, weight: .medium), color: .labelColor)) }
        let numberWidth = max(rows[0].size().width, rows[1].size().width)
        let numberRight = 2 + prefix.size().width + 4 + numberWidth
        let labelWidth = max(labels[0].size().width, labels[1].size().width)
        let size = NSSize(width: ceil(numberRight + 3 + labelWidth + 2), height: 23)
        let image = NSImage(size: size, flipped: true) { _ in
            prefix.draw(at: NSPoint(x: 2, y: (23 - prefix.size().height) / 2))
            for index in 0..<2 {
                let y = CGFloat(index) * 11.5
                rows[index].draw(at: NSPoint(x: numberRight - rows[index].size().width,
                                             y: y + (11.5 - rows[index].size().height) / 2))
                labels[index].draw(at: NSPoint(x: numberRight + 3,
                                               y: y + (11.5 - labels[index].size().height) / 2))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Claude Code quota: " + windows.enumerated().map { index, window in
            let period = index == 0 ? "5 hours" : "week"
            guard let window else { return "\(period) unavailable" }
            let amount = modes[index] ? window.usedPercentage : window.remainingPercentage
            return "\(period) \(Int(amount.rounded())) percent \(modes[index] ? "used" : "remaining")"
        }.joined(separator: ", ")
        return image
    }
}
