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

public enum ProcessStreamEvent: Equatable, Sendable {
    case stdoutLine(String)
    case stderrLine(String)
    case exited(Int32)
}

public protocol ProcessStreaming: Sendable {
    func stream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error>
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try stdinPipe.fileHandleForWriting.close()

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

public struct SubprocessStreamRunner: ProcessStreaming {
    public init() {}

    public func stream(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = StreamingProcessState(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                continuation: continuation
            )

            continuation.onTermination = { @Sendable _ in
                state.terminate()
            }

            state.start()
        }
    }
}

private final class StreamingProcessState: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let workingDirectory: URL?
    private let continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation
    private let process = Process()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "agentctl.streaming-process", attributes: .concurrent)

    init(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.continuation = continuation
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            continuation.finish(throwing: error)
            return
        }

        group.enter()
        queue.async {
            self.readLines(from: stdoutPipe.fileHandleForReading) { line in
                self.continuation.yield(.stdoutLine(line))
            }
            self.group.leave()
        }

        group.enter()
        queue.async {
            self.readLines(from: stderrPipe.fileHandleForReading) { line in
                self.continuation.yield(.stderrLine(line))
            }
            self.group.leave()
        }

        queue.async {
            self.process.waitUntilExit()
            self.group.wait()
            self.continuation.yield(.exited(self.process.terminationStatus))
            self.continuation.finish()
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func readLines(from handle: FileHandle, emit: (String) -> Void) {
        var buffer = Data()
        let newline = Data([0x0A])

        while true {
            let data = handle.availableData
            if data.isEmpty {
                break
            }

            buffer.append(data)

            while let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                emit(String(decoding: lineData, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            }
        }

        if !buffer.isEmpty {
            emit(String(decoding: buffer, as: UTF8.self))
        }
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
