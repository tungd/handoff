import Foundation
import AgentCore
import ACP
import ACPModel

public final class ACPAgentDelegate: AgentDelegate, Sendable {
    private let sessionManager: ACPSessionManager
    private let sessionController: AgentSessionController
    private let store: any AgentTaskStore
    private let agent: Agent
    private let interruptHandle: AgentInterruptHandle

    public init(
        sessionManager: ACPSessionManager,
        sessionController: AgentSessionController,
        store: any AgentTaskStore,
        agent: Agent,
        interruptHandle: AgentInterruptHandle = AgentInterruptHandle()
    ) {
        self.sessionManager = sessionManager
        self.sessionController = sessionController
        self.store = store
        self.agent = agent
        self.interruptHandle = interruptHandle
    }

    public func handleInitialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            protocolVersion: 1,
            agentCapabilities: AgentCapabilities(
                loadSession: true,
                sessionCapabilities: SessionCapabilities(
                    close: SessionCloseCapabilities(),
                    list: SessionListCapabilities(),
                    resume: SessionResumeCapabilities()
                )
            ),
            agentInfo: AgentInfo(
                name: "agentctl",
                version: "1.0.0",
                title: "Agentctl ACP Backend"
            )
        )
    }

    public func handleNewSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let cwd = URL(fileURLWithPath: request.cwd, isDirectory: true)
        let backend: AgentBackend = .codex

        let session = try await sessionManager.createSession(cwd: cwd, backend: backend)

        return NewSessionResponse(
            sessionId: session.sessionId,
            modes: ModesInfo(
                currentModeId: "code",
                availableModes: [
                    ModeInfo(id: "code", name: "Code", description: "Default coding mode"),
                    ModeInfo(id: "ask", name: "Ask", description: "Question mode without editing")
                ]
            )
        )
    }

    public func handlePrompt(_ request: SessionPromptRequest) async throws -> SessionPromptResponse {
        guard let task = await sessionManager.getTask(sessionId: request.sessionId),
              let cwd = await sessionManager.getCwd(sessionId: request.sessionId) else {
            throw ACPAgentError.sessionNotFound(request.sessionId.value)
        }

        await sessionManager.setPromptActive(sessionId: request.sessionId)
        await sessionManager.clearResponse(sessionId: request.sessionId)

        let promptText = extractPromptText(from: request.prompt)
        let snapshot = try RepositoryInspector().inspect(path: cwd)

        do {
            _ = try await sessionController.runCodexTurn(
                task: task,
                prompt: promptText,
                repoURL: cwd,
                snapshot: snapshot,
                options: CodexExecOptions(
                    fullAuto: true,
                    model: nil
                ),
                interruptHandle: interruptHandle,
                onUpdate: { update in
                    await self.handleSessionUpdate(
                        sessionId: request.sessionId,
                        update: update
                    )
                }
            )

            if let session = try await store.latestSession(for: task.id),
               let backendSessionId = session.backendSessionID {
                try await sessionManager.updateSession(
                    sessionId: request.sessionId,
                    backendSessionId: backendSessionId
                )
            }

            await sessionManager.setPromptInactive(sessionId: request.sessionId)

            return SessionPromptResponse(stopReason: .endTurn)
        } catch {
            await sessionManager.setPromptInactive(sessionId: request.sessionId)
            throw error
        }
    }

    public func handleCancel(_ sessionId: SessionId) async throws {
        interruptHandle.requestInterrupt()
        await sessionManager.setPromptInactive(sessionId: sessionId)
    }

    public func handleLoadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        guard await sessionManager.getSession(sessionId: request.sessionId) != nil else {
            throw ACPAgentError.sessionNotFound(request.sessionId.value)
        }

        return LoadSessionResponse(
            modes: ModesInfo(
                currentModeId: await sessionManager.getMode(sessionId: request.sessionId),
                availableModes: [
                    ModeInfo(id: "code", name: "Code", description: "Default coding mode"),
                    ModeInfo(id: "ask", name: "Ask", description: "Question mode without editing")
                ]
            )
        )
    }

    public func handleListSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        let sessions = try await sessionManager.listSessions(cwd: request.cwd)
        return ListSessionsResponse(sessions: sessions)
    }

    public func handleCloseSession(_ request: CloseSessionRequest) async throws -> CloseSessionResponse {
        try await sessionManager.closeSession(sessionId: request.sessionId)
        return CloseSessionResponse()
    }

    private func handleSessionUpdate(
        sessionId: SessionId,
        update: AgentSessionUpdate
    ) async {
        switch update {
        case .event(let event):
            await handleAgentEvent(sessionId: sessionId, event: event)
        case .session(let sessionRecord):
            if let backendSessionId = sessionRecord.backendSessionID {
                try? await sessionManager.updateSession(
                    sessionId: sessionId,
                    backendSessionId: backendSessionId
                )
            }
        }
    }

    private func handleAgentEvent(sessionId: SessionId, event: AgentEvent) async {
        switch event.kind {
        case .assistantDelta:
            if let delta = event.payload["delta"]?.stringValue {
                await sessionManager.appendResponse(sessionId: sessionId, text: delta)
                try? await agent.sendMessageChunk(sessionId: sessionId, text: delta)
            }

        case .assistantDone:
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                try? await agent.sendMessageChunk(sessionId: sessionId, text: text)
            }

        case .toolStarted:
            let toolCallId = event.payload["toolCallID"]?.stringValue ?? event.id.uuidString
            let toolName = event.payload["name"]?.stringValue ?? event.payload["toolName"]?.stringValue ?? "Tool"
            let command = event.payload["command"]?.stringValue

            let toolCall = ToolCallUpdate(
                toolCallId: toolCallId,
                status: .inProgress,
                title: command ?? toolName,
                kind: .execute,
                content: []
            )
            try? await agent.sendToolCall(sessionId: sessionId, toolCall: toolCall)

        case .toolOutput:
            let toolCallId = event.payload["toolCallID"]?.stringValue ?? event.id.uuidString
            let output = event.payload["output"]?.stringValue ?? ""

            let toolCall = ToolCallUpdate(
                toolCallId: toolCallId,
                status: .inProgress,
                content: [.content(.text(TextContent(text: output)))]
            )
            try? await agent.sendToolCall(sessionId: sessionId, toolCall: toolCall)

        case .toolFinished:
            let toolCallId = event.payload["toolCallID"]?.stringValue ?? event.id.uuidString
            let output = event.payload["output"]?.stringValue ?? ""
            let exitCode: Int
            if case let .int(value) = event.payload["exitCode"] {
                exitCode = Int(clamping: value)
            } else {
                exitCode = 0
            }
            let status: ToolStatus = exitCode == 0 ? .completed : .failed

            let toolCall = ToolCallUpdate(
                toolCallId: toolCallId,
                status: status,
                content: [.content(.text(TextContent(text: output)))]
            )
            try? await agent.sendToolCall(sessionId: sessionId, toolCall: toolCall)

        case .sessionStarted, .sessionEnded, .userMessage, .backendSessionUpdated, .backendEvent:
            break

        default:
            break
        }
    }

    private func extractPromptText(from blocks: [ContentBlock]) -> String {
        var textParts: [String] = []
        for block in blocks {
            switch block {
            case .text(let textContent):
                textParts.append(textContent.text)
            case .image(let imageContent):
                textParts.append("[Image: \(imageContent.mimeType)]")
            case .resourceLink(let link):
                textParts.append("[Resource: \(link.uri)]")
            case .resource(let resource):
                if let text = resource.resource.text {
                    textParts.append(text)
                }
            case .audio:
                break
            }
        }
        return textParts.joined(separator: "\n")
    }
}

public enum ACPAgentError: Error, CustomStringConvertible, Sendable {
    case sessionNotFound(String)
    case backendError(String)

    public var description: String {
        switch self {
        case .sessionNotFound(let id):
            return "session not found: \(id)"
        case .backendError(let message):
            return "backend error: \(message)"
        }
    }
}