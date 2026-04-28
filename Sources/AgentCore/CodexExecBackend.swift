import Foundation

public struct CodexExecOptions: Codable, Equatable, Sendable {
    public var fullAuto: Bool
    public var sandbox: String?
    public var model: String?
    public var profile: String?

    public init(
        fullAuto: Bool = false,
        sandbox: String? = nil,
        model: String? = nil,
        profile: String? = nil
    ) {
        self.fullAuto = fullAuto
        self.sandbox = sandbox
        self.model = model
        self.profile = profile
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

        if let resumeThreadID {
            arguments.append(resumeThreadID)
        } else {
            arguments += ["-C", cwd.path]
        }

        arguments.append(prompt)
        return arguments
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

public enum CodexJSONLMapper {
    public static func map(stdout: String) -> CodexJSONLMappingResult {
        var threadID: String?
        var assistantParts: [String] = []
        var events: [AgentEvent] = []

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard
                let data = text.data(using: .utf8),
                let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                let type = object["type"]?.stringValue
            else {
                events.append(AgentEvent(kind: .backendEvent, payload: ["line": .string(text)]))
                continue
            }

            switch type {
            case "thread.started":
                threadID = object["thread_id"]?.stringValue
                events.append(AgentEvent(kind: .backendSessionUpdated, payload: object))
            case "item.completed":
                let item = object["item"]?.objectValue
                if item?["type"]?.stringValue == "agent_message",
                   let message = item?["text"]?.stringValue {
                    assistantParts.append(message)
                    events.append(AgentEvent(kind: .assistantDone, payload: [
                        "text": .string(message),
                        "raw": .object(object)
                    ]))
                } else {
                    events.append(AgentEvent(kind: .backendEvent, payload: object))
                }
            case "turn.completed":
                events.append(AgentEvent(kind: .backendEvent, payload: object))
            case "turn.started":
                events.append(AgentEvent(kind: .backendEvent, payload: object))
            default:
                events.append(AgentEvent(kind: .backendEvent, payload: object))
            }
        }

        return CodexJSONLMappingResult(
            threadID: threadID,
            assistantText: assistantParts.joined(separator: "\n"),
            events: events
        )
    }
}
