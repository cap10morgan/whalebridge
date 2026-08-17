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

        if daemon.state == .sleeping {
            await daemon.wakeFromIdle()
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

        var closed = false
        let closeOnce: @MainActor () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            client.cancel()
            backend.cancel()
            self?.connectionClosed()
        }

        pump(from: client, to: backend, onClose: closeOnce)
        pump(from: backend, to: client, onClose: closeOnce)
    }

    private func connectionClosed() {
        activeConnections -= 1
        lastActivity = Date()
    }

    /// Recursively relays from `from` to `to` until either side closes or
    /// errors, forwarding whatever bytes each read yields before checking
    /// for completion — a half-close shouldn't drop a final chunk of data.
    private func pump(from: NWConnection, to: NWConnection, onClose: @escaping @MainActor () -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.lastActivity = Date()
                if let data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { _ in })
                }
                if isComplete || error != nil {
                    onClose()
                    return
                }
                self?.pump(from: from, to: to, onClose: onClose)
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
