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

    func saveArtifact(_ artifact: ArtifactRecord) async throws
    func listArtifacts(taskID: UUID?) async throws -> [ArtifactRecord]

    @discardableResult
    func writeMemory(_ memory: MemoryItem) async throws -> MemoryItem
    func searchMemory(_ query: String, limit: Int) async throws -> [MemorySearchResult]
    func recentMemories(limit: Int) async throws -> [MemoryItem]
    @discardableResult
    func archiveMemory(id: UUID) async throws -> MemoryItem

    func listSkills() async throws -> [SkillRecord]

    @discardableResult
    func writeSkill(_ skill: SkillRecord) async throws -> SkillRecord

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
    func recentEvents(for taskID: UUID, limit: Int) async throws -> [AgentEvent]
    func recentEvents(for taskID: UUID, limit: Int, kinds: [EventKind]) async throws -> [AgentEvent]
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

    public func saveArtifact(_ artifact: ArtifactRecord) async throws {
        try saveArtifactSync(artifact)
    }

    public func listArtifacts(taskID: UUID?) async throws -> [ArtifactRecord] {
        try listArtifactsSync(taskID: taskID)
    }

    @discardableResult
    public func writeMemory(_ memory: MemoryItem) async throws -> MemoryItem {
        try writeMemorySync(memory)
    }

    public func searchMemory(_ query: String, limit: Int) async throws -> [MemorySearchResult] {
        try searchMemorySync(query, limit: limit)
    }

    public func recentMemories(limit: Int) async throws -> [MemoryItem] {
        try recentMemoriesSync(limit: limit)
    }

    @discardableResult
    public func archiveMemory(id: UUID) async throws -> MemoryItem {
        try archiveMemorySync(id: id)
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

    public func recentEvents(for taskID: UUID, limit: Int) async throws -> [AgentEvent] {
        guard limit > 0 else {
            return []
        }
        return Array(try await events(for: taskID).suffix(limit))
    }

    public func recentEvents(for taskID: UUID, limit: Int, kinds: [EventKind]) async throws -> [AgentEvent] {
        guard limit > 0, !kinds.isEmpty else {
            return []
        }
        let allowed = Set(kinds)
        return Array(try await events(for: taskID).filter { allowed.contains($0.kind) }.suffix(limit))
    }

    public func summary(for task: TaskRecord, eventLimit: Int) async throws -> TaskRunSummary {
        try summarySync(for: task, eventLimit: eventLimit)
    }

    public func listSkills() async throws -> [SkillRecord] {
        // Skills require Postgres store
        return []
    }

    @discardableResult
    public func writeSkill(_ skill: SkillRecord) async throws -> SkillRecord {
        // Skills require Postgres store - return unchanged
        return skill
    }
}
