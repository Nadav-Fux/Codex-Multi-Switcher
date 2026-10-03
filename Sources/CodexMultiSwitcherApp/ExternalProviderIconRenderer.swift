import Cocoa
import CodexProfileCore

/// Compact quota rows retain the provider's separate model/window semantics.
enum ExternalProviderIconRenderer {
    static let antigravityLogo: NSImage? = {
        let name = "antigravity-menu.png"
        for url in [Bundle.main.resourceURL?.appendingPathComponent(name),
                    Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)].compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }()

    static func render(provider: ProviderID, snapshot: ProviderUsageSnapshot?) -> NSImage {
        let buckets = ProviderQuotaPresentation.selectedBuckets(snapshot)
        let rows = buckets.map { bucket -> (NSAttributedString, NSAttributedString) in
            let remaining = ProviderQuotaPresentation.remaining(bucket, snapshot: snapshot)
            let used = UserDefaults.standard.bool(forKey: ProviderQuotaPresentation.modeKey(provider, bucket))
            let amount = remaining.map { used ? 100 - $0 : $0 }
            let value = amount.map { "\(Int($0.rounded()))%" } ?? "?"
            let color = remaining.map { IconRenderer.color(for: Int($0.rounded())) } ?? IconRenderer.cachedQuotaColor
            let text = NSAttributedString(string: value, attributes: IconRenderer.quotaTextAttributes(
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold), color: color))
            let label = NSAttributedString(string: labelFor(bucket, provider: provider), attributes: IconRenderer.quotaTextAttributes(
                font: .systemFont(ofSize: 8, weight: .medium), color: .white))
            return (text, label)
        }
        let identifier = NSAttributedString(string: provider == .antigravity ? "AG" : "Z", attributes: IconRenderer.quotaTextAttributes(
            font: .systemFont(ofSize: 10, weight: .bold), color: .white))
        let numberWidth = rows.map { $0.0.size().width }.max() ?? 8
        let labelWidth = rows.map { $0.1.size().width }.max() ?? 0
        let logo = provider == .antigravity ? antigravityLogo : nil
        let prefixWidth = logo != nil ? CGFloat(26) : identifier.size().width + 5
        let size = NSSize(width: ceil(prefixWidth + numberWidth + labelWidth + 5), height: 23)
        let image = NSImage(size: size, flipped: true) { _ in
            if let logo {
                logo.draw(in: NSRect(x: 0, y: 0, width: 23, height: 23), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high])
            } else {
                identifier.draw(at: NSPoint(x: 0, y: (23 - identifier.size().height) / 2))
            }
            if rows.isEmpty {
                let unknown = NSAttributedString(string: "?", attributes: IconRenderer.quotaTextAttributes(
                    font: .systemFont(ofSize: 10, weight: .semibold), color: IconRenderer.cachedQuotaColor))
                unknown.draw(at: NSPoint(x: prefixWidth, y: (23 - unknown.size().height) / 2))
            }
            for (index, row) in rows.enumerated() {
                let rowHeight: CGFloat = rows.count == 1 ? 23 : 11.5
                let y = CGFloat(index) * rowHeight
                row.0.draw(at: NSPoint(x: prefixWidth + numberWidth - row.0.size().width, y: y + (rowHeight - row.0.size().height) / 2))
                row.1.draw(at: NSPoint(x: prefixWidth + numberWidth + 3, y: y + (rowHeight - row.1.size().height) / 2))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = provider.displayName + ": " + (buckets.isEmpty ? "usage unavailable" : buckets.map { bucket in
            let remaining = ProviderQuotaPresentation.remaining(bucket, snapshot: snapshot)
            let used = UserDefaults.standard.bool(forKey: ProviderQuotaPresentation.modeKey(provider, bucket))
            return bucket.title + (remaining.map { " \(Int((used ? 100 - $0 : $0).rounded())) percent \(used ? "used" : "remaining")" } ?? " unavailable")
        }.joined(separator: ", "))
        return image
    }

    private static func labelFor(_ bucket: ProviderUsageBucket, provider: ProviderID) -> String {
        if provider == .antigravity {
            let family = bucket.group == .gemini ? "G" : "O"
            let period = bucket.title.lowercased().contains("week") ? "w" : bucket.title.contains("5") ? "5h" : ""
            return family + (period.isEmpty ? "" : "·" + period)
        }
        let title = bucket.title.lowercased()
        if title.contains("5") || title.contains("hour") { return "5h" }
        if title.contains("week") { return "w" }
        return "m"
    }
}
