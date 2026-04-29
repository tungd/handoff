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

    public func findTask(_ identifier: String) async throws -> TaskRecord {
        let tasks = try await listTasks()

        if let uuid = UUID(uuidString: identifier),
           let task = tasks.first(where: { $0.id == uuid }) {
            return task
        }

        if let task = tasks.first(where: { $0.slug == identifier }) {
            return task
        }

        if let task = tasks.first(where: { $0.id.uuidString.lowercased().hasPrefix(identifier.lowercased()) }) {
            return task
        }

        throw LocalTaskStoreError.taskNotFound(identifier)
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

    public func summary(for task: TaskRecord, eventLimit: Int = 12) async throws -> TaskRunSummary {
        let sessions = try await listSessions(taskID: task.id)
        let events = try await events(for: task.id)
        let claim = try? await currentTaskClaim(taskID: task.id)
        return TaskRunSummary(
            task: task,
            sessions: sessions,
            latestEvents: Array(events.suffix(eventLimit)),
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
