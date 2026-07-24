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

    // SwiftPM's generated Bundle.module accessor looks next to
    // Bundle.main.bundleURL, which is the .app root — wrong for a real .app,
    // where resources live in Contents/Resources and codesign rejects
    // anything else at the bundle root. Bundle.main.resourceURL resolves
    // correctly there; it's nil for `swift run`'s flat layout, where
    // Bundle.module (matching that layout) is the fallback.
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Whalebridge_Whalebridge.bundle"),
            let bundle = Bundle(url: url)
        {
            return bundle
        }
        return Bundle.module
    }()

    private static func load(_ name: String) -> NSImage {
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
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

/// Which glyph the menu bar shows. Pure decision logic, kept separate from the
/// NSImage loading so it's unit-testable.
enum MenuBarIconState: Equatable {
    case animating
    case active
    case inactive

    /// Both the daemon and Apple's container services gate usability: docker
    /// commands work only when socktainer is running *and* the apiserver is up,
    /// so anything less than that is inactive (dimmed) — including a running
    /// daemon over a stopped apiserver. Animation covers every transition we
    /// drive: daemon startup, and starting/restarting Apple's services.
    static func forState(
        daemon: DaemonManager.State, apiserverRunning: Bool, apiserverTransitioning: Bool
    ) -> Self {
        if apiserverTransitioning || daemon == .starting { return .animating }
        if daemon == .running && apiserverRunning { return .active }
        return .inactive
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

/// The menu bar's label: animates through transitions, full-strength only when
/// docker commands would actually work, dimmed otherwise.
struct MenuBarLabel: View {
    @ObservedObject var daemon: DaemonManager
    @StateObject private var animator = MenuBarAnimator()

    var body: some View {
        Image(nsImage: image)
            .onChange(of: iconState == .animating, initial: true) { _, animating in
                if animating { animator.start() } else { animator.stop() }
            }
    }

    private var iconState: MenuBarIconState {
        .forState(
            daemon: daemon.state,
            apiserverRunning: daemon.apiserverRunning,
            apiserverTransitioning: daemon.apiserverTransitioning)
    }

    private var image: NSImage {
        switch iconState {
        case .animating: MenuBarIcon.startingFrames[animator.frame]
        case .active: MenuBarIcon.running
        case .inactive: MenuBarIcon.stopped
        }
    }
}
