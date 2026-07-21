import SwiftUI

struct AboutView: View {
    @ObservedObject var updater: Updater

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Whalebridge")
                    .font(.title2.bold())
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/cap10morgan/whalebridge")!)
                }
                if updater.isConfigured {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            VStack(spacing: 4) {
                Text("Built on")
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Link("socktainer", destination: URL(string: "https://github.com/socktainer/socktainer")!)
                    Text("and")
                        .foregroundStyle(.secondary)
                    Link("Apple container", destination: URL(string: "https://github.com/apple/container")!)
                }
            }
            .font(.caption)
        }
        .padding(24)
        .frame(width: 280)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.orderFrontRegardless()
        }
    }
}
