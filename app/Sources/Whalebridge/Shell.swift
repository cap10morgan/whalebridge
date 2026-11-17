import Foundation

enum Shell {
    /// Run a command and capture combined stdout/stderr. Never throws; a
    /// launch failure is reported as status -1. Cancelling the calling task
    /// terminates the command, which then reports its signal status.
    static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        let launch = Launch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: (-1, error.localizedDescription))
                        return
                    }
                    launch.started(process)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, output))
                }
            }
        } onCancel: {
            launch.cancel()
        }
    }

    /// Hands a launched process to a cancellation that may arrive before or
    /// after the launch, from another thread.
    private final class Launch: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ process: Process) {
            let cancelled = lock.withLock {
                self.process = process
                return self.cancelled
            }
            if cancelled { process.terminate() }
        }

        func cancel() {
            let process = lock.withLock {
                cancelled = true
                return self.process
            }
            if let process, process.isRunning { process.terminate() }
        }
    }
}
