import AppKit
import Foundation

/// A minimal HTTP/1.0 client for socktainer's unix socket — URLSession can't
/// speak unix sockets, and 1.0 keeps the response close-delimited so parsing
/// stays trivial (with a fallback dechunker in case the server insists).
enum UnixHTTP {
    struct Response {
        let status: Int
        let body: Data
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Connect to a unix socket, with send/receive timeouts so a wedged daemon
    /// can't hang the caller. Caller closes the returned descriptor.
    static func connect(_ socketPath: String, timeoutSeconds: Int = 5) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket() failed") }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw Failure("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { path in
            path.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = strlcpy(dst, socketPath, capacity)
            }
        }
        let connected = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure("connect failed: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    static func request(_ method: String, _ path: String, socket socketPath: String) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try requestSync(method, path, socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func requestSync(_ method: String, _ path: String, _ socketPath: String) throws -> Response {
        let fd = try connect(socketPath)
        defer { close(fd) }

        let request = "\(method) \(path) HTTP/1.0\r\nHost: whalebridge\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else { throw Failure("send failed") }

        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { raw.append(buffer, count: n) } else { break }
        }

        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw Failure("malformed HTTP response")
        }
        let head = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        guard let statusToken = head.split(separator: " ").dropFirst().first,
            let status = Int(statusToken)
        else { throw Failure("malformed status line") }

        var body = raw[headerEnd.upperBound...]
        if head.lowercased().contains("transfer-encoding: chunked") {
            body = dechunk(body)
        }
        return Response(status: status, body: Data(body))
    }

    static func dechunk(_ chunked: Data.SubSequence) -> Data.SubSequence {
        var out = Data()
        var rest = chunked
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeLine = String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = rest.index(start, offsetBy: size, limitedBy: rest.endIndex) else { break }
            out.append(rest[start..<end])
            rest = rest[end...].dropFirst(2)  // trailing \r\n
        }
        return out[...]
    }
}

/// One row of GET /containers/json — the same names and states `docker ps` shows.
struct ContainerSummary: Decodable, Identifiable, Equatable {
    let id: String
    let names: [String]
    let image: String
    let state: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status"
    }

    /// Docker reports names with a leading slash.
    var name: String {
        names.first.map { String($0.dropFirst()) } ?? String(id.prefix(12))
    }
    var isRunning: Bool { state == "running" }
}

/// Polls the daemon's Docker API for the menu's container list and runs the
/// per-container actions through the same API, so what we show and do always
/// matches what `docker ps` would say.
@MainActor
final class ContainerStore: ObservableObject {
    static let shared = ContainerStore()

    @Published private(set) var running: [ContainerSummary] = []
    @Published private(set) var stopped: [ContainerSummary] = []

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        let daemon = DaemonManager.shared
        guard daemon.state == .running else {
            running = []
            stopped = []
            return
        }
        guard
            let response = try? await UnixHTTP.request(
                "GET", "/containers/json?all=1", socket: daemon.socketPath),
            response.status == 200,
            let all = try? JSONDecoder().decode([ContainerSummary].self, from: response.body)
        else { return }  // transient failure — keep the last good list

        let sorted = all.sorted { $0.name < $1.name }
        running = sorted.filter(\.isRunning)
        stopped = sorted.filter { !$0.isRunning }
    }

    func start(_ container: ContainerSummary) async {
        await perform("POST", "/containers/\(container.id)/start")
    }

    func stop(_ container: ContainerSummary) async {
        await perform("POST", "/containers/\(container.id)/stop")
    }

    func restart(_ container: ContainerSummary) async {
        await perform("POST", "/containers/\(container.id)/restart")
    }

    func remove(_ container: ContainerSummary) async {
        await perform("DELETE", "/containers/\(container.id)")
    }

    func copyName(_ container: ContainerSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(container.name, forType: .string)
    }

    private func perform(_ method: String, _ path: String) async {
        _ = try? await UnixHTTP.request(method, path, socket: DaemonManager.shared.socketPath)
        await refresh()
    }
}
