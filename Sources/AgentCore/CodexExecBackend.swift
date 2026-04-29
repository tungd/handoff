import Foundation

public struct CodexExecOptions: Codable, Equatable, Sendable {
    public var fullAuto: Bool
    public var sandbox: String?
    public var model: String?
    public var profile: String?
    public var imagePaths: [String]?  // Paths to image files for -i/--image option

    public init(
        fullAuto: Bool = false,
        sandbox: String? = nil,
        model: String? = nil,
        profile: String? = nil,
        imagePaths: [String]? = nil
    ) {
        self.fullAuto = fullAuto
        self.sandbox = sandbox
        self.model = model
        self.profile = profile
        self.imagePaths = imagePaths
    }
}

public struct CodexExecResult: Codable, Equatable, Sendable {
    public var exitCode: Int32
    public var threadID: String?
    public var assistantText: String
    public var events: [AgentEvent]
    public var stderr: String

    public init(
        exitCode: Int32,
        threadID: String?,
        assistantText: String,
        events: [AgentEvent],
        stderr: String
    ) {
        self.exitCode = exitCode
        self.threadID = threadID
        self.assistantText = assistantText
        self.events = events
        self.stderr = stderr
    }
}

public enum CodexStreamUpdate: Equatable, Sendable {
    case mappedLine(CodexJSONLLineMapping)
    case stderrLine(String)
}

public struct CodexExecBackend: Sendable {
    private let runner: ProcessRunning
    private let executable: String

    public init(runner: ProcessRunning = SubprocessRunner(), executable: String = "/usr/bin/env") {
        self.runner = runner
        self.executable = executable
    }

    public func run(
        prompt: String,
        cwd: URL,
        resumeThreadID: String? = nil,
        options: CodexExecOptions = CodexExecOptions()
    ) throws -> CodexExecResult {
        let arguments = makeArguments(
            prompt: prompt,
            cwd: cwd,
            resumeThreadID: resumeThreadID,
            options: options
        )

        let result = try runner.run(executable, arguments: arguments, workingDirectory: cwd)
        let mapped = CodexJSONLMapper.map(stdout: result.stdout)

        return CodexExecResult(
            exitCode: result.exitCode,
            threadID: mapped.threadID,
            assistantText: mapped.assistantText,
            events: mapped.events,
            stderr: result.stderr
        )
    }

    public func makeArguments(
        prompt: String,
        cwd: URL,
        resumeThreadID: String? = nil,
        options: CodexExecOptions = CodexExecOptions()
    ) -> [String] {
        var arguments = ["codex", "exec"]

        if resumeThreadID != nil {
            arguments.append("resume")
        }

        arguments.append("--json")

        if options.fullAuto {
            arguments.append("--full-auto")
        }

        if resumeThreadID == nil, let sandbox = options.sandbox {
            arguments += ["--sandbox", sandbox]
        }

        if let model = options.model {
            arguments += ["--model", model]
        }

        if resumeThreadID == nil, let profile = options.profile {
            arguments += ["--profile", profile]
        }

        // Add image attachments (-i is repeatable for multiple images)
        if resumeThreadID == nil, let imagePaths = options.imagePaths {
            for imagePath in imagePaths {
                arguments += ["-i", imagePath]
            }
        }

        if let resumeThreadID {
            arguments.append(resumeThreadID)
        } else {
            arguments += ["-C", cwd.path]
        }

        arguments.append(prompt)
        return arguments
    }
}

public struct CodexStreamingBackend: Sendable {
    private let runner: ProcessStreaming
    private let executable: String

    public init(runner: ProcessStreaming = SubprocessStreamRunner(), executable: String = "/usr/bin/env") {
        self.runner = runner
        self.executable = executable
    }

    public func run(
        prompt: String,
        cwd: URL,
        resumeThreadID: String? = nil,
        options: CodexExecOptions = CodexExecOptions(),
        interruptHandle: AgentInterruptHandle? = nil,
        onUpdate: (CodexStreamUpdate) async throws -> Void
    ) async throws -> CodexExecResult {
        let arguments = CodexExecBackend(executable: executable).makeArguments(
            prompt: prompt,
            cwd: cwd,
            resumeThreadID: resumeThreadID,
            options: options
        )

        var exitCode: Int32 = 0
        var threadID: String?
        var assistantParts: [String] = []
        var events: [AgentEvent] = []
        var stderrLines: [String] = []

        let stream = runner.controlledStream(executable, arguments: arguments, workingDirectory: cwd)
        if let control = stream.control {
            interruptHandle?.setAction {
                do {
                    try control.send(Data([0x1B]))
                    return true
                } catch {
                    return false
                }
            }
        }
        defer {
            interruptHandle?.clearAction()
        }

        for try await streamEvent in stream.events {
            switch streamEvent {
            case let .stdoutLine(rawLine):
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                let mapped = CodexJSONLMapper.mapLine(line)
                if let mappedThreadID = mapped.threadID {
                    threadID = mappedThreadID
                }
                if let assistantText = mapped.assistantText {
                    assistantParts.append(assistantText)
                }
                events.append(mapped.event)
                try await onUpdate(.mappedLine(mapped))
            case let .stderrLine(rawLine):
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                stderrLines.append(line)
                try await onUpdate(.stderrLine(line))
            case let .exited(status):
                exitCode = status
            }
        }

        return CodexExecResult(
            exitCode: exitCode,
            threadID: threadID,
            assistantText: assistantParts.joined(separator: "\n"),
            events: events,
            stderr: stderrLines.joined(separator: "\n")
        )
    }
}

public struct CodexJSONLMappingResult: Equatable, Sendable {
    public var threadID: String?
    public var assistantText: String
    public var events: [AgentEvent]

    public init(threadID: String?, assistantText: String, events: [AgentEvent]) {
        self.threadID = threadID
        self.assistantText = assistantText
        self.events = events
    }
}

public struct CodexJSONLLineMapping: Equatable, Sendable {
    public var threadID: String?
    public var assistantText: String?
    public var event: AgentEvent

    public init(threadID: String? = nil, assistantText: String? = nil, event: AgentEvent) {
        self.threadID = threadID
        self.assistantText = assistantText
        self.event = event
    }
}

public enum CodexJSONLMapper {
    public static func map(stdout: String) -> CodexJSONLMappingResult {
        var threadID: String?
        var assistantParts: [String] = []
        var events: [AgentEvent] = []

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let mapped = mapLine(String(line))
            if let mappedThreadID = mapped.threadID {
                threadID = mappedThreadID
            }
            if let assistantText = mapped.assistantText {
                assistantParts.append(assistantText)
            }
            events.append(mapped.event)
        }

        return CodexJSONLMappingResult(
            threadID: threadID,
            assistantText: assistantParts.joined(separator: "\n"),
            events: events
        )
    }

    public static func mapLine(_ text: String) -> CodexJSONLLineMapping {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            let type = object["type"]?.stringValue
        else {
            return CodexJSONLLineMapping(
                event: AgentEvent(kind: .backendEvent, payload: ["line": .string(text)])
            )
        }

        switch type {
        case "thread.started":
            return CodexJSONLLineMapping(
                threadID: object["thread_id"]?.stringValue,
                event: AgentEvent(kind: .backendSessionUpdated, payload: object)
            )
        case "item.started":
            let item = object["item"]?.objectValue
            if item?["type"]?.stringValue == "command_execution" {
                return CodexJSONLLineMapping(event: AgentEvent(kind: .toolStarted, payload: [
                    "command": item?["command"] ?? .null,
                    "raw": .object(object)
                ]))
            }
            return CodexJSONLLineMapping(event: AgentEvent(kind: .backendEvent, payload: object))
        case "item.completed":
            let item = object["item"]?.objectValue
            if item?["type"]?.stringValue == "agent_message",
               let message = item?["text"]?.stringValue {
                return CodexJSONLLineMapping(
                    assistantText: message,
                    event: AgentEvent(kind: .assistantDone, payload: [
                        "text": .string(message),
                        "raw": .object(object)
                    ])
                )
            }
            if item?["type"]?.stringValue == "command_execution" {
                return CodexJSONLLineMapping(event: AgentEvent(kind: .toolFinished, payload: [
                    "command": item?["command"] ?? .null,
                    "exitCode": item?["exit_code"] ?? .null,
                    "output": item?["aggregated_output"] ?? .null,
                    "raw": .object(object)
                ]))
            }
            return CodexJSONLLineMapping(event: AgentEvent(kind: .backendEvent, payload: object))
        case "turn.completed", "turn.started":
            return CodexJSONLLineMapping(event: AgentEvent(kind: .backendEvent, payload: object))
        default:
            return CodexJSONLLineMapping(event: AgentEvent(kind: .backendEvent, payload: object))
        }
    }
}
