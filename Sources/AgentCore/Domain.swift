import Foundation

public enum AgentBackend: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case open
    case blocked
    case completed
    case archived
}

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case waitingForInput = "waiting_for_input"
    case ended
    case failed
    case canceled
}

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case taskCreated = "task.created"
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case userMessage = "user.message"
    case assistantDelta = "assistant.delta"
    case assistantDone = "assistant.done"
    case toolStarted = "tool.started"
    case toolOutput = "tool.output"
    case toolFinished = "tool.finished"
    case permissionRequested = "permission.requested"
    case permissionResolved = "permission.resolved"
    case checkpointCreated = "checkpoint.created"
    case handoffCreated = "handoff.created"
    case memoryWritten = "memory.written"
    case backendSessionUpdated = "backend.session.updated"
    case backendEvent = "backend.event"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
}

public enum MemoryScopeKind: String, Codable, CaseIterable, Sendable {
    case globalPersonal = "global_personal"
    case globalWork = "global_work"
    case repo
    case task
    case machine
    case session
}

public struct MachineRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var stableName: String
    public var hostname: String
    public var createdAt: Date
    public var lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        stableName: String,
        hostname: String,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.stableName = stableName
        self.hostname = hostname
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct RepoRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var canonicalRemoteURL: String
    public var defaultBranch: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        canonicalRemoteURL: String,
        defaultBranch: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.canonicalRemoteURL = canonicalRemoteURL
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
    }
}

public struct TaskRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var repoID: UUID?
    public var title: String
    public var slug: String
    public var backendPreference: AgentBackend
    public var state: TaskState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        repoID: UUID? = nil,
        title: String,
        slug: String,
        backendPreference: AgentBackend = .codex,
        state: TaskState = .open,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.repoID = repoID
        self.title = title
        self.slug = slug
        self.backendPreference = backendPreference
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var taskID: UUID
    public var backend: AgentBackend
    public var backendSessionID: String?
    public var machineID: UUID?
    public var cwd: String
    public var state: SessionState
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        backend: AgentBackend,
        backendSessionID: String? = nil,
        machineID: UUID? = nil,
        cwd: String,
        state: SessionState = .starting,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.backend = backend
        self.backendSessionID = backendSessionID
        self.machineID = machineID
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct CheckpointRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var taskID: UUID
    public var repoID: UUID?
    public var machineID: UUID?
    public var branch: String
    public var commitSHA: String?
    public var remoteName: String
    public var pushedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        repoID: UUID? = nil,
        machineID: UUID? = nil,
        branch: String,
        commitSHA: String? = nil,
        remoteName: String = "origin",
        pushedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.repoID = repoID
        self.machineID = machineID
        self.branch = branch
        self.commitSHA = commitSHA
        self.remoteName = remoteName
        self.pushedAt = pushedAt
        self.createdAt = createdAt
    }
}

public struct AgentEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var taskID: UUID?
    public var sessionID: UUID?
    public var sequence: Int64?
    public var kind: EventKind
    public var occurredAt: Date
    public var payload: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        sessionID: UUID? = nil,
        sequence: Int64? = nil,
        kind: EventKind,
        occurredAt: Date = Date(),
        payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.sequence = sequence
        self.kind = kind
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

public struct MemoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var scopeKind: MemoryScopeKind
    public var scopeID: UUID?
    public var repoID: UUID?
    public var taskID: UUID?
    public var title: String
    public var body: String
    public var summary: String?
    public var tags: [String]
    public var createdBy: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        scopeKind: MemoryScopeKind,
        scopeID: UUID? = nil,
        repoID: UUID? = nil,
        taskID: UUID? = nil,
        title: String,
        body: String,
        summary: String? = nil,
        tags: [String] = [],
        createdBy: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.repoID = repoID
        self.taskID = taskID
        self.title = title
        self.body = body
        self.summary = summary
        self.tags = tags
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}
