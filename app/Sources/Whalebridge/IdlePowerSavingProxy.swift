import Foundation
import Network

/// Power saving's front door: when enabled, this — not socktainer — owns
/// DaemonManager's public socket path permanently, for the app's whole
/// lifetime. socktainer itself binds a separate internal path
/// (patches/0003-configurable-socket-path.patch) that only this proxy talks
/// to directly.
///
/// Every connection is relayed through for its full lifetime (not just
/// handed off after the first one) — that's what lets this notice ongoing
/// activity and know when it's actually safe to idle the daemons back down,
/// not just when to wake them.
@MainActor
final class IdlePowerSavingProxy {
    private unowned let daemon: DaemonManager
    private var listener: NWListener?
    private var activeConnections = 0
    private var lastActivity = Date()
    private var idleCheckTask: Task<Void, Never>?

    private var internalSocketPath: String {
        NSHomeDirectory() + "/.socktainer/container.internal.sock"
    }

    init(daemon: DaemonManager) {
        self.daemon = daemon
    }

    func start() {
        guard listener == nil else { return }
        // On a genuinely fresh install, power saving can be the very first
        // thing that ever touches ~/.socktainer — socktainer itself
        // normally creates that directory (SocketUtility.swift's
        // restrictDirectoryToOwner) on its own first run, but here it may
        // never have run at all yet, so bind() would fail against a
        // nonexistent parent directory. Same 0700 permissions socktainer
        // itself uses.
        try? FileManager.default.createDirectory(
            atPath: (daemon.socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A Unix domain socket bind() fails with "Address already in use"
        // against a stale file left by any previous listener at this path
        // (this app's last run, or a pre-power-saving socktainer that bound
        // it directly) — allowLocalEndpointReuse only covers reuse across
        // this process's own listeners, not an on-disk leftover from a dead
        // one, so it has to be removed first (same as socktainer's own
        // prepareUnixSocket in SocketUtility.swift).
        try? FileManager.default.removeItem(atPath: daemon.socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: daemon.socketPath)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            NSLog("IdlePowerSavingProxy: failed to bind \(daemon.socketPath)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [socketPath = daemon.socketPath] state in
            switch state {
            case .ready:
                // Same as socktainer's own openUnixSocketToAllUsers: the
                // guest-side docker.sock relay needs this world-writable to
                // connect, and bind() creates the file 0600 by default.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o666], ofItemAtPath: socketPath)
            case .failed(let error):
                NSLog("IdlePowerSavingProxy: listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        scheduleIdleCheck()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        idleCheckTask?.cancel()
        idleCheckTask = nil
    }

    private func accept(_ client: NWConnection) async {
        lastActivity = Date()
        activeConnections += 1
        client.start(queue: .main)

        switch daemon.state {
        case .sleeping:
            await daemon.wakeFromIdle()
        case .starting, .waking:
            // A wake this connection didn't trigger is already in flight —
            // start() coalesces onto it, so wait for the daemon to come up
            // rather than dropping a client that arrived a few ms too late.
            await daemon.start()
        case .restarting:
            // A crash relaunch is counting down and a real client is waiting on
            // it — try now rather than making them sit out the backoff. start()
            // keeps the retry budget, so this can't turn into a spawn loop.
            await daemon.start()
        default:
            break
        }
        // Nothing to proxy to if the wake attempt didn't land on .running
        // (e.g. the runtime isn't installed, or the daemon binary is
        // missing) — close rather than hang the client waiting forever.
        guard daemon.state == .running else {
            client.cancel()
            connectionClosed()
            return
        }

        let backendParams = NWParameters()
        backendParams.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let backend = NWConnection(to: .unix(path: internalSocketPath), using: backendParams)
        backend.start(queue: .main)

        Self.relay(
            client, backend,
            onActivity: { [weak self] in self?.lastActivity = Date() },
            onClose: { [weak self] in self?.connectionClosed() })
    }

    private func connectionClosed() {
        activeConnections -= 1
        lastActivity = Date()
    }

    /// Relays bytes both ways between two started connections, then cancels
    /// both and calls `onClose` exactly once — when both directions have
    /// reached end-of-stream, or as soon as either side errors or fails.
    ///
    /// A clean end-of-stream in one direction is passed on as a half-close
    /// rather than tearing the pair down: the Docker CLI shuts its write
    /// side right after an exec's `101 Switching Protocols` when it has no
    /// stdin to send, and still reads the exec's output afterwards (#26).
    /// A peer that's actually gone, rather than just done writing, moves its
    /// connection to `.failed`, which still closes the pair straight away,
    /// so a killed client doesn't hold the daemons awake.
    static func relay(
        _ client: NWConnection, _ backend: NWConnection,
        onActivity: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        var closed = false
        var openDirections = 2
        let close: @MainActor () -> Void = {
            guard !closed else { return }
            closed = true
            client.cancel()
            backend.cancel()
            onClose()
        }
        let finished: @MainActor () -> Void = {
            openDirections -= 1
            if openDirections == 0 { close() }
        }

        for connection in [client, backend] {
            connection.stateUpdateHandler = { state in
                guard case .failed = state else { return }
                Task { @MainActor in close() }
            }
        }
        pump(from: client, to: backend, onActivity: onActivity, onFinished: finished, onError: close)
        pump(from: backend, to: client, onActivity: onActivity, onFinished: finished, onError: close)
    }

    /// Recursively relays from `from` to `to`, forwarding whatever bytes each
    /// read yields before checking for completion — a half-close shouldn't
    /// drop a final chunk of data. On a clean end-of-stream, half-closes `to`
    /// and stops.
    private static func pump(
        from: NWConnection, to: NWConnection,
        onActivity: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor () -> Void
    ) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { @MainActor in
                onActivity()
                if let data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { error in
                        guard error != nil else { return }
                        Task { @MainActor in onError() }
                    })
                }
                if error != nil {
                    onError()
                    return
                }
                if isComplete {
                    to.send(
                        content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
                    onFinished()
                    return
                }
                pump(from: from, to: to, onActivity: onActivity, onFinished: onFinished, onError: onError)
            }
        }
    }

    private func scheduleIdleCheck() {
        idleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                await self.checkIdle()
            }
        }
    }

    private func checkIdle() async {
        guard daemon.state == .running, activeConnections == 0 else { return }
        let idleMinutes = Date().timeIntervalSince(lastActivity) / 60
        guard idleMinutes >= AppSettings.shared.idleTimeoutMinutes else { return }
        await daemon.stopForIdle()
    }
}
