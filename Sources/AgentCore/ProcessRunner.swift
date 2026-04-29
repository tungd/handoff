import Darwin
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

    func controlledStream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) -> ProcessStreamSession
}

public struct ProcessStreamSession: Sendable {
    public var events: AsyncThrowingStream<ProcessStreamEvent, Error>
    public var control: ProcessStreamControl?

    public init(events: AsyncThrowingStream<ProcessStreamEvent, Error>, control: ProcessStreamControl? = nil) {
        self.events = events
        self.control = control
    }
}

public final class ProcessStreamControl: @unchecked Sendable {
    private let sendData: @Sendable (Data) throws -> Void
    private let closeInput: @Sendable () throws -> Void
    private let terminateProcess: @Sendable () -> Void

    public init(
        sendData: @escaping @Sendable (Data) throws -> Void,
        closeInput: @escaping @Sendable () throws -> Void = {},
        terminate: @escaping @Sendable () -> Void = {}
    ) {
        self.sendData = sendData
        self.closeInput = closeInput
        self.terminateProcess = terminate
    }

    public func send(_ data: Data) throws {
        try sendData(data)
    }

    public func closeStdin() throws {
        try closeInput()
    }

    public func terminate() {
        terminateProcess()
    }
}

public extension ProcessStreaming {
    func controlledStream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) -> ProcessStreamSession {
        ProcessStreamSession(events: stream(executable, arguments: arguments, workingDirectory: workingDirectory))
    }
}

public protocol InteractiveProcess: Sendable {
    var events: AsyncThrowingStream<ProcessStreamEvent, Error> { get }

    func sendLine(_ line: String) throws
    func closeStdin() throws
    func terminate()
}

public protocol ProcessInteracting: Sendable {
    func start(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) throws -> any InteractiveProcess
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
        startStream(
            executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            closeStdinOnStart: true
        ).events
    }

    public func controlledStream(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> ProcessStreamSession {
        startStream(
            executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            closeStdinOnStart: false
        )
    }

    private func startStream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?,
        closeStdinOnStart: Bool
    ) -> ProcessStreamSession {
        let stream = AsyncThrowingStream.makeStream(of: ProcessStreamEvent.self, throwing: Error.self)
        let state = StreamingProcessState(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            continuation: stream.continuation
        )
        let control = ProcessStreamControl(
            sendData: { data in try state.send(data) },
            closeInput: { try state.closeStdin() },
            terminate: { state.terminate() }
        )

        stream.continuation.onTermination = { @Sendable _ in
            state.terminate()
        }

        state.start(closeStdinOnStart: closeStdinOnStart)
        return ProcessStreamSession(events: stream.stream, control: control)
    }
}

public struct SubprocessPTYStreamRunner: ProcessStreaming {
    public init() {}

    public func stream(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        controlledStream(executable, arguments: arguments, workingDirectory: workingDirectory).events
    }

    public func controlledStream(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> ProcessStreamSession {
        let stream = AsyncThrowingStream.makeStream(of: ProcessStreamEvent.self, throwing: Error.self)
        let state = PTYProcessState(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            continuation: stream.continuation
        )
        let control = ProcessStreamControl(
            sendData: { data in try state.send(data) },
            closeInput: { try state.closeInput() },
            terminate: { state.terminate() }
        )

        stream.continuation.onTermination = { @Sendable _ in
            state.terminate()
        }

        state.start()
        return ProcessStreamSession(events: stream.stream, control: control)
    }
}

public struct SubprocessInteractiveRunner: ProcessInteracting {
    public init() {}

    public func start(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) throws -> any InteractiveProcess {
        try SubprocessInteractiveProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}

private final class StreamingProcessState: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let workingDirectory: URL?
    private let continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdinLock = NSLock()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "agentctl.streaming-process", attributes: .concurrent)
    private var stdinClosed = false

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

    func start(closeStdinOnStart: Bool) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            if closeStdinOnStart {
                try closeStdin()
            }
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

    func send(_ data: Data) throws {
        try stdinLock.withLock {
            guard !stdinClosed else {
                return
            }
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func closeStdin() throws {
        try stdinLock.withLock {
            guard !stdinClosed else {
                return
            }
            stdinClosed = true
            try stdinPipe.fileHandleForWriting.close()
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

private final class PTYProcessState: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let workingDirectory: URL?
    private let continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation
    private let process = Process()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "agentctl.pty-process", attributes: .concurrent)
    private let inputLock = NSLock()
    private var masterHandle: FileHandle?
    private var inputClosed = false

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
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            return
        }

        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        masterHandle = master

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        do {
            try process.run()
            try slave.close()
        } catch {
            try? slave.close()
            try? master.close()
            continuation.finish(throwing: error)
            return
        }

        group.enter()
        queue.async {
            self.readLines(from: master) { line in
                self.continuation.yield(.stdoutLine(line))
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

    func send(_ data: Data) throws {
        try inputLock.withLock {
            guard !inputClosed, let masterHandle else {
                return
            }
            try masterHandle.write(contentsOf: data)
        }
    }

    func closeInput() throws {
        try inputLock.withLock {
            guard !inputClosed else {
                return
            }
            inputClosed = true
            try masterHandle?.close()
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
                emit(Self.decodePTYLine(lineData))
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            }
        }

        if !buffer.isEmpty {
            emit(Self.decodePTYLine(buffer))
        }
    }

    private static func decodePTYLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
}

private final class SubprocessInteractiveProcess: InteractiveProcess, @unchecked Sendable {
    let events: AsyncThrowingStream<ProcessStreamEvent, Error>

    private let process = Process()
    private let stdinPipe = Pipe()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "agentctl.interactive-process", attributes: .concurrent)
    private let stdinLock = NSLock()
    private var stdinClosed = false

    init(
        executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stream = AsyncThrowingStream.makeStream(of: ProcessStreamEvent.self)
        events = stream.stream

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        stream.continuation.onTermination = { @Sendable [weak self] _ in
            self?.terminate()
        }

        group.enter()
        queue.async {
            Self.readLines(from: stdoutPipe.fileHandleForReading) { line in
                stream.continuation.yield(.stdoutLine(line))
            }
            self.group.leave()
        }

        group.enter()
        queue.async {
            Self.readLines(from: stderrPipe.fileHandleForReading) { line in
                stream.continuation.yield(.stderrLine(line))
            }
            self.group.leave()
        }

        queue.async {
            self.process.waitUntilExit()
            self.group.wait()
            stream.continuation.yield(.exited(self.process.terminationStatus))
            stream.continuation.finish()
        }
    }

    func sendLine(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        try stdinLock.withLock {
            guard !stdinClosed else {
                return
            }
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func closeStdin() throws {
        try stdinLock.withLock {
            guard !stdinClosed else {
                return
            }
            stdinClosed = true
            try stdinPipe.fileHandleForWriting.close()
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private static func readLines(from handle: FileHandle, emit: (String) -> Void) {
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
