import Foundation
import AgentCore
import ACPModel

public struct ACPSession: Sendable {
    public let sessionId: SessionId
    public let task: TaskRecord
    public let cwd: URL
    public let createdAt: Date
    public var backendSessionId: String?
    public var state: SessionState
    public var currentMode: String
    public var pendingPrompt: String?
    public var accumulatedResponse: String

    public init(
        sessionId: SessionId,
        task: TaskRecord,
        cwd: URL,
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.task = task
        self.cwd = cwd
        self.createdAt = createdAt
        self.backendSessionId = nil
        self.state = .starting
        self.currentMode = "code"
        self.pendingPrompt = nil
        self.accumulatedResponse = ""
    }
}

public actor ACPSessionManager {
    private var sessions: [SessionId: ACPSession] = [:]
    private var activePrompts: [SessionId: Bool] = [:]
    private let store: any AgentTaskStore

    public init(store: any AgentTaskStore) {
        self.store = store
    }

    public func createSession(cwd: URL, backend: AgentBackend = .codex) async throws -> ACPSession {
        let sessionId = SessionId(UUID().uuidString)
        let task = TaskRecord(
            title: "ACP Session",
            slug: Slug.make("acp-session-\(sessionId.value)"),
            backendPreference: backend
        )

        try await store.saveTask(task)
        try await store.appendEvent(AgentEvent(taskID: task.id, kind: .taskCreated, payload: [
            "title": .string(task.title),
            "slug": .string(task.slug),
            "backend": .string(task.backendPreference.rawValue),
            "source": .string("acp")
        ]))

        let session = ACPSession(sessionId: sessionId, task: task, cwd: cwd)
        sessions[sessionId] = session
        return session
    }

    public func getSession(sessionId: SessionId) -> ACPSession? {
        sessions[sessionId]
    }

    public func updateSession(sessionId: SessionId, backendSessionId: String?) async throws {
        guard var session = sessions[sessionId] else { return }
        session.backendSessionId = backendSessionId
        session.state = .running
        sessions[sessionId] = session

        let sessionRecord = SessionRecord(
            taskID: session.task.id,
            backend: session.task.backendPreference,
            backendSessionID: backendSessionId,
            cwd: session.cwd.path,
            state: .running
        )
        try await store.saveSession(sessionRecord)
    }

    public func endSession(sessionId: SessionId, state: SessionState = .ended) async throws {
        guard var session = sessions[sessionId] else { return }
        session.state = state
        sessions[sessionId] = session

        let sessionRecord = SessionRecord(
            taskID: session.task.id,
            backend: session.task.backendPreference,
            backendSessionID: session.backendSessionId,
            cwd: session.cwd.path,
            state: state,
            endedAt: Date()
        )
        try await store.saveSession(sessionRecord)
    }

    public func closeSession(sessionId: SessionId) async throws {
        guard sessions[sessionId] != nil else { return }
        try await endSession(sessionId: sessionId, state: .ended)
        sessions.removeValue(forKey: sessionId)
        activePrompts.removeValue(forKey: sessionId)
    }

    public func listSessions(cwd: String?) async throws -> [SessionInfo] {
        var result: [SessionInfo] = []
        for session in sessions.values {
            if let cwd, !session.cwd.path.hasPrefix(cwd) { continue }
            result.append(SessionInfo(
                sessionId: session.sessionId,
                cwd: session.cwd.path,
                title: session.task.title,
                updatedAt: ISO8601DateFormatter().string(from: session.createdAt)
            ))
        }
        return result
    }

    public func setPromptActive(sessionId: SessionId) {
        activePrompts[sessionId] = true
    }

    public func setPromptInactive(sessionId: SessionId) {
        activePrompts[sessionId] = false
    }

    public func isPromptActive(sessionId: SessionId) -> Bool {
        activePrompts[sessionId] ?? false
    }

    public func appendResponse(sessionId: SessionId, text: String) {
        guard var session = sessions[sessionId] else { return }
        session.accumulatedResponse += text
        sessions[sessionId] = session
    }

    public func getResponse(sessionId: SessionId) -> String {
        sessions[sessionId]?.accumulatedResponse ?? ""
    }

    public func clearResponse(sessionId: SessionId) {
        guard var session = sessions[sessionId] else { return }
        session.accumulatedResponse = ""
        sessions[sessionId] = session
    }

    public func getTask(sessionId: SessionId) -> TaskRecord? {
        sessions[sessionId]?.task
    }

    public func getCwd(sessionId: SessionId) -> URL? {
        sessions[sessionId]?.cwd
    }

    public func getBackendSessionId(sessionId: SessionId) -> String? {
        sessions[sessionId]?.backendSessionId
    }

    public func setMode(sessionId: SessionId, mode: String) {
        guard var session = sessions[sessionId] else { return }
        session.currentMode = mode
        sessions[sessionId] = session
    }

    public func getMode(sessionId: SessionId) -> String {
        sessions[sessionId]?.currentMode ?? "code"
    }
}