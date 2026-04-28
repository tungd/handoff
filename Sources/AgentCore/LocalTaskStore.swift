import Foundation

public enum LocalTaskStoreError: Error, CustomStringConvertible, Sendable {
    case taskNotFound(String)
    case malformedEventLine(URL)

    public var description: String {
        switch self {
        case let .taskNotFound(identifier):
            return "task not found: \(identifier)"
        case let .malformedEventLine(url):
            return "malformed event line in \(url.path)"
        }
    }
}

public struct TaskRunSummary: Codable, Equatable, Sendable {
    public var task: TaskRecord
    public var sessions: [SessionRecord]
    public var latestEvents: [AgentEvent]

    public init(task: TaskRecord, sessions: [SessionRecord], latestEvents: [AgentEvent]) {
        self.task = task
        self.sessions = sessions
        self.latestEvents = latestEvents
    }
}

public struct LocalTaskStore: Sendable {
    public let root: URL

    private var tasksDirectory: URL { root.appendingPathComponent("tasks", isDirectory: true) }
    private var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var eventsDirectory: URL { root.appendingPathComponent("events", isDirectory: true) }
    private var checkpointsDirectory: URL { root.appendingPathComponent("checkpoints", isDirectory: true) }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: checkpointsDirectory, withIntermediateDirectories: true)
    }

    public func saveTask(_ task: TaskRecord) throws {
        try prepare()
        let data = try encoder.encode(task)
        try data.write(to: taskURL(task.id), options: [.atomic])
    }

    public func saveTaskSync(_ task: TaskRecord) throws {
        try saveTask(task)
    }

    public func listTasks() throws -> [TaskRecord] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        return try files
            .map { try decoder.decode(TaskRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func listTasksSync() throws -> [TaskRecord] {
        try listTasks()
    }

    public func findTask(_ identifier: String) throws -> TaskRecord {
        let tasks = try listTasks()

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

    public func findTaskSync(_ identifier: String) throws -> TaskRecord {
        try findTask(identifier)
    }

    public func saveSession(_ session: SessionRecord) throws {
        try prepare()
        let data = try encoder.encode(session)
        try data.write(to: sessionURL(session.id), options: [.atomic])
    }

    public func saveSessionSync(_ session: SessionRecord) throws {
        try saveSession(session)
    }

    public func listSessions(taskID: UUID? = nil) throws -> [SessionRecord] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        let sessions = try files.map { try decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
        return sessions
            .filter { taskID == nil || $0.taskID == taskID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func listSessionsSync(taskID: UUID? = nil) throws -> [SessionRecord] {
        try listSessions(taskID: taskID)
    }

    public func latestSession(for taskID: UUID) throws -> SessionRecord? {
        try listSessions(taskID: taskID).first
    }

    public func latestSessionSync(for taskID: UUID) throws -> SessionRecord? {
        try latestSession(for: taskID)
    }

    public func saveCheckpoint(_ checkpoint: CheckpointRecord) throws {
        try prepare()
        let data = try encoder.encode(checkpoint)
        try data.write(to: checkpointURL(checkpoint.id), options: [.atomic])
    }

    public func saveCheckpointSync(_ checkpoint: CheckpointRecord) throws {
        try saveCheckpoint(checkpoint)
    }

    public func listCheckpoints(taskID: UUID? = nil) throws -> [CheckpointRecord] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: checkpointsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        let checkpoints = try files.map { try decoder.decode(CheckpointRecord.self, from: Data(contentsOf: $0)) }
        return checkpoints
            .filter { taskID == nil || $0.taskID == taskID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func listCheckpointsSync(taskID: UUID? = nil) throws -> [CheckpointRecord] {
        try listCheckpoints(taskID: taskID)
    }

    @discardableResult
    public func appendEvent(_ event: AgentEvent) throws -> AgentEvent {
        try prepare()
        guard let taskID = event.taskID else {
            return event
        }

        let url = eventsURL(taskID)
        let sequence: Int64
        if let existingSequence = event.sequence {
            sequence = existingSequence
        } else {
            sequence = Int64(try events(for: taskID).count + 1)
        }
        var stored = event
        stored.sequence = sequence

        let data = try encoder.encode(stored)
        guard let line = String(data: data, encoding: .utf8) else {
            return stored
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        return stored
    }

    public func appendEventSync(_ event: AgentEvent) throws -> AgentEvent {
        try appendEvent(event)
    }

    public func events(for taskID: UUID) throws -> [AgentEvent] {
        try prepare()
        let url = eventsURL(taskID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                guard let data = String(line).data(using: .utf8) else {
                    throw LocalTaskStoreError.malformedEventLine(url)
                }
                return try decoder.decode(AgentEvent.self, from: data)
            }
            .sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }

    public func eventsSync(for taskID: UUID) throws -> [AgentEvent] {
        try events(for: taskID)
    }

    public func summary(for task: TaskRecord, eventLimit: Int = 12) throws -> TaskRunSummary {
        let sessions = try listSessions(taskID: task.id)
        let events = try events(for: task.id)
        return TaskRunSummary(
            task: task,
            sessions: sessions,
            latestEvents: Array(events.suffix(eventLimit))
        )
    }

    public func summarySync(for task: TaskRecord, eventLimit: Int = 12) throws -> TaskRunSummary {
        try summary(for: task, eventLimit: eventLimit)
    }

    private func taskURL(_ id: UUID) -> URL {
        tasksDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func sessionURL(_ id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func eventsURL(_ taskID: UUID) -> URL {
        eventsDirectory.appendingPathComponent("\(taskID.uuidString).jsonl")
    }

    private func checkpointURL(_ id: UUID) -> URL {
        checkpointsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}

public enum StorePathResolver {
    public static func defaultRoot(cwd: URL, snapshot: RepositorySnapshot? = nil) -> URL {
        let rootPath = snapshot?.rootPath
        let base = rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? cwd
        return base.appendingPathComponent(".agentctl", isDirectory: true)
    }
}
