import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool {
        exitCode == 0
    }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult
}

public enum ProcessRunnerError: Error, CustomStringConvertible, Sendable {
    case nonUTF8Output

    public var description: String {
        switch self {
        case .nonUTF8Output:
            return "process emitted non-UTF8 output"
        }
    }
}

public struct SubprocessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard
            let stdout = String(data: stdoutData, encoding: .utf8),
            let stderr = String(data: stderrData, encoding: .utf8)
        else {
            throw ProcessRunnerError.nonUTF8Output
        }

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public struct GitRunner: Sendable {
    private let runner: ProcessRunning
    private let gitExecutable: String

    public init(runner: ProcessRunning = SubprocessRunner(), gitExecutable: String = "/usr/bin/env") {
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    public func run(_ arguments: [String], workingDirectory: URL?) throws -> ProcessResult {
        try runner.run(gitExecutable, arguments: ["git"] + arguments, workingDirectory: workingDirectory)
    }
}
