import ServiceManagement
import SwiftUI

/// User preferences that live outside the daemon's own state.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            apply(launchAtLogin: launchAtLogin)
        }
    }
    @Published private(set) var launchAtLoginError: String?

    private let firstRunLoginItemKey = "didFirstRunLoginItem"

    /// SMAppService only works on a real bundle, so `make dev` runs opt out.
    private var canManageLoginItem: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    private init() {
        guard canManageLoginItem else { return }
        // A menu bar daemon that vanishes on reboot is useless, so we opt in by
        // default — but only once, so we never re-enable a user's deliberate off.
        if !UserDefaults.standard.bool(forKey: firstRunLoginItemKey) {
            UserDefaults.standard.set(true, forKey: firstRunLoginItemKey)
            apply(launchAtLogin: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The system can revoke a login item behind our back (Login Items settings),
    /// so re-read rather than trusting our last write.
    func refresh() {
        guard canManageLoginItem else { return }
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin {
            launchAtLogin = enabled
        }
    }

    private func apply(launchAtLogin enabled: Bool) {
        guard canManageLoginItem else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            NSLog("failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater
    @ObservedObject var daemon: DaemonManager

    var body: some View {
        Form {
            Section {
                Toggle("Launch Whalebridge at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle(
                    "Use Whalebridge as the default Docker context",
                    isOn: Binding(
                        get: { daemon.isDefaultContext },
                        set: { daemon.setDefaultContext($0) }
                    ))
                Text("Plain `docker` commands run on Apple containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if updater.isConfigured {
                Section {
                    Toggle(
                        "Check for updates automatically",
                        isOn: $updater.automaticallyChecksForUpdates)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            settings.refresh()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.orderFrontRegardless()
        }
    }
}
