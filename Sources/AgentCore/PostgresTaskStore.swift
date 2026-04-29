import Foundation
import PostgresNIO

public enum PostgresTaskStoreError: Error, CustomStringConvertible, Sendable {
    case missingTaskID
    case schemaOutOfDate(String)

    public var description: String {
        switch self {
        case .missingTaskID:
            return "events persisted to Postgres must have a task id"
        case let .schemaOutOfDate(detail):
            return "Postgres schema is out of date: \(detail). Run `swift run agentctl db migrate` against this database."
        }
    }
}

public struct PostgresTaskStore: AgentTaskStore {
    private let client: PostgresClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(client: PostgresClient) {
        self.client = client

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func withStore<T>(
        configuration: AgentPostgresConfiguration,
        operation: (PostgresTaskStore) async throws -> T
    ) async throws -> T {
        let client = PostgresClient(configuration: configuration.postgresClientConfiguration)
        let runTask = Task {
            await client.run()
        }
        defer {
            runTask.cancel()
        }

        return try await operation(PostgresTaskStore(client: client))
    }

    public func migrate() async throws {
        let statements = try SchemaLoader.initialMigration()
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for statement in statements {
            try await drain(client.query(PostgresQuery(unsafeSQL: statement)))
        }
    }

    public func saveTask(_ task: TaskRecord) async throws {
        try await drain(client.query("""
            INSERT INTO tasks (id, repo_id, title, slug, backend_preference, state, created_at, updated_at, metadata)
            VALUES (
                \(task.id),
                \(task.repoID),
                \(task.title),
                \(task.slug),
                \(task.backendPreference.rawValue),
                \(task.state.rawValue),
                \(task.createdAt),
                \(task.updatedAt),
                '{}'::jsonb
            )
            ON CONFLICT (id) DO UPDATE SET
                repo_id = EXCLUDED.repo_id,
                title = EXCLUDED.title,
                slug = EXCLUDED.slug,
                backend_preference = EXCLUDED.backend_preference,
                state = EXCLUDED.state,
                updated_at = EXCLUDED.updated_at
            """))
    }

    public func listTasks() async throws -> [TaskRecord] {
        let rows = try await client.query("""
            SELECT id, repo_id, title, slug, backend_preference, state, created_at, updated_at
            FROM tasks
            ORDER BY updated_at DESC
            """)

        return try await decodeTasks(rows)
    }

    public func findTask(_ identifier: String) async throws -> TaskRecord {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if let uuid = UUID(uuidString: identifier) {
            let rows = try await client.query("""
                SELECT id, repo_id, title, slug, backend_preference, state, created_at, updated_at
                FROM tasks
                WHERE id = \(uuid)
                LIMIT 1
                """)
            if let task = try await decodeTasks(rows).first {
                return task
            }
        }

        let slugRows = try await client.query("""
            SELECT id, repo_id, title, slug, backend_preference, state, created_at, updated_at
            FROM tasks
            WHERE slug = \(identifier)
            ORDER BY updated_at DESC
            LIMIT 1
            """)
        if let task = try await decodeTasks(slugRows).first {
            return task
        }

        let idPrefix = "\(identifier.lowercased())%"
        let prefixRows = try await client.query("""
            SELECT id, repo_id, title, slug, backend_preference, state, created_at, updated_at
            FROM tasks
            WHERE lower(id::text) LIKE \(idPrefix)
            ORDER BY updated_at DESC
            LIMIT 1
            """)
        if let task = try await decodeTasks(prefixRows).first {
            return task
        }

        throw LocalTaskStoreError.taskNotFound(identifier)
    }

    private func decodeTasks(_ rows: PostgresRowSequence) async throws -> [TaskRecord] {
        var tasks: [TaskRecord] = []
        for try await (id, repoID, title, slug, backend, state, createdAt, updatedAt) in rows.decode((
            UUID,
            UUID?,
            String,
            String,
            String,
            String,
            Date,
            Date
        ).self) {
            tasks.append(TaskRecord(
                id: id,
                repoID: repoID,
                title: title,
                slug: slug,
                backendPreference: AgentBackend(rawValue: backend) ?? .codex,
                state: TaskState(rawValue: state) ?? .open,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return tasks
    }

    public func saveSession(_ session: SessionRecord) async throws {
        try await drain(client.query("""
            INSERT INTO sessions (id, task_id, backend, backend_session_id, machine_id, cwd, state, started_at, ended_at, metadata)
            VALUES (
                \(session.id),
                \(session.taskID),
                \(session.backend.rawValue),
                \(session.backendSessionID),
                \(session.machineID),
                \(session.cwd),
                \(session.state.rawValue),
                \(session.startedAt),
                \(session.endedAt),
                '{}'::jsonb
            )
            ON CONFLICT (id) DO UPDATE SET
                backend_session_id = EXCLUDED.backend_session_id,
                machine_id = EXCLUDED.machine_id,
                cwd = EXCLUDED.cwd,
                state = EXCLUDED.state,
                ended_at = EXCLUDED.ended_at
            """))
    }

    public func listSessions(taskID: UUID? = nil) async throws -> [SessionRecord] {
        let rows: PostgresRowSequence
        if let taskID {
            rows = try await client.query("""
                SELECT id, task_id, backend, backend_session_id, machine_id, cwd, state, started_at, ended_at
                FROM sessions
                WHERE task_id = \(taskID)
                ORDER BY started_at DESC
                """)
        } else {
            rows = try await client.query("""
                SELECT id, task_id, backend, backend_session_id, machine_id, cwd, state, started_at, ended_at
                FROM sessions
                ORDER BY started_at DESC
                """)
        }

        var sessions: [SessionRecord] = []
        for try await (id, taskID, backend, backendSessionID, machineID, cwd, state, startedAt, endedAt) in rows.decode((
            UUID,
            UUID,
            String,
            String?,
            UUID?,
            String,
            String,
            Date,
            Date?
        ).self) {
            sessions.append(SessionRecord(
                id: id,
                taskID: taskID,
                backend: AgentBackend(rawValue: backend) ?? .codex,
                backendSessionID: backendSessionID,
                machineID: machineID,
                cwd: cwd,
                state: SessionState(rawValue: state) ?? .ended,
                startedAt: startedAt,
                endedAt: endedAt
            ))
        }
        return sessions
    }

    public func latestSession(for taskID: UUID) async throws -> SessionRecord? {
        try await listSessions(taskID: taskID).first
    }

    public func saveCheckpoint(_ checkpoint: CheckpointRecord) async throws {
        let metadataJSON = try jsonString(checkpoint.metadata)
        try await drain(client.query("""
            INSERT INTO checkpoints (id, task_id, repo_id, machine_id, branch, commit_sha, remote_name, pushed_at, created_at, dirty_summary, metadata)
            VALUES (
                \(checkpoint.id),
                \(checkpoint.taskID),
                \(checkpoint.repoID),
                \(checkpoint.machineID),
                \(checkpoint.branch),
                \(checkpoint.commitSHA),
                \(checkpoint.remoteName),
                \(checkpoint.pushedAt),
                \(checkpoint.createdAt),
                '{}'::jsonb,
                \(metadataJSON)::jsonb
            )
            ON CONFLICT (id) DO UPDATE SET
                repo_id = EXCLUDED.repo_id,
                machine_id = EXCLUDED.machine_id,
                branch = EXCLUDED.branch,
                commit_sha = EXCLUDED.commit_sha,
                remote_name = EXCLUDED.remote_name,
                pushed_at = EXCLUDED.pushed_at,
                metadata = EXCLUDED.metadata
            """))
    }

    public func listCheckpoints(taskID: UUID? = nil) async throws -> [CheckpointRecord] {
        let rows: PostgresRowSequence
        if let taskID {
            rows = try await client.query("""
                SELECT id, task_id, repo_id, machine_id, branch, commit_sha, remote_name, pushed_at, created_at, metadata::text
                FROM checkpoints
                WHERE task_id = \(taskID)
                ORDER BY created_at DESC
                """)
        } else {
            rows = try await client.query("""
                SELECT id, task_id, repo_id, machine_id, branch, commit_sha, remote_name, pushed_at, created_at, metadata::text
                FROM checkpoints
                ORDER BY created_at DESC
                """)
        }

        var checkpoints: [CheckpointRecord] = []
        for try await (id, taskID, repoID, machineID, branch, commitSHA, remoteName, pushedAt, createdAt, metadataText) in rows.decode((
            UUID,
            UUID,
            UUID?,
            UUID?,
            String,
            String?,
            String,
            Date?,
            Date,
            String
        ).self) {
            let metadata = try decoder.decode([String: JSONValue].self, from: Data(metadataText.utf8))
            checkpoints.append(CheckpointRecord(
                id: id,
                taskID: taskID,
                repoID: repoID,
                machineID: machineID,
                branch: branch,
                commitSHA: commitSHA,
                remoteName: remoteName,
                pushedAt: pushedAt,
                createdAt: createdAt,
                metadata: metadata
            ))
        }
        return checkpoints
    }

    public func saveArtifact(_ artifact: ArtifactRecord) async throws {
        let metadataJSON = try jsonString(artifact.metadata)
        try await drain(client.query("""
            INSERT INTO artifacts (id, task_id, session_id, kind, title, content_ref, content_type, created_at, metadata)
            VALUES (
                \(artifact.id),
                \(artifact.taskID),
                \(artifact.sessionID),
                \(artifact.kind.rawValue),
                \(artifact.title),
                \(artifact.contentRef),
                \(artifact.contentType),
                \(artifact.createdAt),
                \(metadataJSON)::jsonb
            )
            ON CONFLICT (id) DO UPDATE SET
                session_id = EXCLUDED.session_id,
                kind = EXCLUDED.kind,
                title = EXCLUDED.title,
                content_ref = EXCLUDED.content_ref,
                content_type = EXCLUDED.content_type,
                metadata = EXCLUDED.metadata
            """))
    }

    public func listArtifacts(taskID: UUID? = nil) async throws -> [ArtifactRecord] {
        let rows: PostgresRowSequence
        if let taskID {
            rows = try await client.query("""
                SELECT id, task_id, session_id, kind, title, content_ref, content_type, created_at, metadata::text
                FROM artifacts
                WHERE task_id = \(taskID)
                ORDER BY created_at DESC
                """)
        } else {
            rows = try await client.query("""
                SELECT id, task_id, session_id, kind, title, content_ref, content_type, created_at, metadata::text
                FROM artifacts
                ORDER BY created_at DESC
                """)
        }

        var artifacts: [ArtifactRecord] = []
        for try await (id, taskID, sessionID, kind, title, contentRef, contentType, createdAt, metadataText) in rows.decode((
            UUID,
            UUID,
            UUID?,
            String,
            String,
            String,
            String?,
            Date,
            String
        ).self) {
            let metadata = try decoder.decode([String: JSONValue].self, from: Data(metadataText.utf8))
            artifacts.append(ArtifactRecord(
                id: id,
                taskID: taskID,
                sessionID: sessionID,
                kind: ArtifactKind(rawValue: kind) ?? .handoffManifest,
                title: title,
                contentRef: contentRef,
                contentType: contentType,
                createdAt: createdAt,
                metadata: metadata
            ))
        }
        return artifacts
    }

    @discardableResult
    public func writeMemory(_ memory: MemoryItem) async throws -> MemoryItem {
        let metadataJSON = try jsonString(memory.metadata)
        try await drain(client.query("""
            INSERT INTO memory_items (
                id,
                scope_kind,
                scope_id,
                repo_id,
                task_id,
                title,
                body,
                summary,
                tags,
                status,
                created_by,
                expires_at,
                archived_at,
                created_at,
                updated_at,
                metadata
            )
            VALUES (
                \(memory.id),
                \(memory.scopeKind.rawValue),
                \(memory.scopeID),
                \(memory.repoID),
                \(memory.taskID),
                \(memory.title),
                \(memory.body),
                \(memory.summary),
                \(memory.tags),
                \(memory.status.rawValue),
                \(memory.createdBy),
                \(memory.expiresAt),
                \(memory.archivedAt),
                \(memory.createdAt),
                \(memory.updatedAt),
                \(metadataJSON)::jsonb
            )
            ON CONFLICT (id) DO UPDATE SET
                scope_kind = EXCLUDED.scope_kind,
                scope_id = EXCLUDED.scope_id,
                repo_id = EXCLUDED.repo_id,
                task_id = EXCLUDED.task_id,
                title = EXCLUDED.title,
                body = EXCLUDED.body,
                summary = EXCLUDED.summary,
                tags = EXCLUDED.tags,
                status = EXCLUDED.status,
                created_by = EXCLUDED.created_by,
                expires_at = EXCLUDED.expires_at,
                archived_at = EXCLUDED.archived_at,
                updated_at = EXCLUDED.updated_at,
                metadata = EXCLUDED.metadata
            """))

        return memory
    }

    public func searchMemory(_ query: String, limit: Int) async throws -> [MemorySearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmedQuery.isEmpty else {
            return []
        }

        let boundedLimit = min(limit, 100)
        let rows = try await client.query("""
            WITH memory_query AS (
                SELECT websearch_to_tsquery('english', \(trimmedQuery)) AS tsquery
            )
            SELECT
                id,
                scope_kind,
                scope_id,
                repo_id,
                task_id,
                title,
                body,
                summary,
                to_json(tags)::text,
                status,
                created_by,
                expires_at,
                archived_at,
                created_at,
                updated_at,
                metadata::text,
                ts_rank(search_vector, memory_query.tsquery)::double precision AS score
            FROM memory_items, memory_query
            WHERE memory_query.tsquery @@ search_vector
              AND status = 'active'
              AND archived_at IS NULL
              AND (expires_at IS NULL OR expires_at > now())
            ORDER BY score DESC, created_at DESC
            LIMIT \(boundedLimit)
            """)

        var results: [MemorySearchResult] = []
        for row in try await decodeMemoryRows(rows, includeScore: true) {
            results.append(MemorySearchResult(item: row.item, score: row.score ?? 0))
        }
        return results
    }

    public func recentMemories(limit: Int) async throws -> [MemoryItem] {
        guard limit > 0 else {
            return []
        }

        let boundedLimit = min(limit, 100)
        let rows = try await client.query("""
            SELECT
                id,
                scope_kind,
                scope_id,
                repo_id,
                task_id,
                title,
                body,
                summary,
                to_json(tags)::text,
                status,
                created_by,
                expires_at,
                archived_at,
                created_at,
                updated_at,
                metadata::text
            FROM memory_items
            WHERE status = 'active'
              AND archived_at IS NULL
              AND (expires_at IS NULL OR expires_at > now())
            ORDER BY created_at DESC, updated_at DESC
            LIMIT \(boundedLimit)
            """)

        var memories: [MemoryItem] = []
        for row in try await decodeMemoryRows(rows, includeScore: false) {
            memories.append(row.item)
        }
        return memories
    }

    @discardableResult
    public func archiveMemory(id: UUID) async throws -> MemoryItem {
        let now = Date()
        let rows = try await client.query("""
            UPDATE memory_items
            SET status = 'archived',
                archived_at = COALESCE(archived_at, \(now)),
                updated_at = \(now)
            WHERE id = \(id)
            RETURNING
                id,
                scope_kind,
                scope_id,
                repo_id,
                task_id,
                title,
                body,
                summary,
                to_json(tags)::text,
                status,
                created_by,
                expires_at,
                archived_at,
                created_at,
                updated_at,
                metadata::text
            """)

        for row in try await decodeMemoryRows(rows, includeScore: false) {
            return row.item
        }

        throw LocalTaskStoreError.memoryNotFound(id)
    }

    public func claimTask(
        taskID: UUID,
        checkpointID: UUID?,
        ownerName: String,
        ttl: TimeInterval,
        force: Bool
    ) async throws -> TaskClaimRecord {
        try await ensureTaskClaimsSchema()
        let now = Date()
        let expiresAt = now.addingTimeInterval(ttl)
        let metadata: [String: JSONValue] = [
            "store": .string("postgres"),
            "forced": .bool(force)
        ]
        let metadataJSON = try jsonString(metadata)
        let rows = try await client.query("""
            INSERT INTO task_claims (task_id, checkpoint_id, owner_name, claimed_at, expires_at, metadata)
            VALUES (
                \(taskID),
                \(checkpointID),
                \(ownerName),
                \(now),
                \(expiresAt),
                \(metadataJSON)::jsonb
            )
            ON CONFLICT (task_id) DO UPDATE SET
                checkpoint_id = EXCLUDED.checkpoint_id,
                owner_name = EXCLUDED.owner_name,
                claimed_at = EXCLUDED.claimed_at,
                expires_at = EXCLUDED.expires_at,
                metadata = EXCLUDED.metadata
            WHERE task_claims.expires_at < now()
               OR task_claims.owner_name = EXCLUDED.owner_name
               OR \(force)
            RETURNING task_id, checkpoint_id, owner_name, claimed_at, expires_at, metadata::text
            """)

        if let claim = try await decodeTaskClaims(rows).first {
            return claim
        }

        if let existing = try await currentTaskClaim(taskID: taskID) {
            throw TaskClaimError.alreadyClaimed(existing)
        }

        throw TaskClaimError.alreadyClaimed(TaskClaimRecord(
            taskID: taskID,
            checkpointID: checkpointID,
            ownerName: "unknown",
            expiresAt: expiresAt
        ))
    }

    public func currentTaskClaim(taskID: UUID) async throws -> TaskClaimRecord? {
        try await ensureTaskClaimsSchema()
        let rows = try await client.query("""
            SELECT task_id, checkpoint_id, owner_name, claimed_at, expires_at, metadata::text
            FROM task_claims
            WHERE task_id = \(taskID)
            """)

        return try await decodeTaskClaims(rows).first
    }

    public func refreshTaskClaim(taskID: UUID, ownerName: String, ttl: TimeInterval) async throws -> TaskClaimRecord? {
        try await ensureTaskClaimsSchema()
        let expiresAt = Date().addingTimeInterval(ttl)
        let rows = try await client.query("""
            UPDATE task_claims
            SET expires_at = \(expiresAt),
                metadata = metadata || '{"refreshed": true}'::jsonb
            WHERE task_id = \(taskID)
              AND owner_name = \(ownerName)
            RETURNING task_id, checkpoint_id, owner_name, claimed_at, expires_at, metadata::text
            """)

        if let claim = try await decodeTaskClaims(rows).first {
            return claim
        }

        if let existing = try await currentTaskClaim(taskID: taskID),
           existing.ownerName != ownerName,
           existing.expiresAt > Date() {
            throw TaskClaimError.alreadyClaimed(existing)
        }
        return nil
    }

    public func releaseTaskClaim(taskID: UUID, ownerName: String) async throws -> Bool {
        try await ensureTaskClaimsSchema()
        let rows = try await client.query("""
            DELETE FROM task_claims
            WHERE task_id = \(taskID)
              AND owner_name = \(ownerName)
            RETURNING task_id
            """)

        for try await _ in rows.decode(UUID.self) {
            return true
        }
        return false
    }

    @discardableResult
    public func appendEvent(_ event: AgentEvent) async throws -> AgentEvent {
        guard let taskID = event.taskID else {
            throw PostgresTaskStoreError.missingTaskID
        }

        let sequence: Int64
        if let existingSequence = event.sequence {
            sequence = existingSequence
        } else {
            sequence = try await nextEventSequence(taskID: taskID)
        }

        var stored = event
        stored.sequence = sequence
        let payloadJSON = try jsonString(stored.payload)

        try await drain(client.query("""
            INSERT INTO events (id, task_id, session_id, seq, kind, occurred_at, payload)
            VALUES (
                \(stored.id),
                \(taskID),
                \(stored.sessionID),
                \(sequence),
                \(stored.kind.rawValue),
                \(stored.occurredAt),
                \(payloadJSON)::jsonb
            )
            ON CONFLICT (id) DO NOTHING
            """))

        return stored
    }

    public func events(for taskID: UUID) async throws -> [AgentEvent] {
        let rows = try await client.query("""
            SELECT id, task_id, session_id, seq, kind, occurred_at, payload::text
            FROM events
            WHERE task_id = \(taskID)
            ORDER BY seq ASC
            """)

        var events: [AgentEvent] = []
        for try await (id, taskID, sessionID, sequence, kind, occurredAt, payloadText) in rows.decode((
            UUID,
            UUID?,
            UUID?,
            Int64?,
            String,
            Date,
            String
        ).self) {
            let payloadData = Data(payloadText.utf8)
            let payload = try decoder.decode([String: JSONValue].self, from: payloadData)
            events.append(AgentEvent(
                id: id,
                taskID: taskID,
                sessionID: sessionID,
                sequence: sequence,
                kind: EventKind(rawValue: kind) ?? .backendEvent,
                occurredAt: occurredAt,
                payload: payload
            ))
        }
        return events
    }

    public func recentEvents(for taskID: UUID, limit: Int) async throws -> [AgentEvent] {
        guard limit > 0 else {
            return []
        }
        let boundedLimit = min(limit, 500)
        let rows = try await client.query("""
            SELECT id, task_id, session_id, seq, kind, occurred_at, payload::text
            FROM events
            WHERE task_id = \(taskID)
            ORDER BY seq DESC
            LIMIT \(boundedLimit)
            """)

        var events: [AgentEvent] = []
        for try await (id, taskID, sessionID, sequence, kind, occurredAt, payloadText) in rows.decode((
            UUID,
            UUID?,
            UUID?,
            Int64?,
            String,
            Date,
            String
        ).self) {
            let payloadData = Data(payloadText.utf8)
            let payload = try decoder.decode([String: JSONValue].self, from: payloadData)
            events.append(AgentEvent(
                id: id,
                taskID: taskID,
                sessionID: sessionID,
                sequence: sequence,
                kind: EventKind(rawValue: kind) ?? .backendEvent,
                occurredAt: occurredAt,
                payload: payload
            ))
        }
        return events.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }

    public func recentEvents(for taskID: UUID, limit: Int, kinds: [EventKind]) async throws -> [AgentEvent] {
        guard limit > 0, !kinds.isEmpty else {
            return []
        }
        let boundedLimit = min(limit, 500)
        let kindList = kinds
            .map { "'\($0.rawValue.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
        let rows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT id, task_id, session_id, seq, kind, occurred_at, payload::text
            FROM events
            WHERE task_id = '\(taskID.uuidString)'::uuid
              AND kind IN (\(kindList))
            ORDER BY seq DESC
            LIMIT \(boundedLimit)
            """))

        var events: [AgentEvent] = []
        for try await (id, taskID, sessionID, sequence, kind, occurredAt, payloadText) in rows.decode((
            UUID,
            UUID?,
            UUID?,
            Int64?,
            String,
            Date,
            String
        ).self) {
            let payloadData = Data(payloadText.utf8)
            let payload = try decoder.decode([String: JSONValue].self, from: payloadData)
            events.append(AgentEvent(
                id: id,
                taskID: taskID,
                sessionID: sessionID,
                sequence: sequence,
                kind: EventKind(rawValue: kind) ?? .backendEvent,
                occurredAt: occurredAt,
                payload: payload
            ))
        }
        return events.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }

    public func summary(for task: TaskRecord, eventLimit: Int = 12) async throws -> TaskRunSummary {
        let sessions = try await listSessions(taskID: task.id)
        let events = try await recentEvents(for: task.id, limit: eventLimit)
        let claim = try? await currentTaskClaim(taskID: task.id)
        return TaskRunSummary(
            task: task,
            sessions: sessions,
            latestEvents: events,
            currentClaim: claim
        )
    }

    private func decodeTaskClaims(_ rows: PostgresRowSequence) async throws -> [TaskClaimRecord] {
        var claims: [TaskClaimRecord] = []
        for try await (taskID, checkpointID, ownerName, claimedAt, expiresAt, metadataText) in rows.decode((
            UUID,
            UUID?,
            String,
            Date,
            Date,
            String
        ).self) {
            let metadata = try decoder.decode([String: JSONValue].self, from: Data(metadataText.utf8))
            claims.append(TaskClaimRecord(
                taskID: taskID,
                checkpointID: checkpointID,
                ownerName: ownerName,
                claimedAt: claimedAt,
                expiresAt: expiresAt,
                metadata: metadata
            ))
        }
        return claims
    }

    private func decodeMemoryRows(
        _ rows: PostgresRowSequence,
        includeScore: Bool
    ) async throws -> [(item: MemoryItem, score: Double?)] {
        var memories: [(item: MemoryItem, score: Double?)] = []

        if includeScore {
            for try await (
                id,
                scopeKind,
                scopeID,
                repoID,
                taskID,
                title,
                body,
                summary,
                tagsText,
                status,
                createdBy,
                expiresAt,
                archivedAt,
                createdAt,
                updatedAt,
                metadataText,
                score
            ) in rows.decode((
                UUID,
                String,
                UUID?,
                UUID?,
                UUID?,
                String,
                String,
                String?,
                String,
                String,
                String,
                Date?,
                Date?,
                Date,
                Date,
                String,
                Double
            ).self) {
                memories.append(try makeMemoryRow(
                    id: id,
                    scopeKind: scopeKind,
                    scopeID: scopeID,
                    repoID: repoID,
                    taskID: taskID,
                    title: title,
                    body: body,
                    summary: summary,
                    tagsText: tagsText,
                    status: status,
                    createdBy: createdBy,
                    expiresAt: expiresAt,
                    archivedAt: archivedAt,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    metadataText: metadataText,
                    score: score
                ))
            }
        } else {
            for try await (
                id,
                scopeKind,
                scopeID,
                repoID,
                taskID,
                title,
                body,
                summary,
                tagsText,
                status,
                createdBy,
                expiresAt,
                archivedAt,
                createdAt,
                updatedAt,
                metadataText
            ) in rows.decode((
                UUID,
                String,
                UUID?,
                UUID?,
                UUID?,
                String,
                String,
                String?,
                String,
                String,
                String,
                Date?,
                Date?,
                Date,
                Date,
                String
            ).self) {
                memories.append(try makeMemoryRow(
                    id: id,
                    scopeKind: scopeKind,
                    scopeID: scopeID,
                    repoID: repoID,
                    taskID: taskID,
                    title: title,
                    body: body,
                    summary: summary,
                    tagsText: tagsText,
                    status: status,
                    createdBy: createdBy,
                    expiresAt: expiresAt,
                    archivedAt: archivedAt,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    metadataText: metadataText,
                    score: nil
                ))
            }
        }

        return memories
    }

    private func makeMemoryRow(
        id: UUID,
        scopeKind: String,
        scopeID: UUID?,
        repoID: UUID?,
        taskID: UUID?,
        title: String,
        body: String,
        summary: String?,
        tagsText: String,
        status: String,
        createdBy: String,
        expiresAt: Date?,
        archivedAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        metadataText: String,
        score: Double?
    ) throws -> (item: MemoryItem, score: Double?) {
        let tags = try decoder.decode([String].self, from: Data(tagsText.utf8))
        let metadata = try decoder.decode([String: JSONValue].self, from: Data(metadataText.utf8))
        return (
            item: MemoryItem(
                id: id,
                scopeKind: MemoryScopeKind(rawValue: scopeKind) ?? .repo,
                scopeID: scopeID,
                repoID: repoID,
                taskID: taskID,
                title: title,
                body: body,
                summary: summary,
                tags: tags,
                status: MemoryStatus(rawValue: status) ?? .active,
                createdBy: createdBy,
                expiresAt: expiresAt,
                archivedAt: archivedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: metadata
            ),
            score: score
        )
    }

    private func ensureTaskClaimsSchema() async throws {
        let rows = try await client.query("""
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name = 'task_claims'
            )
            """)

        for try await exists in rows.decode(Bool.self) {
            if exists {
                return
            }
            throw PostgresTaskStoreError.schemaOutOfDate("missing table task_claims")
        }

        throw PostgresTaskStoreError.schemaOutOfDate("could not verify table task_claims")
    }

    private func nextEventSequence(taskID: UUID) async throws -> Int64 {
        let rows = try await client.query("""
            SELECT COALESCE(MAX(seq), 0) + 1
            FROM events
            WHERE task_id = \(taskID)
            """)

        for try await value in rows.decode(Int64.self) {
            return value
        }
        return 1
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func drain(_ rows: PostgresRowSequence) async throws {
        for try await _ in rows {}
    }
}
