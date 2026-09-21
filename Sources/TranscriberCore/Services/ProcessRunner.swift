import Foundation

public enum ProcessRunnerError: Error, LocalizedError {
    case executableMissing(String)
    case launchFailed(String)
    case nonZeroExit(executable: String, code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Missing executable: \(path)"
        case .launchFailed(let message):
            return "Process launch failed: \(message)"
        case .nonZeroExit(let executable, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(executable) exited with code \(code)."
            }
            return "\(executable) exited with code \(code): \(trimmed)"
        }
    }
}

public struct ProcessResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
}

public final class ProcessRunner {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        forwardOutput: Bool = false
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunnerError.executableMissing(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = LockedProcessOutput()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            output.appendStdout(data)
            if forwardOutput {
                FileHandle.standardOutput.write(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            output.appendStderr(data)
            if forwardOutput {
                FileHandle.standardError.write(data)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    output.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    output.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                    let result = output.result(exitCode: finishedProcess.terminationStatus)
                    if result.exitCode == 0 {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(
                            throwing: ProcessRunnerError.nonZeroExit(
                                executable: executableURL.lastPathComponent,
                                code: result.exitCode,
                                stderr: result.stderr
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        append(data, to: &stdout)
    }

    func appendStderr(_ data: Data) {
        append(data, to: &stderr)
    }

    func result(exitCode: Int32) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }

        return ProcessResult(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    private func append(_ data: Data, to destination: inout Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        destination.append(data)
        lock.unlock()
    }
}
