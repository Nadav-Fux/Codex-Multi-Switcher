import Cocoa

/// One status item keeps the selected provider indicators adjacent.
enum MenuBarCompositeRenderer {
    private static let height: CGFloat = 23
    private static let gap: CGFloat = 8

    static func render(codex: NSImage, claude: NSImage, providers: MenuBarProviders) -> NSImage {
        let selected: [(NSImage, String)] = switch providers {
        case .codex: [(codex, "Codex")]
        case .claude: [(claude, "Claude Code")]
        case .both: [(codex, "Codex"), (claude, "Claude Code")]
        }
        let images = selected.map { Self.boundedImage($0.0, provider: $0.1) }
        let widths = images.map { image -> CGFloat in
            let scale = min(1, Self.height / image.size.height)
            return ceil(image.size.width * scale)
        }
        let width = widths.reduce(0, +) + Self.gap * CGFloat(images.count - 1)
        let image = NSImage(size: NSSize(width: width, height: Self.height), flipped: true) { _ in
            var x: CGFloat = 0
            for (index, source) in images.enumerated() {
                let scale = min(1, Self.height / source.size.height)
                let sourceHeight = source.size.height * scale
                source.draw(in: NSRect(x: x, y: (Self.height - sourceHeight) / 2,
                    width: widths[index], height: sourceHeight),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += widths[index] + Self.gap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = images.enumerated().map { index, source in
            source.accessibilityDescription ?? "\(selected[index].1) usage unavailable"
        }.joined(separator: "; ")
        return image
    }

    private static func boundedImage(_ image: NSImage, provider: String) -> NSImage {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= 512, size.height <= 128 else {
            let text = NSAttributedString(string: "?", attributes: IconRenderer.quotaTextAttributes(
                font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                color: IconRenderer.cachedQuotaColor))
            let fallback = NSImage(size: NSSize(width: 18, height: Self.height), flipped: true) { _ in
                text.draw(at: NSPoint(x: (18 - text.size().width) / 2,
                    y: (Self.height - text.size().height) / 2))
                return true
            }
            fallback.accessibilityDescription = image.accessibilityDescription ?? "\(provider) usage unavailable"
            return fallback
        }
        return image
    }
}
