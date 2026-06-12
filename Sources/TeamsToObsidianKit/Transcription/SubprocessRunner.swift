import Foundation

struct SubprocessResult {
    let exitCode: Int32
    let stderr: String
    let timedOut: Bool
}

/// Runs a child process with a hard timeout, draining stdout/stderr so the
/// child can never block on a full pipe.
enum SubprocessRunner {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Foundation.Process()
            process.executableURL = executable
            process.arguments = arguments

            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe

            let collector = DataCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            // stdout is discarded but must still be drained.
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            let state = RunState(continuation: continuation)

            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? stderrPipe.fileHandleForReading.readToEnd() {
                    collector.append(rest)
                }
                state.finish(.success(SubprocessResult(
                    exitCode: proc.terminationStatus,
                    stderr: collector.string(),
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

    private final class DataCollector {
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

    private final class RunState {
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
