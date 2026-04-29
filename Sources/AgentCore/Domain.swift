import Foundation

public enum AgentBackend: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case pi
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
    case taskClaimed = "task.claimed"
    case taskClaimRefreshed = "task.claim.refreshed"
    case taskClaimReleased = "task.claim.released"
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

public enum MemoryStatus: String, Codable, CaseIterable, Sendable {
    case active
    case archived
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

    public func withTitle(_ newTitle: String) -> TaskRecord {
        var copy = self
        copy.title = newTitle
        copy.updatedAt = Date()
        return copy
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
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        repoID: UUID? = nil,
        machineID: UUID? = nil,
        branch: String,
        commitSHA: String? = nil,
        remoteName: String = "origin",
        pushedAt: Date? = nil,
        createdAt: Date = Date(),
        metadata: [String: JSONValue] = [:]
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
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case repoID
        case machineID
        case branch
        case commitSHA
        case remoteName
        case pushedAt
        case createdAt
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        repoID = try container.decodeIfPresent(UUID.self, forKey: .repoID)
        machineID = try container.decodeIfPresent(UUID.self, forKey: .machineID)
        branch = try container.decode(String.self, forKey: .branch)
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
        remoteName = try container.decode(String.self, forKey: .remoteName)
        pushedAt = try container.decodeIfPresent(Date.self, forKey: .pushedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

public struct TaskClaimRecord: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var checkpointID: UUID?
    public var ownerName: String
    public var claimedAt: Date
    public var expiresAt: Date
    public var metadata: [String: JSONValue]

    public init(
        taskID: UUID,
        checkpointID: UUID? = nil,
        ownerName: String,
        claimedAt: Date = Date(),
        expiresAt: Date,
        metadata: [String: JSONValue] = [:]
    ) {
        self.taskID = taskID
        self.checkpointID = checkpointID
        self.ownerName = ownerName
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
        self.metadata = metadata
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case handoffManifest = "handoff_manifest"
    case commandOutput = "command_output"
    case testResult = "test_result"
    case generatedFile = "generated_file"
    case transcriptExport = "transcript_export"
    case continuationPrompt = "continuation_prompt"
}

public struct ArtifactRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var taskID: UUID
    public var sessionID: UUID?
    public var kind: ArtifactKind
    public var title: String
    public var contentRef: String
    public var contentType: String?
    public var createdAt: Date
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        sessionID: UUID? = nil,
        kind: ArtifactKind,
        title: String,
        contentRef: String,
        contentType: String? = nil,
        createdAt: Date = Date(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.contentRef = contentRef
        self.contentType = contentType
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public enum TaskClaimError: Error, CustomStringConvertible, Sendable {
    case alreadyClaimed(TaskClaimRecord)

    public var description: String {
        switch self {
        case let .alreadyClaimed(claim):
            let expiry = ISO8601DateFormatter().string(from: claim.expiresAt)
            return "task is already claimed by \(claim.ownerName) until \(expiry)"
        }
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
    public var status: MemoryStatus
    public var createdBy: String
    public var expiresAt: Date?
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: JSONValue]

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
        status: MemoryStatus = .active,
        createdBy: String,
        expiresAt: Date? = nil,
        archivedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: JSONValue] = [:]
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
        self.status = status
        self.createdBy = createdBy
        self.expiresAt = expiresAt
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case scopeKind
        case scopeID
        case repoID
        case taskID
        case title
        case body
        case summary
        case tags
        case status
        case createdBy
        case expiresAt
        case archivedAt
        case createdAt
        case updatedAt
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        id = try container.decode(UUID.self, forKey: .id)
        scopeKind = try container.decode(MemoryScopeKind.self, forKey: .scopeKind)
        scopeID = try container.decodeIfPresent(UUID.self, forKey: .scopeID)
        repoID = try container.decodeIfPresent(UUID.self, forKey: .repoID)
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        status = try container.decodeIfPresent(MemoryStatus.self, forKey: .status) ?? .active
        createdBy = try container.decode(String.self, forKey: .createdBy)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.createdAt = createdAt
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

public struct MemorySearchResult: Codable, Equatable, Sendable {
    public var item: MemoryItem
    public var score: Double

    public init(item: MemoryItem, score: Double) {
        self.item = item
        self.score = score
    }
}

public struct SkillRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var description: String?
    public var content: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        content: String,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
