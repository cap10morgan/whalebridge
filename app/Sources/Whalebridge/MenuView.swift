import SwiftUI

struct MenuView: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var updater: Updater
    @ObservedObject var containers: ContainerStore = .shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Whalebridge: \(daemon.state.label)")
        // A compatible runtime is table stakes, not status — only surface it
        // when something needs the user's attention.
        if !daemon.runtimeStatus.isCompatible {
            Text("Apple container runtime: \(daemon.runtimeStatus.label)")
        }
        if !daemon.runtimeStatus.needsInstall {
            Text("Apple container services: \(daemon.apiserverRunning ? "running" : "stopped")")
        }

        if daemon.state == .running {
            Divider()

            Section("Containers") {
                if containers.running.isEmpty {
                    Text("None running")
                }
                ForEach(containers.running) { container in
                    Menu(container.name) {
                        Text("\(container.image) — \(container.status)")
                        Divider()
                        Button("Stop") { Task { await containers.stop(container) } }
                        Button("Restart") { Task { await containers.restart(container) } }
                        Button("Copy Name") { containers.copyName(container) }
                    }
                }
                if !containers.stopped.isEmpty {
                    Menu("Stopped") {
                        ForEach(containers.stopped) { container in
                            Menu(container.name) {
                                Text("\(container.image) — \(container.status)")
                                Divider()
                                Button("Start") { Task { await containers.start(container) } }
                                Button("Remove") { Task { await containers.remove(container) } }
                                Button("Copy Name") { containers.copyName(container) }
                            }
                        }
                    }
                }
            }
        }

        Divider()

        if daemon.runtimeStatus.needsInstall {
            Button("Install Apple Container \(daemon.requiredContainerVersion)…") {
                Task { await daemon.installRuntime() }
            }
            .disabled(daemon.installProgress != nil)
        }
        if let progress = daemon.installProgress {
            Text(progress)
        }
        if let error = daemon.installError {
            Text("Install failed: \(error)")
        }

        if daemon.state == .running {
            Button("Stop Whalebridge") { daemon.stop() }
        } else if !daemon.runtimeStatus.needsInstall {
            Button("Start Whalebridge") { Task { await daemon.start() } }
        }
        if !daemon.runtimeStatus.needsInstall && !daemon.apiserverRunning {
            Button("Start Apple Container Services") {
                Task { await daemon.startApiserver() }
            }
        }

        Divider()

        Toggle(
            "Use as Default Docker Context",
            isOn: Binding(
                get: { daemon.isDefaultContext },
                set: { daemon.setDefaultContext($0) }
            ))
        Button("Copy DOCKER_HOST Export") { daemon.copyDockerHost() }
        Button("Open Whalebridge Log") { daemon.openLog() }

        Divider()

        Button("About Whalebridge") { openWindow(id: "about") }
        if updater.isConfigured {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Whalebridge") { NSApplication.shared.terminate(nil) }
    }
}
