import SwiftUI

struct AboutView: View {
    @ObservedObject var updater: Updater

    private var version: String { AppVersion.current }

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

            HStack(alignment: .top) {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/cap10morgan/whalebridge")!)
                }
                if updater.isConfigured {
                    // Two lines keep the caption about as wide as the button it describes.
                    VStack(spacing: 6) {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                        Text("Last checked\n\(updater.lastUpdateCheckText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            updater.refreshLastUpdateCheckDate()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.orderFrontRegardless()
        }
    }
}
