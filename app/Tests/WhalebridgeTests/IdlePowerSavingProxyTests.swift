import Foundation
import Network
import Testing

@testable import Whalebridge

/// `IdlePowerSavingProxy.relay` sits between every Docker client and
/// socktainer under power saving, so it has to pass half-closes through the
/// way a direct connection would.
@Suite @MainActor struct IdlePowerSavingProxyRelayTests {
    /// The `docker exec` case from #26: the CLI half-closes right after the
    /// upgrade, and socktainer only writes the exec's output after that.
    @Test func halfClosedClientStillReceivesBackendOutput() async throws {
        let backend = try await listen { connection in
            readToEnd(connection) {
                connection.send(content: Data("hi\n".utf8), completion: .contentProcessed { _ in })
                connection.send(
                    content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in })
            }
        }
        var closes = 0
        let proxy = try await proxy(to: backend.path) { closes += 1 }

        let received = try await Task.detached {
            try UnixClient.exchange(path: proxy.path, send: "req", then: .halfClose)
        }.value

        #expect(received == "hi\n")
        #expect(await eventually { closes == 1 })
        backend.listener.cancel()
        proxy.listener.cancel()
    }

    /// A client that's actually gone (not just done writing), like a
    /// Ctrl-C'd `docker logs -f`, still closes the pair right away, even
    /// with a backend that's gone quiet without closing, so it can't keep the
    /// daemons awake.
    @Test func disconnectedClientClosesPairWithoutWaitingOnBackend() async throws {
        let backend = try await listen { connection in
            connection.send(content: Data("hi\n".utf8), completion: .contentProcessed { _ in })
        }
        var closes = 0
        let proxy = try await proxy(to: backend.path) { closes += 1 }

        let received = try await Task.detached {
            try UnixClient.exchange(path: proxy.path, send: "req", then: .close)
        }.value

        #expect(received == "hi\n")
        #expect(await eventually { closes == 1 })
        backend.listener.cancel()
        proxy.listener.cancel()
    }

    // MARK: - Helpers

    private struct Listening {
        let listener: NWListener
        let path: String
    }

    /// A Unix socket listener on a fresh temp path, handing each started
    /// connection to `handler`, returned once it's accepting connections.
    private func listen(_ handler: @escaping @MainActor (NWConnection) -> Void) async throws -> Listening {
        let path = NSTemporaryDirectory() + "wb-\(UUID().uuidString.prefix(8)).sock"
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                handler(connection)
            }
        }
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                listener.stateUpdateHandler = nil
                continuation.resume()
            }
            listener.start(queue: .main)
        }
        return Listening(listener: listener, path: path)
    }

    /// A listener relaying each connection to the socket at `backendPath`,
    /// the way the proxy does once the daemon is running.
    private func proxy(to backendPath: String, onClose: @escaping @MainActor () -> Void) async throws -> Listening {
        try await listen { client in
            let params = NWParameters()
            params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
            let backend = NWConnection(to: .unix(path: backendPath), using: params)
            backend.start(queue: .main)
            IdlePowerSavingProxy.relay(client, backend, onActivity: {}, onClose: onClose)
        }
    }

    private func readToEnd(_ connection: NWConnection, then done: @escaping @MainActor () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, isComplete, error in
            MainActor.assumeIsolated {
                if isComplete || error != nil {
                    done()
                } else {
                    readToEnd(connection, then: done)
                }
            }
        }
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// A plain blocking BSD-socket client, so the test can half-close with
/// `shutdown(SHUT_WR)` exactly as the Docker CLI does.
private enum UnixClient {
    enum Ending { case halfClose, close }

    struct Failure: Error { let call: String }

    /// Connects to `path` and writes `send`. Then either half-closes and
    /// reads until EOF, or reads one chunk and fully closes. Returns what
    /// was read.
    static func exchange(path: String, send: String, then ending: Ending) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure(call: "connect") }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.send(fd, send, send.utf8.count, 0) == send.utf8.count else { throw Failure(call: "send") }

        if ending == .halfClose { shutdown(fd, SHUT_WR) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n >= 0 else { throw Failure(call: "recv") }
            received.append(contentsOf: buffer[..<n])
            if n == 0 || ending == .close { return String(decoding: received, as: UTF8.self) }
        }
    }
}
