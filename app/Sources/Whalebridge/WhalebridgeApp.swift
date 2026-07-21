import SwiftUI

@main
struct WhalebridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var daemon = DaemonManager.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(daemon: daemon, updater: updater)
        } label: {
            MenuBarLabel(daemon: daemon)
        }

        Settings {
            SettingsView(settings: settings, updater: updater, daemon: daemon)
        }

        Window("About Whalebridge", id: "about") {
            AboutView(updater: updater)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep us out of the Dock even when run unbundled (make dev).
        NSApp.setActivationPolicy(.accessory)
        _ = AppSettings.shared
        _ = Updater.shared
        ContainerStore.shared.startPolling()
        Task {
            await DaemonManager.shared.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DaemonManager.shared.markTerminating()
        DaemonManager.shared.stop()
    }
}
