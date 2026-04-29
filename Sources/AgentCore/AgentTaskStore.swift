import Foundation

public protocol AgentTaskStore: Sendable {
    func saveTask(_ task: TaskRecord) async throws
    func listTasks() async throws -> [TaskRecord]
    func findTask(_ identifier: String) async throws -> TaskRecord

    func saveSession(_ session: SessionRecord) async throws
    func listSessions(taskID: UUID?) async throws -> [SessionRecord]
    func latestSession(for taskID: UUID) async throws -> SessionRecord?

    func saveCheckpoint(_ checkpoint: CheckpointRecord) async throws
    func listCheckpoints(taskID: UUID?) async throws -> [CheckpointRecord]

    func claimTask(
        taskID: UUID,
        checkpointID: UUID?,
        ownerName: String,
        ttl: TimeInterval,
        force: Bool
    ) async throws -> TaskClaimRecord
    func currentTaskClaim(taskID: UUID) async throws -> TaskClaimRecord?
    func refreshTaskClaim(taskID: UUID, ownerName: String, ttl: TimeInterval) async throws -> TaskClaimRecord?
    func releaseTaskClaim(taskID: UUID, ownerName: String) async throws -> Bool

    @discardableResult
    func appendEvent(_ event: AgentEvent) async throws -> AgentEvent
    func events(for taskID: UUID) async throws -> [AgentEvent]
    func summary(for task: TaskRecord, eventLimit: Int) async throws -> TaskRunSummary
}

public extension AgentTaskStore {
    func summary(for task: TaskRecord) async throws -> TaskRunSummary {
        try await summary(for: task, eventLimit: 12)
    }

    func claimTask(
        taskID: UUID,
        checkpointID: UUID?,
        ownerName: String,
        ttl: TimeInterval
    ) async throws -> TaskClaimRecord {
        try await claimTask(
            taskID: taskID,
            checkpointID: checkpointID,
            ownerName: ownerName,
            ttl: ttl,
            force: false
        )
    }
}

extension LocalTaskStore: AgentTaskStore {
    public func saveTask(_ task: TaskRecord) async throws {
        try saveTaskSync(task)
    }

    public func listTasks() async throws -> [TaskRecord] {
        try listTasksSync()
    }

    public func findTask(_ identifier: String) async throws -> TaskRecord {
        try findTaskSync(identifier)
    }

    public func saveSession(_ session: SessionRecord) async throws {
        try saveSessionSync(session)
    }

    public func listSessions(taskID: UUID?) async throws -> [SessionRecord] {
        try listSessionsSync(taskID: taskID)
    }

    public func latestSession(for taskID: UUID) async throws -> SessionRecord? {
        try latestSessionSync(for: taskID)
    }

    public func saveCheckpoint(_ checkpoint: CheckpointRecord) async throws {
        try saveCheckpointSync(checkpoint)
    }

    public func listCheckpoints(taskID: UUID?) async throws -> [CheckpointRecord] {
        try listCheckpointsSync(taskID: taskID)
    }

    public func claimTask(
        taskID: UUID,
        checkpointID: UUID?,
        ownerName: String,
        ttl: TimeInterval,
        force: Bool
    ) async throws -> TaskClaimRecord {
        TaskClaimRecord(
            taskID: taskID,
            checkpointID: checkpointID,
            ownerName: ownerName,
            expiresAt: Date().addingTimeInterval(ttl),
            metadata: [
                "store": .string("local"),
                "forced": .bool(force)
            ]
        )
    }

    public func currentTaskClaim(taskID: UUID) async throws -> TaskClaimRecord? {
        nil
    }

    public func refreshTaskClaim(taskID: UUID, ownerName: String, ttl: TimeInterval) async throws -> TaskClaimRecord? {
        nil
    }

    public func releaseTaskClaim(taskID: UUID, ownerName: String) async throws -> Bool {
        false
    }

    public func appendEvent(_ event: AgentEvent) async throws -> AgentEvent {
        try appendEventSync(event)
    }

    public func events(for taskID: UUID) async throws -> [AgentEvent] {
        try eventsSync(for: taskID)
    }

    public func summary(for task: TaskRecord, eventLimit: Int) async throws -> TaskRunSummary {
        try summarySync(for: task, eventLimit: eventLimit)
    }
}
