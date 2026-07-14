import Combine
import Sparkle
import SwiftUI

/// Sparkle, wrapped so SwiftUI can bind to it. The appcast URL and the public
/// EdDSA key come from Info.plist (SUFeedURL / SUPublicEDKey), baked in by
/// bundle.sh — so an unbundled `make dev` run simply has no updater.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// False when there's no feed configured (dev runs); the menu hides the
    /// update controls rather than offering a check that can only fail.
    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !feed.isEmpty
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        do {
            try controller.updater.start()
        } catch {
            NSLog("Sparkle failed to start: \(error)")
            return
        }
        self.controller = controller
        isConfigured = true
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        // We're an accessory app, so Sparkle's window would otherwise open behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        controller?.updater.checkForUpdates()
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// A background check that found an update shouldn't yank focus out of the
    /// user's editor; Sparkle waits until they come back to us.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
