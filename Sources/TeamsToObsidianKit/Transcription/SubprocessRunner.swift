import Foundation

struct SubprocessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

/// Runs a child process with a hard timeout, draining stdout/stderr so the
/// child can never block on a full pipe.
enum SubprocessRunner {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    captureStdout: Bool = false) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Foundation.Process()
            process.executableURL = executable
            process.arguments = arguments

            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe

            let stderrCollector = DataCollector()
            let stdoutCollector = DataCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrCollector.append(handle.availableData)
            }
            // Always drained; only kept when the caller wants it.
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if captureStdout {
                    stdoutCollector.append(data)
                }
            }

            let state = RunState(continuation: continuation)

            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? stderrPipe.fileHandleForReading.readToEnd() {
                    stderrCollector.append(rest)
                }
                if captureStdout, let rest = try? stdoutPipe.fileHandleForReading.readToEnd() {
                    stdoutCollector.append(rest)
                }
                state.finish(.success(SubprocessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutCollector.string(),
                    stderr: stderrCollector.string(),
                    timedOut: state.timedOutFlag)))
            }

            do {
                try process.run()
            } catch {
                state.finish(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    // Lock-protected; safe to touch from the pipe, termination, and timeout callbacks.
    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ d: Data) {
            guard !d.isEmpty else { return }
            lock.lock(); data.append(d); lock.unlock()
        }

        func string() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // Lock-protected; safe to touch from the pipe, termination, and timeout callbacks.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SubprocessResult, Error>?
        private var timedOut = false

        init(continuation: CheckedContinuation<SubprocessResult, Error>) {
            self.continuation = continuation
        }

        var timedOutFlag: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }

        func finish(_ result: Result<SubprocessResult, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            switch result {
            case .success(let value): c?.resume(returning: value)
            case .failure(let error): c?.resume(throwing: error)
            }
        }
    }
}
