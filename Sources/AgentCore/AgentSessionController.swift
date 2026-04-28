import Foundation

public enum AgentSessionControllerError: Error, CustomStringConvertible, Sendable {
    case unsupportedBackend(AgentBackend)
    case backendFailed(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .unsupportedBackend(backend):
            return "backend is not wired yet: \(backend.rawValue)"
        case let .backendFailed(exitCode, stderr):
            return "Codex exited with \(exitCode): \(stderr)"
        }
    }
}

public enum AgentSessionUpdate: Equatable, Sendable {
    case event(AgentEvent)
    case session(SessionRecord)
}

public struct AgentSessionController: Sendable {
    private let store: any AgentTaskStore
    private let codexBackend: CodexStreamingBackend

    public init(
        store: any AgentTaskStore,
        codexBackend: CodexStreamingBackend = CodexStreamingBackend()
    ) {
        self.store = store
        self.codexBackend = codexBackend
    }

    public func runCodexTurn(
        task: TaskRecord,
        prompt: String,
        repoURL: URL,
        snapshot: RepositorySnapshot,
        options: CodexExecOptions = CodexExecOptions(),
        onUpdate: (AgentSessionUpdate) async throws -> Void = { _ in }
    ) async throws -> TaskRunSummary {
        guard task.backendPreference == .codex else {
            throw AgentSessionControllerError.unsupportedBackend(task.backendPreference)
        }

        let cwd = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
        let previousSession = try await store.latestSession(for: task.id)
        var session = SessionRecord(
            taskID: task.id,
            backend: .codex,
            backendSessionID: previousSession?.backendSessionID,
            cwd: cwd.path,
            state: .running
        )

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionStarted, payload: [
            "backend": .string(session.backend.rawValue),
            "cwd": .string(session.cwd),
            "resumeThreadID": session.backendSessionID.map { .string($0) } ?? .null
        ]), onUpdate: onUpdate)

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage, payload: [
            "text": .string(prompt)
        ]), onUpdate: onUpdate)

        let result = try await codexBackend.run(
            prompt: prompt,
            cwd: cwd,
            resumeThreadID: session.backendSessionID,
            options: options
        ) { update in
            switch update {
            case let .mappedLine(mapped):
                if let threadID = mapped.threadID {
                    session.backendSessionID = threadID
                    try await store.saveSession(session)
                    try await onUpdate(.session(session))
                }

                var event = mapped.event
                event.taskID = task.id
                event.sessionID = session.id
                try await appendAndEmit(event, onUpdate: onUpdate)
            case let .stderrLine(line):
                try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .backendEvent, payload: [
                    "stderr": .string(line)
                ]), onUpdate: onUpdate)
            }
        }

        if let threadID = result.threadID {
            session.backendSessionID = threadID
        }

        session.state = result.exitCode == 0 ? .ended : .failed
        session.endedAt = Date()

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionEnded, payload: [
            "exitCode": .int(Int64(result.exitCode)),
            "threadID": session.backendSessionID.map { .string($0) } ?? .null
        ]), onUpdate: onUpdate)

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        if result.exitCode != 0 {
            throw AgentSessionControllerError.backendFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        return try await store.summary(for: task)
    }

    @discardableResult
    private func appendAndEmit(
        _ event: AgentEvent,
        onUpdate: (AgentSessionUpdate) async throws -> Void
    ) async throws -> AgentEvent {
        let stored = try await store.appendEvent(event)
        try await onUpdate(.event(stored))
        return stored
    }
}
