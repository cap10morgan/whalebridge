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
        /// Recovering from an unexpected daemon exit — the automatic relaunch
        /// is either counting down or already under way.
        case restarting

        var label: String {
            switch self {
            case .stopped: "stopped"
            case .starting: "starting…"
            case .running: "running"
            case .waitingForRuntime: "waiting for Apple container runtime"
            case .failed(let reason): "failed — \(reason)"
            case .restarting: "restarting after crash…"
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
    /// True while Whalebridge itself is starting or restarting Apple's
    /// container services — the menu bar icon animates through it.
    @Published private(set) var apiserverTransitioning = false
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

    /// Where socktainer listens; Docker clients, DockerContext and dockerHost
    /// all point here.
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
    /// A child we've asked to exit but haven't confirmed dead yet. Held so the
    /// next start() waits it out instead of racing it for the socket.
    private var terminatingPID: Int32?
    private var relaunchTask: Task<Void, Never>?
    private var relaunchAttempts = 0
    private var lastDaemonStart = Date.distantPast

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
        // Left behind by the since-removed power saving mode, where socktainer
        // listened here behind a proxy that owned `socketPath`.
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.socktainer/container.internal.sock")
        await start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.refreshRuntimeStatus()
                await self.refreshApiserverStatus()
                self.refreshContextStatus()
                // Apple's services can stop independently of socktainer (their
                // own crash, or a `container system stop` from a shell), which
                // leaves our daemon up but answering nothing. Relaunching on a
                // crash has to cover both halves, not just ours.
                if self.state == .running, !self.apiserverRunning, !self.apiserverTransitioning {
                    NSLog("apple/container services stopped under a running daemon — restarting")
                    await self.startApiserver()
                }
                // runtime appeared (user finished Installer.app) — start the daemon
                if case .compatible = self.runtimeStatus, self.state == .waitingForRuntime {
                    await self.start()
                }
            }
        }
        if runtimeStatus.needsInstall {
            // A newer Whalebridge may need a newer runtime than this build
            // does, so installing ours first would be wasted effort. Offer the
            // update instead; the updated app makes its own runtime offer.
            if await Updater.shared.offerAvailableUpdate() { return }
            // They may have installed the runtime by hand while deciding.
            if runtimeStatus.needsInstall { offerRuntimeInstall() }
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
        guard result.output.contains("socktainer") else { return }
        kill(pid, SIGTERM)
        await waitForExit(pid: pid)
    }

    /// SIGTERM only *asks* a process to exit, and socktainer holds its socket
    /// bound until it actually does. Starting the replacement before then is
    /// what makes the new daemon lose the race to bind and die on EEXIST, so
    /// every teardown path waits here before a new daemon spawns.
    private func waitForExit(pid: Int32, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Wouldn't go quietly. SIGKILL can't be caught, so this always lands.
        kill(pid, SIGKILL)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Concurrent callers must never each spawn a daemon. Checking `state`
    /// can't prevent that on its own: this class is @MainActor, but the actor
    /// is released at every `await` in the startup path, so two tasks that
    /// both pass the guard before the first suspension point will both go on
    /// to run a daemon. That is exactly how two socktainers end up racing to
    /// bind the same socket — the loser dies on EEXIST and overwrites the
    /// pidfile on its way out, orphaning the winner. Funnel every caller
    /// through one Task so latecomers await the in-flight start instead of
    /// beginning a second one.
    private var startTask: Task<Void, Never>?

    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        guard state != .running, state != .starting else { return }
        // A start that didn't come from the relaunch ladder (menu Start, the
        // runtime finally appearing) is a fresh intent — give it the whole
        // retry budget, not the tail of an old streak.
        if state != .restarting { relaunchAttempts = 0 }
        // Claim the transition synchronously, before the first `await` below,
        // so anything checking `state` while this start is suspended sees a
        // start already under way.
        state = .starting
        // A relaunch still counting down would spawn a second daemon once this
        // one finishes. The relaunch task clears this itself immediately before
        // calling start(), so cancelling here can never hit the very task we
        // are being called from.
        relaunchTask?.cancel()
        relaunchTask = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart() async {
        guard let daemonURL, FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            state = .failed("Whalebridge binary not found")
            return
        }
        await refreshRuntimeStatus()
        guard case .compatible(let version) = runtimeStatus else {
            state = .waitingForRuntime
            return
        }
        stopRequested = false
        await reapOrphanedDaemon()
        // Our own child from a stop() may still be on its way out.
        if let pid = terminatingPID {
            await waitForExit(pid: pid)
            terminatingPID = nil
        }

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
        await ensureDefaultKernel()

        let daemon = Process()
        daemon.executableURL = daemonURL
        daemon.arguments = ["--no-docker-context"]
        let env = [
            // Brand `docker version` output (patches/0001-brandable-platform-name.patch).
            "SOCKTAINER_PLATFORM_NAME": "Whalebridge",
            "SOCKTAINER_PLATFORM_VERSION": AppVersion.current,
            // Default memory limit for containers that don't request their own
            // (patches/0002-create-conflict-and-default-memory.patch),
            // configurable in Settings.
            "SOCKTAINER_DEFAULT_MEMORY_PERCENT": "\(AppSettings.shared.defaultContainerMemoryPercent)",
        ]
        daemon.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
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
            lastDaemonStart = Date()
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
        relaunchTask?.cancel()
        relaunchTask = nil
        relaunchAttempts = 0
        terminatingPID = process?.processIdentifier
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: pidFileURL)
        state = .stopped
    }

    func startApiserver() async {
        guard containerCLIInstalled else { return }
        apiserverTransitioning = true
        defer { apiserverTransitioning = false }
        // Without --enable-kernel-install, `system start` prompts on stdin
        // before installing a missing default kernel; with no terminal
        // attached that reads as "no", leaving a fresh apple/container
        // install unable to create any container. A no-op when one exists.
        let result = await Shell.run(containerCLI, ["system", "start", "--enable-kernel-install"])
        if result.status != 0 {
            NSLog("container system start exited \(result.status): \(result.output)")
        }
        await refreshApiserverStatus()
    }

    /// Installs Apple's recommended default kernel when none is configured.
    /// `startApiserver` covers this for services we start ourselves, but the
    /// apiserver may already be running without one (started from a shell,
    /// or by an older Whalebridge), and then every container create fails
    /// with "default kernel not configured". apple/container has no command
    /// that reports the default kernel, so check for its file in the
    /// apiserver's app root.
    nonisolated static func defaultKernelPath(statusOutput: String, architecture: String) -> String? {
        guard let line = statusOutput.split(separator: "\n").first(where: { $0.hasPrefix("paths.appRoot") }) else {
            return nil
        }
        let appRoot = line.dropFirst("paths.appRoot".count).trimmingCharacters(in: .whitespaces)
        guard !appRoot.isEmpty else { return nil }
        return URL(fileURLWithPath: appRoot).appending(path: "kernels/default.kernel-\(architecture)").path
    }

    private func ensureDefaultKernel() async {
        let status = await Shell.run(containerCLI, ["system", "status"])
        guard status.status == 0,
            let path = DaemonManager.defaultKernelPath(statusOutput: status.output, architecture: "arm64")
        else { return }
        guard !FileManager.default.fileExists(atPath: path) else { return }
        NSLog("no default kernel configured — installing the recommended one")
        let result = await Shell.run(containerCLI, ["system", "kernel", "set", "--recommended"])
        if result.status != 0 {
            NSLog("container system kernel set exited \(result.status): \(result.output)")
        }
    }

    /// `container system stop` on an already-stopped service is a harmless
    /// no-op, so this is safe to call whenever the running apiserver's
    /// version is in doubt.
    private func stopApiserver() async {
        apiserverTransitioning = true
        defer { apiserverTransitioning = false }
        let result = await Shell.run(containerCLI, ["system", "stop"])
        if result.status != 0 {
            NSLog("container system stop exited \(result.status): \(result.output)")
        }
        await refreshApiserverStatus()
    }

    private func restartApiserver() async {
        await stopApiserver()
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

    /// Picks the highest patch tag matching `majorMinor` (e.g. "1.2") from a
    /// list of apple/container release tag names. Pure so the selection logic
    /// is testable without a network call; matches exact `major.minor.patch`
    /// tags only — pre-release suffixes (e.g. "1.2.1-rc1") fail the `Int(...)`
    /// parse and are correctly excluded.
    nonisolated static func bestPatchTag(from tagNames: [String], majorMinor: String) -> String? {
        let prefix = "\(majorMinor)."
        let matches: [(patch: Int, tag: String)] = tagNames.compactMap { name in
            guard name.hasPrefix(prefix), let patch = Int(name.dropFirst(prefix.count)) else { return nil }
            return (patch, name)
        }
        return matches.max(by: { $0.patch < $1.patch })?.tag
    }

    /// The newest available patch for the major.minor socktainer requires, so
    /// installs/upgrades always land on the latest apple/container patch
    /// instead of the exact version baked in at build time (which only bumps
    /// when we vendor a new socktainer). Same-minor patches are ABI-compatible
    /// by Apple's own versioning, so falling back to the baked-in exact
    /// version on any failure (offline, rate-limited, malformed response) is
    /// always a safe, working choice — never blocks the install on this call.
    private func latestPatchVersion() async -> String {
        let fallback = requiredContainerVersion
        guard let url = URL(string: "https://api.github.com/repos/apple/container/tags?per_page=100") else {
            return fallback
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return fallback }
            struct Tag: Decodable { let name: String }
            let tags = try JSONDecoder().decode([Tag].self, from: data)
            return DaemonManager.bestPatchTag(from: tags.map(\.name), majorMinor: requiredMajorMinor) ?? fallback
        } catch {
            return fallback
        }
    }

    /// Download the signed apple/container installer, verify Apple's signature,
    /// and hand it to Installer.app (which owns the admin-privileges prompt).
    func installRuntime() async {
        guard installProgress == nil else { return }
        installError = nil
        installProgress = "Checking for the latest apple/container release…"
        let version = await latestPatchVersion()
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
            // Cooperative activation: an app can only bring another to the
            // front by being active and yielding to it. By the time the
            // download finishes, this menu bar app long since lost focus, so
            // a plain open() left Installer's window buried behind everything
            // and the install looked like it silently did nothing.
            NSApp.activate()
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.installer")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if let installer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.installer") {
                _ = try await NSWorkspace.shared.open([dest], withApplicationAt: installer, configuration: configuration)
            } else {
                NSWorkspace.shared.open(dest)
            }
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
        if stopRequested {
            state = .stopped
            return
        }
        // The app is on its way out; don't fight it by starting a new daemon.
        guard !isTerminating else {
            state = .stopped
            return
        }
        scheduleRelaunch(afterExitCode: status)
    }

    /// How long a daemon must survive for its run to count as healthy. Past
    /// this, the next crash starts a fresh retry budget rather than inheriting
    /// the streak from some earlier bad patch.
    private let healthyRunSeconds: TimeInterval = 60
    private let maxRelaunchAttempts = 5

    /// An unexpected exit used to land in .failed and sit there until someone
    /// happened to look at the menu bar. Bring the daemon back on its own
    /// instead, widening the delay as attempts repeat so a daemon that dies on
    /// every launch (missing runtime, corrupt install) settles into .failed
    /// instead of becoming a spawn loop.
    private func scheduleRelaunch(afterExitCode status: Int32) {
        if Date().timeIntervalSince(lastDaemonStart) >= healthyRunSeconds {
            relaunchAttempts = 0
        }
        guard relaunchAttempts < maxRelaunchAttempts else {
            NSLog("socktainer exited (code \(status)); giving up after \(relaunchAttempts) relaunches")
            state = .failed("Whalebridge exited (code \(status)) — see log")
            return
        }
        relaunchAttempts += 1
        let attempt = relaunchAttempts
        let delay = min(pow(2, Double(attempt - 1)), 30)
        state = .restarting
        NSLog("socktainer exited (code \(status)) — relaunch \(attempt)/\(maxRelaunchAttempts) in \(delay)s")
        relaunchTask?.cancel()
        relaunchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Cleared before start() so start()'s own cancel can't target the
            // task that is running this very closure.
            self.relaunchTask = nil
            await self.start()
        }
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
