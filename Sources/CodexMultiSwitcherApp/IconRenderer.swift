import Cocoa
import Foundation
import SwiftUI

enum IconRenderer {
    private static let iconHeight: CGFloat = 23
    private static let rowHeight = Self.iconHeight / 2
    private static let textFontSize: CGFloat = 10
    private static let labelFontSize: CGFloat = 8
    private static let labelGap: CGFloat = 3
    private static let horizontalMargin: CGFloat = 2
    private static let emptyIconSize = CGSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let emptyIconName = "codex-multi-switcher-menu-icon-empty.png"

    // MARK: - Public

    static func render(primaryRemainingPercent: Int?, secondaryRemainingPercent: Int?,
                       primaryShowsUsed: Bool = false, secondaryShowsUsed: Bool = false,
                       cached: Bool = false, weeklyOnly: Bool = false,
                       weeklyResetAt: Date? = nil, showResetCountdown: Bool = true) -> NSImage {
        if weeklyOnly {
            return Self.withCodexIdentifier(Self.renderWeeklyOnly(remainingPercent: secondaryRemainingPercent,
                showsUsed: secondaryShowsUsed, cached: cached, resetAt: weeklyResetAt,
                showResetCountdown: showResetCountdown))
        }
        let primaryValue = primaryRemainingPercent.map {
            let remaining = min(100, max(0, $0))
            return primaryShowsUsed ? 100 - remaining : remaining
        }
        let secondaryValue = secondaryRemainingPercent.map {
            let remaining = min(100, max(0, $0))
            return secondaryShowsUsed ? 100 - remaining : remaining
        }
        let primaryColor = cached ? Self.cachedQuotaColor : primaryRemainingPercent.map(Self.color(for:)) ?? Self.cachedQuotaColor
        let secondaryColor = cached ? Self.cachedQuotaColor : secondaryRemainingPercent.map(Self.color(for:)) ?? Self.cachedQuotaColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: Self.textFontSize, weight: .bold)
        let topStr = NSAttributedString(
            string: primaryValue.map { String(format: "%02d", $0) } ?? "—",
            attributes: Self.quotaTextAttributes(font: font, color: primaryColor))
        let bottomStr = NSAttributedString(
            string: secondaryValue.map { String(format: "%02d", $0) } ?? "—",
            attributes: Self.quotaTextAttributes(font: font, color: secondaryColor))
        let labelFont = NSFont.systemFont(ofSize: Self.labelFontSize, weight: .medium)
        let topLabel = NSAttributedString(
            string: "5h", attributes: Self.quotaTextAttributes(font: labelFont, color: primaryColor))
        let bottomLabel = NSAttributedString(
            string: "w", attributes: Self.quotaTextAttributes(font: labelFont, color: secondaryColor))
        let topSize = topStr.size()
        let bottomSize = bottomStr.size()
        let numberWidth = max(topSize.width, bottomSize.width)
        let labelWidth = max(topLabel.size().width, bottomLabel.size().width)
        let contentWidth = numberWidth + Self.labelGap + labelWidth
        let imageWidth = ceil(contentWidth + Self.horizontalMargin * 2)
        let size = NSSize(width: imageWidth, height: Self.iconHeight)

        let image = NSImage(size: size, flipped: true) { _ in
            let numberRightEdge = Self.horizontalMargin + numberWidth
            Self.drawRow(topStr, textSize: topSize, rightEdge: numberRightEdge, rowY: 0)
            Self.drawRow(bottomStr, textSize: bottomSize, rightEdge: numberRightEdge, rowY: Self.rowHeight)
            let labelX = numberRightEdge + Self.labelGap
            Self.drawLabel(topLabel, x: labelX, rowY: 0)
            Self.drawLabel(bottomLabel, x: labelX, rowY: Self.rowHeight)

            return true
        }

        // Template images discard the traffic-light colors in the menu bar.
        image.isTemplate = false
        let primaryDescription = primaryValue.map { "5 hours \($0) percent \(primaryShowsUsed ? "used" : "remaining")" } ?? "5 hours unavailable"
        let secondaryDescription = secondaryValue.map { "week \($0) percent \(secondaryShowsUsed ? "used" : "remaining")" } ?? "week unavailable"
        image.accessibilityDescription = "Codex quota: \(cached ? "cached observations, " : "")\(primaryDescription), \(secondaryDescription)"
        return Self.withCodexIdentifier(image)
    }

    private static func renderWeeklyOnly(remainingPercent: Int?, showsUsed: Bool, cached: Bool,
                                         resetAt: Date?, showResetCountdown: Bool) -> NSImage {
        let remaining = remainingPercent.map { min(100, max(0, $0)) }
        let value = remaining.map { showsUsed ? 100 - $0 : $0 }
        let color = cached ? Self.cachedQuotaColor : remaining.map(Self.color(for:)) ?? Self.cachedQuotaColor
        let number = NSAttributedString(string: value.map { "\($0)%" } ?? "—",
            attributes: Self.quotaTextAttributes(font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold), color: color))
        let detail = NSMutableAttributedString(string: "w",
            attributes: Self.quotaTextAttributes(font: .monospacedDigitSystemFont(ofSize: 8, weight: .medium), color: color))
        if showResetCountdown, let countdown = Self.weeklyCountdown(resetAt) {
            detail.append(NSAttributedString(string: " · " + countdown,
                attributes: Self.quotaTextAttributes(font: .monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                    color: NSColor(ResetCountdownColor.color(for: resetAt, isStale: cached)))))
        }
        let width = ceil(number.size().width + detail.size().width + 7)
        let image = NSImage(size: NSSize(width: width, height: Self.iconHeight), flipped: true) { _ in
            number.draw(at: NSPoint(x: 2, y: (Self.iconHeight - number.size().height) / 2))
            detail.draw(at: NSPoint(x: 5 + number.size().width, y: (Self.iconHeight - detail.size().height) / 2))
            return true
        }
        image.isTemplate = false
        let amount = value.map { "week \($0) percent \(showsUsed ? "used" : "remaining")" } ?? "week unavailable"
        let resetDescription = showResetCountdown ? resetAt.map { ", resets \($0.formatted(date: .complete, time: .shortened))" } ?? "" : ""
        image.accessibilityDescription = "Codex quota: \(cached ? "cached observation, " : "")\(amount)\(resetDescription)"
        return image
    }

    // Codex uses the bundled flat OpenAI knot within a contrasting badge.
    private static func withCodexIdentifier(_ quota: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: quota.size.width + 20, height: Self.iconHeight), flipped: true) { _ in
            Self.drawCodexIdentifier(in: NSRect(x: 1, y: 4, width: 15, height: 15))
            quota.draw(in: NSRect(x: 20, y: 0, width: quota.size.width, height: Self.iconHeight),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = quota.accessibilityDescription
        return image
    }

    private static let openAIKnot: NSImage? = {
        let name = "openai-knot-menu.png"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)]
        for url in candidates.compactMap({ $0 }) {
            if let mask = NSImage(contentsOf: url) {
                let size = mask.size
                let whiteKnot = NSImage(size: size, flipped: false) { _ in
                    // Tint in this isolated image so sourceIn cannot affect the black badge.
                    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                    let bounds = NSRect(origin: .zero, size: size)
                    mask.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    bounds.fill(using: .sourceIn)
                    return true
                }
                whiteKnot.isTemplate = false
                return whiteKnot
            }
        }
        return nil
    }()

    private static func drawCodexIdentifier(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        shadow.set()
        let frame = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.black.setFill()
        frame.fill()
        NSColor.white.setStroke()
        frame.lineWidth = 0.6
        frame.stroke()
        // The official template mask is tinted white in its own image; this badge supplies contrast.
        if let knot = Self.openAIKnot {
            knot.draw(in: rect.insetBy(dx: 1.2, dy: 1.2), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func weeklyCountdown(_ resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds.isFinite else { return nil }
        if seconds <= 0 { return "reset due" }
        if seconds > 365 * 86400 { return ">365d" }
        let hours = Int(seconds) / 3600
        if hours >= 24 { return "\(hours / 24)d\(hours % 24)h" }
        return hours == 0 ? "<1h" : "\(hours)h"
    }

    static func renderEmpty() -> NSImage {
        Self.loadIcon(named: Self.emptyIconName)
            ?? Self.renderFallbackEmpty()
    }

    // Light colors keep small glyphs legible on dark and saturated menu backgrounds.
    static let cachedQuotaColor = NSColor(srgbRed: 0.77, green: 0.80, blue: 0.85, alpha: 1)
    static let lowQuotaColor = NSColor(srgbRed: 1.00, green: 0.67, blue: 0.72, alpha: 1)
    static let midQuotaColor = NSColor(srgbRed: 1.00, green: 0.86, blue: 0.44, alpha: 1)
    static let highQuotaColor = NSColor(srgbRed: 0.50, green: 0.94, blue: 0.69, alpha: 1)

    // The thresholds always describe remaining quota, independently of display mode.
    static func color(for remainingPercent: Int) -> NSColor {
        if remainingPercent < 20 { return Self.lowQuotaColor }
        if remainingPercent < 50 { return Self.midQuotaColor }
        return Self.highQuotaColor
    }

    static func quotaTextAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.88)
        shadow.shadowBlurRadius = 1.25
        shadow.shadowOffset = .zero
        return [.font: font, .foregroundColor: color, .shadow: shadow,
                .strokeColor: NSColor.white.withAlphaComponent(0.8), .strokeWidth: -0.8]
    }

    // MARK: - Row Drawing

    private static func drawRow(
        _ attrStr: NSAttributedString,
        textSize: CGSize,
        rightEdge: CGFloat,
        rowY: CGFloat
    ) {
        let textY = rowY + (Self.rowHeight - textSize.height) / 2
        attrStr.draw(at: NSPoint(x: rightEdge - textSize.width, y: textY))
    }

    private static func drawLabel(_ label: NSAttributedString, x: CGFloat, rowY: CGFloat) {
        let textY = rowY + (Self.rowHeight - label.size().height) / 2
        label.draw(at: NSPoint(x: x, y: textY))
    }

    // MARK: - Empty Icon

    private static func loadIcon(named name: String) -> NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name),
        ].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = Self.emptyIconSize
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func renderFallbackEmpty() -> NSImage {
        let size = Self.emptyIconSize

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: Self.scale, y: Self.scale)
            Self.drawFrontCard(ctx: ctx)
            return true
        }

        image.isTemplate = true
        return image
    }

    private static func drawFrontCard(ctx: CGContext) {
        let frontRect = CGRect(x: 3.0, y: 6.4, width: 9.8, height: 8.4)
        let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(frontPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5.8, y: 10.6))
        ctx.addLine(to: CGPoint(x: 10.1, y: 10.6))
        ctx.strokePath()

        let markerRect = CGRect(x: 4.45, y: 9.65, width: 1.9, height: 1.9)
        let markerPath = CGPath(ellipseIn: markerRect, transform: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(markerPath)
        ctx.fillPath()
    }
}

// MARK: - CodexBridge
