import SwiftUI

struct MenuView: View {
    @ObservedObject var daemon: DaemonManager

    var body: some View {
        Text("Daemon: \(daemon.state.label)")
        Text("Apple container runtime: \(daemon.runtimeStatus.label)")
        if !daemon.runtimeStatus.needsInstall {
            Text("Apple container services: \(daemon.apiserverRunning ? "running" : "stopped")")
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
            Button("Stop Daemon") { daemon.stop() }
        } else if !daemon.runtimeStatus.needsInstall {
            Button("Start Daemon") { Task { await daemon.start() } }
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
        Button("Open Daemon Log") { daemon.openLog() }

        Divider()

        Button("Quit Whalebridge") { NSApplication.shared.terminate(nil) }
    }
}
