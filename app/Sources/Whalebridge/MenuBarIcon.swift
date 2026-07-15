import AppKit
import SwiftUI

/// The whale-bridge template glyph for the menu bar: `stopped` is a dimmed
/// variant so the daemon state is visible at a glance, and `startingFrames` is
/// a loop of the tail lifting off the bridge deck and settling back.
@MainActor
enum MenuBarIcon {
    static let running: NSImage = load("MenuBarIcon")
    static let stopped: NSImage = dimmed(load("MenuBarIcon"), alpha: 0.45)
    static let startingFrames: [NSImage] = (0..<12).map { load(String(format: "MenuBarIcon-%02d", $0)) }
    static let frameDuration: Duration = .milliseconds(80)

    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
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

/// Drives the frame loop while the daemon is coming up. Kept separate from
/// DaemonManager so a redraw 12x a second doesn't republish daemon state.
@MainActor
final class MenuBarAnimator: ObservableObject {
    @Published private(set) var frame = 0
    private var task: Task<Void, Never>?

    var isAnimating: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MenuBarIcon.frameDuration)
                guard let self else { return }
                frame = (frame + 1) % MenuBarIcon.startingFrames.count
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        frame = 0
    }
}

/// The menu bar's label: animates while starting, otherwise a static glyph.
struct MenuBarLabel: View {
    @ObservedObject var daemon: DaemonManager
    @StateObject private var animator = MenuBarAnimator()

    var body: some View {
        Image(nsImage: image)
            .onChange(of: daemon.state == .starting, initial: true) { _, starting in
                if starting { animator.start() } else { animator.stop() }
            }
    }

    private var image: NSImage {
        switch daemon.state {
        case .starting: MenuBarIcon.startingFrames[animator.frame]
        case .running: MenuBarIcon.running
        default: MenuBarIcon.stopped
        }
    }
}
