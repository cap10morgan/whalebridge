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

    /// Percent of host RAM containers get when they don't request a memory
    /// limit of their own (passed to socktainer as SOCKTAINER_DEFAULT_MEMORY_PERCENT).
    /// Apple Container's own default is a fixed 1 GiB, which real workloads
    /// (e.g. Node/vite builds) can OOM well under.
    @Published var defaultContainerMemoryPercent: Double = 75 {
        didSet {
            guard defaultContainerMemoryPercent != oldValue else { return }
            UserDefaults.standard.set(defaultContainerMemoryPercent, forKey: defaultContainerMemoryPercentKey)
        }
    }

    /// Stop both socktainer and the apple/container apiserver after
    /// idleTimeoutMinutes of inactivity, transparently waking them on the
    /// next Docker API connection (IdlePowerSavingProxy). Takes effect the
    /// next time Whalebridge starts, same as defaultContainerMemoryPercent.
    @Published var powerSavingEnabled: Bool = false {
        didSet {
            guard powerSavingEnabled != oldValue else { return }
            UserDefaults.standard.set(powerSavingEnabled, forKey: powerSavingEnabledKey)
        }
    }
    @Published var idleTimeoutMinutes: Double = 30 {
        didSet {
            guard idleTimeoutMinutes != oldValue else { return }
            UserDefaults.standard.set(idleTimeoutMinutes, forKey: idleTimeoutMinutesKey)
        }
    }

    private let firstRunLoginItemKey = "didFirstRunLoginItem"
    private let defaultContainerMemoryPercentKey = "defaultContainerMemoryPercent"
    private let powerSavingEnabledKey = "powerSavingEnabled"
    private let idleTimeoutMinutesKey = "idleTimeoutMinutes"

    /// SMAppService only works on a real bundle, so `make dev` runs opt out.
    private var canManageLoginItem: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    private init() {
        if let stored = UserDefaults.standard.object(forKey: defaultContainerMemoryPercentKey) as? Double {
            defaultContainerMemoryPercent = stored
        }
        if let stored = UserDefaults.standard.object(forKey: idleTimeoutMinutesKey) as? Double {
            idleTimeoutMinutes = stored
        }
        if let stored = UserDefaults.standard.object(forKey: powerSavingEnabledKey) as? Bool {
            powerSavingEnabled = stored
        } else if !UserDefaults.standard.bool(forKey: firstRunLoginItemKey) {
            // This key not being set doesn't by itself mean a new install —
            // it's a new *setting*, so every existing install upgrading to
            // it would look identical to a fresh one. firstRunLoginItemKey
            // has been set on every launch since Whalebridge's first
            // version, so its absence is the actual "never run before"
            // signal; enable by default only then — an existing install
            // (the else branch) explicitly opts out instead.
            powerSavingEnabled = true
            UserDefaults.standard.set(true, forKey: powerSavingEnabledKey)
        } else {
            // Existing install upgrading to a version with this setting —
            // never silently turn this on behind someone already using
            // Whalebridge.
            powerSavingEnabled = false
            UserDefaults.standard.set(false, forKey: powerSavingEnabledKey)
        }

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

    private var memoryLimitCaption: String {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let limitGB = totalGB * settings.defaultContainerMemoryPercent / 100
        return String(
            format: "%.0f%% of this Mac's %.0f GB (%.0f GB) for containers that don't set their own limit."
                + " Applies the next time Whalebridge starts.",
            settings.defaultContainerMemoryPercent, totalGB, limitGB)
    }

    private var idleTimeoutCaption: String {
        String(
            format: "Stop both daemons after %.0f minutes idle, and transparently restart them on the next"
                + " docker command. Applies the next time Whalebridge starts.",
            settings.idleTimeoutMinutes)
    }

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

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $settings.defaultContainerMemoryPercent, in: 10...90, step: 5) {
                        Text("Default container memory limit")
                    }
                    Text(memoryLimitCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Power saving", isOn: $settings.powerSavingEnabled)
                if settings.powerSavingEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $settings.idleTimeoutMinutes, in: 5...120, step: 5) {
                            Text("Idle timeout")
                        }
                        Text(idleTimeoutCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
