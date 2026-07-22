import AppKit
import Foundation

/// Owns the bundled socktainer daemon process and tracks the state of the
/// Apple container services it depends on.
@MainActor
final class DaemonManager: ObservableObject {
    static let shared = DaemonManager()

    enum State: Equatable {
        case stopped
        case starting
        case running
        case waitingForRuntime
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "stopped"
            case .starting: "starting…"
            case .running: "running"
            case .waitingForRuntime: "waiting for Apple container runtime"
            case .failed(let reason): "failed — \(reason)"
            }
        }
    }

    enum RuntimeStatus: Equatable {
        case checking
        case notInstalled
        case incompatible(installed: String, required: String)
        case compatible(String)

        var label: String {
            switch self {
            case .checking: "checking…"
            case .notInstalled: "not installed"
            case .incompatible(let installed, let required): "\(installed) installed — needs \(required).x"
            case .compatible(let version): version
            }
        }

        var needsInstall: Bool {
            switch self {
            case .notInstalled, .incompatible: true
            case .checking, .compatible: false
            }
        }

        var isCompatible: Bool {
            if case .compatible = self { true } else { false }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var apiserverRunning = false
    @Published private(set) var runtimeStatus: RuntimeStatus = .checking
    @Published private(set) var installProgress: String?
    @Published private(set) var installError: String?
    @Published private(set) var isDefaultContext = DockerContext.isDefault

    private let previousContextKey = "previousDockerContext"
    private let firstRunContextKey = "didFirstRunContextSetup"
    private let verifiedApiserverVersionKey = "verifiedApiserverVersion"
    private var offeredInstallThisLaunch = false
    private(set) var isTerminating = false

    /// apple/container major.minor the bundled socktainer requires; baked into
    /// Info.plist by bundle.sh from the vendored Package.swift pin.
    var requiredContainerVersion: String {
        ProcessInfo.processInfo.environment["WHALEBRIDGE_CONTAINER_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "WBRequiredContainerVersion") as? String
            ?? "1.1.0"
    }

    let socketPath = NSHomeDirectory() + "/.socktainer/container.sock"
    var dockerHost: String { "unix://\(socketPath)" }

    var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Whalebridge/daemon.log")
    }

    private let containerCLI =
        ProcessInfo.processInfo.environment["WHALEBRIDGE_CONTAINER_CLI"] ?? "/usr/local/bin/container"
    private var containerCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: containerCLI)
    }
    private var process: Process?
    private var stopRequested = false
    private var pollTask: Task<Void, Never>?

    /// Bundled binary in Contents/MacOS, or WHALEBRIDGE_DAEMON when run via `make dev`.
    private var daemonURL: URL? {
        if let override = ProcessInfo.processInfo.environment["WHALEBRIDGE_DAEMON"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "socktainer"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled
        }
        return nil
    }

    func bootstrap() async {
        await refreshRuntimeStatus()
        await refreshApiserverStatus()
        await start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.refreshRuntimeStatus()
                await self.refreshApiserverStatus()
                self.refreshContextStatus()
                // runtime appeared (user finished Installer.app) — start the daemon
                if case .compatible = self.runtimeStatus, self.state == .waitingForRuntime {
                    await self.start()
                }
            }
        }
        if runtimeStatus.needsInstall {
            offerRuntimeInstall()
        }
    }

    /// SIGTERM to the app (pkill, logout) skips applicationWillTerminate, so a
    /// previous instance's daemon can outlive it. Track the child in a pidfile
    /// and reap it before starting a new one.
    private var pidFileURL: URL {
        logFileURL.deletingLastPathComponent().appending(path: "daemon.pid")
    }

    private func reapOrphanedDaemon() async {
        defer { try? FileManager.default.removeItem(at: pidFileURL) }
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
            kill(pid, 0) == 0
        else { return }
        // Guard against pid reuse: only kill if it's actually our daemon.
        let result = await Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        if result.output.contains("socktainer") {
            kill(pid, SIGTERM)
        }
    }

    func start() async {
        guard state != .running, state != .starting else { return }
        guard let daemonURL, FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            state = .failed("Whalebridge binary not found")
            return
        }
        await refreshRuntimeStatus()
        guard case .compatible(let version) = runtimeStatus else {
            state = .waitingForRuntime
            return
        }
        state = .starting
        stopRequested = false
        await reapOrphanedDaemon()

        // The apple/container pkg installer updates files on disk but doesn't
        // restart an already-running apiserver, so a service started under an
        // old version can still be live here even though `container --version`
        // now reports the new one — and that can be true on a totally fresh
        // Whalebridge launch, long after whatever upgraded it (our own
        // installer flow, Homebrew, a manual download). socktainer's own
        // compatibility check pings that live process, not the CLI, so
        // trusting apiserverRunning would start it against a stale server.
        // Track the last version we've confirmed the apiserver was actually
        // restarted for, persisted across launches, and restart whenever it
        // doesn't match what's installed now.
        if UserDefaults.standard.string(forKey: verifiedApiserverVersionKey) != version {
            NSLog("apple/container version changed to \(version) — restarting apiserver before starting Whalebridge")
            await restartApiserver()
            UserDefaults.standard.set(version, forKey: verifiedApiserverVersionKey)
        } else if !apiserverRunning {
            await startApiserver()
        }

        let daemon = Process()
        daemon.executableURL = daemonURL
        daemon.arguments = ["--no-docker-context"]
        // Brand `docker version` output (patches/0001-brandable-platform-name.patch).
        let appVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        daemon.environment = ProcessInfo.processInfo.environment.merging([
            "SOCKTAINER_PLATFORM_NAME": "Whalebridge",
            "SOCKTAINER_PLATFORM_VERSION": appVersion,
            // Default memory limit for containers that don't request their own
            // (patches/0002-default-container-memory-limit.patch), configurable
            // in Settings.
            "SOCKTAINER_DEFAULT_MEMORY_PERCENT": "\(AppSettings.shared.defaultContainerMemoryPercent)",
        ]) { _, new in new }
        if let log = makeLogHandle() {
            daemon.standardOutput = log
            daemon.standardError = log
        }
        daemon.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.daemonDidExit(status: status)
            }
        }

        do {
            try daemon.run()
            process = daemon
            try? "\(daemon.processIdentifier)".write(to: pidFileURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        await waitForSocket()
        // stop() or an early daemon exit may have moved us on while we waited.
        guard state == .starting else { return }
        state = .running
        try? DockerContext.ensureContext(socketPath: socketPath)
        performFirstRunContextSetup()
    }

    /// socktainer needs a moment to bind its socket, so "running" should mean
    /// "answering", not "spawned" — otherwise the first docker command races it.
    private func waitForSocket() async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && state == .starting {
            if socketIsAccepting() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Connect rather than stat: a stale socket file from a crashed daemon
    /// exists on disk but refuses connections.
    private func socketIsAccepting() -> Bool {
        guard let fd = try? UnixHTTP.connect(socketPath, timeoutSeconds: 1) else { return false }
        close(fd)
        return true
    }

    /// Once, on the first successful daemon start: if no other engine owns the
    /// Docker context, claim it silently; if one does, ask — never steal.
    private func performFirstRunContextSetup() {
        guard !UserDefaults.standard.bool(forKey: firstRunContextKey) else { return }
        UserDefaults.standard.set(true, forKey: firstRunContextKey)

        guard let current = DockerContext.currentContext(), current != "default" else {
            setDefaultContext(true)
            return
        }
        guard current != DockerContext.name else { return }

        let alert = NSAlert()
        alert.messageText = "Make Whalebridge your default Docker context?"
        alert.informativeText =
            "Your docker CLI currently uses the “\(current)” context. If Whalebridge becomes the default, "
            + "plain docker commands run on Apple containers. You can switch back anytime from the menu bar."
        alert.addButton(withTitle: "Use Whalebridge")
        alert.addButton(withTitle: "Keep “\(current)”")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // Quitting the app while the alert is open makes runModal() return
        // .alertFirstButtonReturn — don't treat an involuntary dismissal as consent.
        guard !isTerminating, response == .alertFirstButtonReturn else { return }
        setDefaultContext(true)
    }

    /// Toggle whether `whalebridge` is the Docker CLI's current context.
    /// config.json is the source of truth; the menu toggle reflects it even if
    /// the user runs `docker context use` behind our back.
    func setDefaultContext(_ enabled: Bool) {
        do {
            if enabled {
                try DockerContext.ensureContext(socketPath: socketPath)
                let previous = try DockerContext.makeDefault()
                UserDefaults.standard.set(previous, forKey: previousContextKey)
            } else {
                try DockerContext.resignDefault(
                    restoring: UserDefaults.standard.string(forKey: previousContextKey))
                UserDefaults.standard.removeObject(forKey: previousContextKey)
            }
        } catch {
            NSLog("failed to update Docker context: \(error)")
        }
        isDefaultContext = DockerContext.isDefault
    }

    func markTerminating() {
        isTerminating = true
    }

    func stop() {
        stopRequested = true
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: pidFileURL)
        state = .stopped
    }

    func startApiserver() async {
        guard containerCLIInstalled else { return }
        let result = await Shell.run(containerCLI, ["system", "start"])
        if result.status != 0 {
            NSLog("container system start exited \(result.status): \(result.output)")
        }
        await refreshApiserverStatus()
    }

    /// `container system stop` on an already-stopped service is a harmless
    /// no-op, so this is safe to call whenever the running apiserver's
    /// version is in doubt.
    private func restartApiserver() async {
        let result = await Shell.run(containerCLI, ["system", "stop"])
        if result.status != 0 {
            NSLog("container system stop exited \(result.status): \(result.output)")
        }
        await startApiserver()
    }

    private func refreshRuntimeStatus() async {
        guard containerCLIInstalled else {
            runtimeStatus = .notInstalled
            return
        }
        let result = await Shell.run(containerCLI, ["--version"])
        guard let match = result.output.firstMatch(of: #/version (\d+)\.(\d+)\.(\d+)/#) else {
            runtimeStatus = .incompatible(installed: "unknown version", required: requiredMajorMinor)
            return
        }
        let installed = "\(match.1).\(match.2).\(match.3)"
        if "\(match.1).\(match.2)" == requiredMajorMinor {
            runtimeStatus = .compatible(installed)
            if installProgress != nil {
                installProgress = nil  // install finished
            }
        } else {
            runtimeStatus = .incompatible(installed: installed, required: requiredMajorMinor)
        }
    }

    private var requiredMajorMinor: String {
        requiredContainerVersion.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Download the signed apple/container installer, verify Apple's signature,
    /// and hand it to Installer.app (which owns the admin-privileges prompt).
    func installRuntime() async {
        guard installProgress == nil else { return }
        installError = nil
        let version = requiredContainerVersion
        let pkgName = "container-\(version)-installer-signed.pkg"
        installProgress = "Downloading Apple container \(version)…"
        defer { if installError != nil { installProgress = nil } }
        do {
            let url = URL(string: "https://github.com/apple/container/releases/download/\(version)/\(pkgName)")!
            let (tmpFile, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallFailure("download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            let dest = FileManager.default.temporaryDirectory.appending(path: pkgName)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpFile, to: dest)

            installProgress = "Verifying signature…"
            let signature = await Shell.run("/usr/sbin/pkgutil", ["--check-signature", dest.path])
            guard signature.status == 0,
                signature.output.contains("Apple Inc. - Containerization"),
                signature.output.contains("trusted by the Apple notary service")
            else {
                try? FileManager.default.removeItem(at: dest)
                throw InstallFailure("installer signature verification failed")
            }

            installProgress = "Finish the install in Installer, then Whalebridge starts automatically."
            NSWorkspace.shared.open(dest)
        } catch let failure as InstallFailure {
            installError = failure.message
        } catch {
            installError = error.localizedDescription
        }
    }

    private struct InstallFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func offerRuntimeInstall() {
        guard !offeredInstallThisLaunch else { return }
        offeredInstallThisLaunch = true
        let alert = NSAlert()
        alert.messageText = "Whalebridge needs Apple's container runtime"
        switch runtimeStatus {
        case .incompatible(let installed, let required):
            alert.informativeText =
                "Apple container \(installed) is installed, but Whalebridge needs \(required).x. "
                + "Whalebridge can download the signed installer from Apple's GitHub releases and open it for you."
        default:
            alert.informativeText =
                "Containers run on Apple's open-source container runtime, which isn't installed yet. "
                + "Whalebridge can download the signed installer from Apple's GitHub releases and open it for you."
        }
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await installRuntime() }
        }
    }

    func copyDockerHost() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("export DOCKER_HOST=\(dockerHost)", forType: .string)
    }

    func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }

    private func daemonDidExit(status: Int32) {
        process = nil
        state = stopRequested ? .stopped : .failed("Whalebridge exited (code \(status)) — see log")
    }

    private func refreshContextStatus() {
        let current = DockerContext.isDefault
        if current != isDefaultContext {
            isDefaultContext = current
        }
    }

    private func refreshApiserverStatus() async {
        guard containerCLIInstalled else {
            apiserverRunning = false
            return
        }
        let result = await Shell.run(containerCLI, ["system", "status"])
        apiserverRunning = result.status == 0 && !result.output.contains("not running")
    }

    private func makeLogHandle() -> FileHandle? {
        let fm = FileManager.default
        let dir = logFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
