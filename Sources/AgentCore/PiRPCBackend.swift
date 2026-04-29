import Foundation

/// Image content for sending to Pi backend via RPC.
public struct PiRPCImage: Codable, Equatable, Sendable {
    public var type: String = "image"
    public var data: String  // base64-encoded
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct PiRPCOptions: Codable, Equatable, Sendable {
    public var provider: String?
    public var model: String?
    public var thinking: String?
    public var tools: String?
    public var noTools: Bool
    public var skillPaths: [URL]

    public init(
        provider: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        tools: String? = nil,
        noTools: Bool = false,
        skillPaths: [URL] = []
    ) {
        self.provider = provider
        self.model = model
        self.thinking = thinking
        self.tools = tools
        self.noTools = noTools
        self.skillPaths = skillPaths
    }
}

public struct PiRPCResult: Codable, Equatable, Sendable {
    public var exitCode: Int32
    public var sessionPath: String
    public var assistantText: String
    public var stderr: String

    public init(exitCode: Int32, sessionPath: String, assistantText: String, stderr: String) {
        self.exitCode = exitCode
        self.sessionPath = sessionPath
        self.assistantText = assistantText
        self.stderr = stderr
    }
}

public enum PiRPCStreamUpdate: Equatable, Sendable {
    case mappedLine(PiRPCLineMapping)
    case stderrLine(String)
}

public struct PiRPCLineMapping: Equatable, Sendable {
    public var requestID: String?
    public var command: String?
    public var sessionPath: String?
    public var assistantText: String?
    public var isAgentEnd: Bool
    public var promptError: String?
    public var event: AgentEvent

    public init(
        requestID: String? = nil,
        command: String? = nil,
        sessionPath: String? = nil,
        assistantText: String? = nil,
        isAgentEnd: Bool = false,
        promptError: String? = nil,
        event: AgentEvent
    ) {
        self.requestID = requestID
        self.command = command
        self.sessionPath = sessionPath
        self.assistantText = assistantText
        self.isAgentEnd = isAgentEnd
        self.promptError = promptError
        self.event = event
    }
}

public struct PiRPCBackend: Sendable {
    private let runner: ProcessInteracting
    private let executable: String

    public init(runner: ProcessInteracting = SubprocessInteractiveRunner(), executable: String = "/usr/bin/env") {
        self.runner = runner
        self.executable = executable
    }

    public func run(
        prompt: String,
        cwd: URL,
        sessionPath: URL,
        options: PiRPCOptions = PiRPCOptions(),
        images: [PiRPCImage] = [],
        interruptHandle: AgentInterruptHandle? = nil,
        onUpdate: (PiRPCStreamUpdate) async throws -> Void
    ) async throws -> PiRPCResult {
        try FileManager.default.createDirectory(
            at: sessionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = try runner.start(
            executable,
            arguments: makeArguments(sessionPath: sessionPath, options: options),
            workingDirectory: cwd
        )

        let promptID = "prompt-\(UUID().uuidString)"
        let statsID = "stats-\(UUID().uuidString)"
        
        // Build prompt command with optional images
        var promptCommand: [String: Any] = [
            "id": promptID,
            "type": "prompt",
            "message": prompt
        ]
        if !images.isEmpty {
            promptCommand["images"] = images.map { img -> [String: String] in
                ["type": "image", "data": img.data, "mimeType": img.mimeType]
            }
        }
        try process.sendLine(Self.encodeCommand(promptCommand))

        interruptHandle?.setAction {
            do {
                try process.sendLine(Self.encodeCommand([
                    "id": "abort-\(UUID().uuidString)",
                    "type": "abort"
                ]))
                return true
            } catch {
                return false
            }
        }
        defer {
            interruptHandle?.clearAction()
        }

        var exitCode: Int32 = 0
        var stderrLines: [String] = []
        var assistantText: String?
        var resolvedSessionPath = sessionPath.path
        var requestedStats = false
        var completedTurn = false
        var promptError: String?

        for try await streamEvent in process.events {
            switch streamEvent {
            case let .stdoutLine(line):
                let mapped = PiRPCMapper.mapLine(line)
                if let newSessionPath = mapped.sessionPath {
                    resolvedSessionPath = newSessionPath
                }
                if let text = mapped.assistantText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantText = text
                }
                if let error = mapped.promptError {
                    promptError = error
                }
                try await onUpdate(.mappedLine(mapped))

                if mapped.isAgentEnd, !requestedStats {
                    completedTurn = true
                    requestedStats = true
                    try process.sendLine(Self.encodeCommand([
                        "id": statsID,
                        "type": "get_session_stats"
                    ]))
                } else if mapped.requestID == statsID {
                    process.terminate()
                }
            case let .stderrLine(line):
                stderrLines.append(line)
                try await onUpdate(.stderrLine(line))
            case let .exited(status):
                exitCode = status
            }
        }

        let stderr = stderrLines.joined(separator: "\n")
        if let promptError, !completedTurn {
            return PiRPCResult(
                exitCode: exitCode == 0 ? 1 : exitCode,
                sessionPath: resolvedSessionPath,
                assistantText: assistantText ?? "",
                stderr: promptError
            )
        }

        return PiRPCResult(
            exitCode: completedTurn ? 0 : exitCode,
            sessionPath: resolvedSessionPath,
            assistantText: assistantText ?? "",
            stderr: stderr
        )
    }

    public func makeArguments(
        sessionPath: URL,
        options: PiRPCOptions = PiRPCOptions()
    ) -> [String] {
        var arguments = ["pi", "--mode", "rpc", "--session", sessionPath.path]

        if let provider = options.provider, !provider.isEmpty {
            arguments += ["--provider", provider]
        }
        if let model = options.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let thinking = options.thinking, !thinking.isEmpty {
            arguments += ["--thinking", thinking]
        }
        if options.noTools {
            arguments.append("--no-tools")
        } else if let tools = options.tools, !tools.isEmpty {
            arguments += ["--tools", tools]
        }

        // Add skill paths
        for skillPath in options.skillPaths {
            arguments += ["--skill", skillPath.path]
        }

        return arguments
    }

    private static func encodeCommand(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PiRPCMapper {
    public static func mapLine(_ text: String) -> PiRPCLineMapping {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            let type = object["type"]?.stringValue
        else {
            return PiRPCLineMapping(
                event: AgentEvent(kind: .backendEvent, payload: ["line": .string(text), "backend": .string("pi")])
            )
        }

        switch type {
        case "response":
            return mapResponse(object)
        case "agent_end":
            let assistantText = latestAssistantText(from: object["messages"]?.arrayValue)
            if let assistantText, !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return PiRPCLineMapping(
                    assistantText: assistantText,
                    isAgentEnd: true,
                    event: AgentEvent(kind: .assistantDone, payload: [
                        "text": .string(assistantText),
                        "backend": .string("pi"),
                        "raw": .object(object)
                    ])
                )
            }
            return PiRPCLineMapping(
                isAgentEnd: true,
                event: AgentEvent(kind: .backendEvent, payload: normalizedPayload(object))
            )
        case "message_update":
            if let event = object["assistantMessageEvent"]?.objectValue,
               event["type"]?.stringValue == "text_delta",
               let delta = event["delta"]?.stringValue {
                return PiRPCLineMapping(event: AgentEvent(kind: .assistantDelta, payload: [
                    "delta": .string(delta),
                    "backend": .string("pi"),
                    "raw": .object(object)
                ]))
            }
            return PiRPCLineMapping(event: AgentEvent(kind: .backendEvent, payload: normalizedPayload(object)))
        case "tool_execution_start":
            return PiRPCLineMapping(event: AgentEvent(kind: .toolStarted, payload: toolPayload(from: object)))
        case "tool_execution_update":
            return PiRPCLineMapping(event: AgentEvent(kind: .toolOutput, payload: toolPayload(from: object)))
        case "tool_execution_end":
            return PiRPCLineMapping(event: AgentEvent(kind: .toolFinished, payload: toolPayload(from: object)))
        default:
            return PiRPCLineMapping(event: AgentEvent(kind: .backendEvent, payload: normalizedPayload(object)))
        }
    }

    private static func mapResponse(_ object: [String: JSONValue]) -> PiRPCLineMapping {
        let requestID = object["id"]?.stringValue
        let command = object["command"]?.stringValue
        let success = boolValue(object["success"]) ?? false
        let data = object["data"]?.objectValue
        let sessionPath = data?["sessionFile"]?.stringValue
        let promptError = command == "prompt" && !success
            ? responseErrorMessage(object)
            : nil

        if command == "get_session_stats", let data {
            return PiRPCLineMapping(
                requestID: requestID,
                command: command,
                sessionPath: sessionPath,
                event: AgentEvent(kind: .backendEvent, payload: sessionStatsPayload(data))
            )
        }

        return PiRPCLineMapping(
            requestID: requestID,
            command: command,
            sessionPath: sessionPath,
            promptError: promptError,
            event: AgentEvent(kind: command == "get_state" ? .backendSessionUpdated : .backendEvent, payload: normalizedPayload(object))
        )
    }

    private static func toolPayload(from object: [String: JSONValue]) -> [String: JSONValue] {
        let toolName = object["toolName"]?.stringValue ?? "Tool"
        let args = object["args"]?.objectValue ?? [:]
        let result = object["result"]?.objectValue
        let partialResult = object["partialResult"]?.objectValue
        let resultObject = result ?? partialResult
        let output = contentText(from: resultObject?["content"]?.arrayValue)
        let isError = boolValue(object["isError"]) ?? false
        let command = args["command"]?.stringValue

        var payload: [String: JSONValue] = [
            "backend": .string("pi"),
            "name": .string(toolName),
            "toolName": .string(toolName),
            "toolCallID": object["toolCallId"] ?? .null,
            "args": .object(args),
            "raw": .object(object)
        ]

        if let command {
            payload["command"] = .string(command)
        } else if !args.isEmpty {
            payload["detail"] = .string(compactObject(args))
        }

        if let output, !output.isEmpty {
            payload["output"] = .string(output)
        }
        if isError {
            payload["exitCode"] = .int(1)
        } else if let exitCode = intValue(resultObject?["details"]?.objectValue?["exitCode"]) {
            payload["exitCode"] = .int(exitCode)
        } else {
            payload["exitCode"] = .int(0)
        }

        return payload
    }

    private static func sessionStatsPayload(_ data: [String: JSONValue]) -> [String: JSONValue] {
        let tokens = data["tokens"]?.objectValue ?? [:]
        let contextUsage = data["contextUsage"]?.objectValue ?? [:]
        var usage: [String: JSONValue] = [
            "input_tokens": tokens["input"] ?? .int(0),
            "output_tokens": tokens["output"] ?? .int(0)
        ]
        if let total = tokens["total"] {
            usage["total_tokens"] = total
        }

        var payload: [String: JSONValue] = [
            "backend": .string("pi"),
            "type": .string("pi.session_stats"),
            "usage": .object(usage),
            "raw": .object(data)
        ]
        if let contextWindow = contextUsage["contextWindow"] {
            payload["context_window"] = contextWindow
        }
        if let contextTokens = contextUsage["tokens"] {
            payload["context_tokens"] = contextTokens
        }
        if let sessionFile = data["sessionFile"] {
            payload["sessionFile"] = sessionFile
        }
        return payload
    }

    private static func normalizedPayload(_ object: [String: JSONValue]) -> [String: JSONValue] {
        var payload = object
        payload["backend"] = .string("pi")
        return payload
    }

    private static func latestAssistantText(from messages: [JSONValue]?) -> String? {
        guard let messages else {
            return nil
        }

        for messageValue in messages.reversed() {
            guard let message = messageValue.objectValue,
                  message["role"]?.stringValue == "assistant"
            else {
                continue
            }
            if let content = message["content"]?.stringValue {
                return content
            }
            if let text = contentText(from: message["content"]?.arrayValue), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func contentText(from content: [JSONValue]?) -> String? {
        guard let content else {
            return nil
        }
        let parts = content.compactMap { value -> String? in
            guard let object = value.objectValue else {
                return value.stringValue
            }
            if object["type"]?.stringValue == "text" {
                return object["text"]?.stringValue
            }
            return nil
        }
        return parts.joined(separator: "\n")
    }

    private static func responseErrorMessage(_ object: [String: JSONValue]) -> String {
        if let error = object["error"]?.stringValue {
            return error
        }
        if let message = object["message"]?.stringValue {
            return message
        }
        if let data = object["data"]?.objectValue,
           let error = data["error"]?.stringValue {
            return error
        }
        return "Pi rejected the prompt."
    }

    private static func boolValue(_ value: JSONValue?) -> Bool? {
        if case let .bool(value) = value {
            return value
        }
        return nil
    }

    private static func intValue(_ value: JSONValue?) -> Int64? {
        switch value {
        case let .int(value):
            return value
        case let .double(value):
            return Int64(value)
        case let .string(value):
            return Int64(value)
        default:
            return nil
        }
    }

    private static func compactObject(_ object: [String: JSONValue]) -> String {
        object.keys.sorted().map { key in
            guard let value = object[key] else {
                return key
            }
            if let text = value.stringValue {
                return "\(key)=\(text)"
            }
            return "\(key)=\(value)"
        }.joined(separator: " ")
    }
}
