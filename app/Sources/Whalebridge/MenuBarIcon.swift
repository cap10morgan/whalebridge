import AppKit

/// The whale-bridge template glyph for the menu bar; `stopped` is a dimmed
/// variant so the daemon state is visible at a glance.
@MainActor
enum MenuBarIcon {
    static let running: NSImage = load()
    static let stopped: NSImage = dimmed(load(), alpha: 0.45)

    private static func load() -> NSImage {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            let fallback = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Whalebridge")!
            fallback.isTemplate = true
            return fallback
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private static func dimmed(_ base: NSImage, alpha: CGFloat) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
}
