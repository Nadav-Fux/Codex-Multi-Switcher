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
        if windows.allSatisfy({ $0 == nil }) { return Self.renderUnavailable() }
        let modes = [primaryShowsUsed, secondaryShowsUsed]
        let rows = windows.enumerated().map { index, window -> NSAttributedString in
            let value = window.map { modes[index] ? $0.usedPercentage : $0.remainingPercentage }
            let display = value.map { String(format: "%02d%%", Int(min(100, max(0, $0)).rounded())) } ?? "—"
            let color = window.map { IconRenderer.color(for: Int($0.remainingPercentage.rounded())) } ?? IconRenderer.cachedQuotaColor
            return NSAttributedString(string: display, attributes: IconRenderer.quotaTextAttributes(
                font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), color: color))
        }
        let labels = ["5h", "w"].map { NSAttributedString(string: $0, attributes: IconRenderer.quotaTextAttributes(
            font: NSFont.systemFont(ofSize: 8, weight: .medium), color: Self.providerColor)) }
        let numberWidth = max(rows[0].size().width, rows[1].size().width)
        let numberRight = 20 + numberWidth
        let labelWidth = max(labels[0].size().width, labels[1].size().width)
        let size = NSSize(width: ceil(numberRight + 3 + labelWidth + 2), height: 23)
        let image = NSImage(size: size, flipped: true) { _ in
            Self.drawIdentifier()
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

    private static let providerColor = NSColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 1)

    // A warm asterisk is a compact Claude identifier, not official logo artwork.
    private static func drawIdentifier() {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor(srgbRed: 1, green: 0.67, blue: 0.45, alpha: 1).setStroke()
        let rays = NSBezierPath()
        for index in 0..<12 {
            let angle = CGFloat(index) * .pi / 6
            rays.move(to: NSPoint(x: 9 + cos(angle) * 2, y: 11.5 + sin(angle) * 2))
            rays.line(to: NSPoint(x: 9 + cos(angle) * 7, y: 11.5 + sin(angle) * 7))
        }
        rays.lineWidth = 1.7
        rays.lineCapStyle = .round
        rays.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func renderUnavailable() -> NSImage {
        let text = NSAttributedString(string: "?", attributes: IconRenderer.quotaTextAttributes(
            font: .systemFont(ofSize: 10, weight: .semibold), color: IconRenderer.cachedQuotaColor))
        let image = NSImage(size: NSSize(width: ceil(text.size().width + 22), height: 23), flipped: true) { _ in
            Self.drawIdentifier()
            text.draw(at: NSPoint(x: 20, y: (23 - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Claude Code usage unavailable: 5 hours unavailable, week unavailable"
        return image
    }
}
