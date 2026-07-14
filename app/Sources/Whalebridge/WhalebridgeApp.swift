import SwiftUI

@main
struct WhalebridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var daemon = DaemonManager.shared
    @ObservedObject private var updater = Updater.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(daemon: daemon, updater: updater)
        } label: {
            Image(nsImage: daemon.state == .running ? MenuBarIcon.running : MenuBarIcon.stopped)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep us out of the Dock even when run unbundled (make dev).
        NSApp.setActivationPolicy(.accessory)
        _ = Updater.shared
        Task {
            await DaemonManager.shared.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DaemonManager.shared.markTerminating()
        DaemonManager.shared.stop()
    }
}
