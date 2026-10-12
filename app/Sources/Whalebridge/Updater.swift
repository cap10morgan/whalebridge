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

    /// Pending answers for offerAvailableUpdate(), resumed from the
    /// SPUUpdaterDelegate callbacks below.
    private var updateProbe: CheckedContinuation<Bool, Never>?
    private var updateDecision: CheckedContinuation<Bool, Never>?
    private var probeFoundUpdate = false
    /// The probe is riding on a check Sparkle already had under way, whose
    /// cycle doesn't end until the user has dealt with whatever it found.
    private var probeSharesSession = false

    private override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !feed.isEmpty
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
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

    /// Looks for an update and, if there is one, shows it and waits for the
    /// user's answer. True means they chose to install it. False covers
    /// everything else: nothing newer, the check failed or timed out, they
    /// declined, or automatic checks are off (in which case we don't go
    /// looking behind their back).
    func offerAvailableUpdate() async -> Bool {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates,
            updateProbe == nil, updateDecision == nil
        else { return false }
        guard await updateIsAvailable(updater) else { return false }
        return await withCheckedContinuation { continuation in
            updateDecision = continuation
            checkForUpdates()
        }
    }

    private func updateIsAvailable(_ updater: SPUUpdater) async -> Bool {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.resolveProbe(false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            updateProbe = continuation
            probeFoundUpdate = false
            // Sparkle may have begun its own scheduled check at launch, and a
            // probe does nothing during a session — listen in on that one.
            probeSharesSession = updater.sessionInProgress
            if !probeSharesSession { updater.checkForUpdateInformation() }
        }
    }

    private func resolveProbe(_ found: Bool) {
        updateProbe?.resume(returning: found)
        updateProbe = nil
    }

    private func resolveDecision(installing: Bool) {
        updateDecision?.resume(returning: installing)
        updateDecision = nil
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        probeFoundUpdate = true
        if probeSharesSession { resolveProbe(true) }
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        resolveDecision(installing: choice == .install)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Our own probe answers only here, once its session is over: answering
        // from didFindValidUpdate would let this same callback land afterwards
        // and be mistaken for the user dismissing the update we then show.
        if updateProbe != nil {
            resolveProbe(probeFoundUpdate)
        } else {
            resolveDecision(installing: false)
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// A background check that found an update shouldn't yank focus out of the
    /// user's editor; Sparkle waits until they come back to us.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
