import Foundation
import Testing
@testable import AgentCore

@Test
func jsonValueRoundTripsNestedObjects() throws {
    let value: JSONValue = .object([
        "text": .string("hello"),
        "count": .int(2),
        "nested": .array([.bool(true), .null])
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == value)
}

@Test
func agentEventsEncodePayloads() throws {
    let taskID = UUID()
    let sessionID = UUID()
    let event = AgentEvent(
        taskID: taskID,
        sessionID: sessionID,
        sequence: 42,
        kind: .assistantDelta,
        payload: [
            "delta": .string("hello"),
            "tokens": .int(3),
            "metadata": .object(["backend": .string("codex")])
        ]
    )

    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

    #expect(decoded.taskID == taskID)
    #expect(decoded.sessionID == sessionID)
    #expect(decoded.sequence == 42)
    #expect(decoded.kind == .assistantDelta)
    #expect(decoded.payload["delta"] == .string("hello"))
    #expect(decoded.payload["tokens"] == .int(3))
    #expect(decoded.payload["metadata"] == .object(["backend": .string("codex")]))
}

@Test
func slugGenerationIsStable() {
    #expect(Slug.make("Fix Auth Retry!") == "fix-auth-retry")
    #expect(Slug.make("   ") == "task")
    #expect(Slug.make("One---Two___Three") == "one-two-three")
}

@Test
func slugGenerationRespectsMaxLengthWithoutTrailingDash() {
    #expect(Slug.make("Alpha Beta Gamma", maxLength: 10) == "alpha-beta")
}

@Test
func taskRecordsDefaultToCodexAndOpenState() {
    let task = TaskRecord(title: "Fix flaky tests", slug: Slug.make("Fix flaky tests"))

    #expect(task.backendPreference == .codex)
    #expect(task.state == .open)
    #expect(task.slug == "fix-flaky-tests")
}

@Test
func schemaLoaderFindsInitialMigration() throws {
    let schema = try SchemaLoader.initialMigration()

    #expect(schema.contains("CREATE TABLE IF NOT EXISTS tasks"))
    #expect(schema.contains("CREATE TABLE IF NOT EXISTS memory_items"))
    #expect(schema.contains("memory_items_search_idx"))
    #expect(schema.contains("events_task_seq_unique_idx"))
}

@Test
func backendDescriptorsCaptureInitialBackendPriorities() {
    let codex = CodexBackendAdapter()
    let claude = ClaudeBackendAdapter()

    #expect(codex.descriptor.backend == .codex)
    #expect(codex.descriptor.capabilities.contains(.execJSON))
    #expect(codex.descriptor.capabilities.contains(.appServer))
    #expect(codex.descriptor.capabilities.contains(.resumeNativeSession))
    #expect(codex.appServerCommand == ["codex", "app-server", "--listen", "stdio://"])
    #expect(codex.execServerCommand == ["codex", "exec-server"])

    #expect(claude.descriptor.backend == .claude)
    #expect(claude.descriptor.capabilities.contains(.structuredInput))
    #expect(claude.streamJSONCommand == [
        "claude",
        "--output-format",
        "stream-json",
        "--input-format",
        "stream-json"
    ])
}

@Test
func repositoryInspectorReturnsNonGitSnapshotWhenRootLookupFails() throws {
    let inspector = RepositoryInspector(git: GitRunner(
        runner: FakeProcessRunner(responses: [
            gitKey("rev-parse", "--show-toplevel"): ProcessResult(
                exitCode: 128,
                stdout: "",
                stderr: "not a git repository"
            )
        ])
    ))

    let snapshot = try inspector.inspect(path: URL(fileURLWithPath: "/tmp/not-a-repo"))

    #expect(snapshot.isGitRepository == false)
    #expect(snapshot.rootPath == nil)
    #expect(snapshot.isDirty == false)
}

@Test
func repositoryInspectorReadsCleanRepositoryMetadata() throws {
    let root = "/tmp/agentctl"
    let inspector = RepositoryInspector(git: GitRunner(
        runner: FakeProcessRunner(responses: [
            gitKey("rev-parse", "--show-toplevel"): ok("\(root)\n"),
            gitKey("remote", "get-url", "origin"): ok("git@github.com:tungd/agentctl.git\n"),
            gitKey("branch", "--show-current"): ok("main\n"),
            gitKey("rev-parse", "HEAD"): ok("abcdef123\n"),
            gitKey("status", "--porcelain=v1"): ok("")
        ])
    ))

    let snapshot = try inspector.inspect(path: URL(fileURLWithPath: root))

    #expect(snapshot.isGitRepository)
    #expect(snapshot.rootPath == root)
    #expect(snapshot.originURL == "git@github.com:tungd/agentctl.git")
    #expect(snapshot.currentBranch == "main")
    #expect(snapshot.headSHA == "abcdef123")
    #expect(snapshot.isDirty == false)
}

@Test
func repositoryInspectorMarksDirtyStatusAndHandlesDetachedHead() throws {
    let root = "/tmp/agentctl"
    let status = " M Package.swift\n?? Sources/NewFile.swift\n"
    let inspector = RepositoryInspector(git: GitRunner(
        runner: FakeProcessRunner(responses: [
            gitKey("rev-parse", "--show-toplevel"): ok("\(root)\n"),
            gitKey("remote", "get-url", "origin"): ProcessResult(exitCode: 2, stdout: "", stderr: ""),
            gitKey("branch", "--show-current"): ok("\n"),
            gitKey("rev-parse", "HEAD"): ok("deadbeef\n"),
            gitKey("status", "--porcelain=v1"): ok(status)
        ])
    ))

    let snapshot = try inspector.inspect(path: URL(fileURLWithPath: root))

    #expect(snapshot.isGitRepository)
    #expect(snapshot.originURL == nil)
    #expect(snapshot.currentBranch == nil)
    #expect(snapshot.headSHA == "deadbeef")
    #expect(snapshot.isDirty)
    #expect(snapshot.porcelainStatus == status)
}

@Test
func codexJSONLMapperExtractsThreadAndAssistantMessage() {
    let stdout = """
    {"type":"thread.started","thread_id":"thread-123"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hello"}}
    {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}
    """

    let result = CodexJSONLMapper.map(stdout: stdout)

    #expect(result.threadID == "thread-123")
    #expect(result.assistantText == "hello")
    #expect(result.events.map(\.kind) == [
        .backendSessionUpdated,
        .backendEvent,
        .assistantDone,
        .backendEvent
    ])
}

@Test
func codexJSONLMapperPreservesUnknownLinesAsBackendEvents() {
    let result = CodexJSONLMapper.map(stdout: "not json\n{\"type\":\"mystery\",\"value\":1}\n")

    #expect(result.threadID == nil)
    #expect(result.assistantText == "")
    #expect(result.events.count == 2)
    #expect(result.events[0].kind == .backendEvent)
    #expect(result.events[0].payload["line"] == .string("not json"))
    #expect(result.events[1].payload["type"] == .string("mystery"))
}

@Test
func codexExecArgumentsUseFreshExecShape() {
    let backend = CodexExecBackend()
    let args = backend.makeArguments(
        prompt: "hello",
        cwd: URL(fileURLWithPath: "/tmp/repo"),
        options: CodexExecOptions(fullAuto: true, sandbox: "workspace-write", model: "gpt-test", profile: "default")
    )

    #expect(args == [
        "codex",
        "exec",
        "--json",
        "--full-auto",
        "--sandbox",
        "workspace-write",
        "--model",
        "gpt-test",
        "--profile",
        "default",
        "-C",
        "/tmp/repo",
        "hello"
    ])
}

@Test
func codexExecArgumentsUseResumeShapeWithoutUnsupportedFlags() {
    let backend = CodexExecBackend()
    let args = backend.makeArguments(
        prompt: "continue",
        cwd: URL(fileURLWithPath: "/tmp/repo"),
        resumeThreadID: "thread-123",
        options: CodexExecOptions(fullAuto: true, sandbox: "workspace-write", model: "gpt-test", profile: "default")
    )

    #expect(args == [
        "codex",
        "exec",
        "resume",
        "--json",
        "--full-auto",
        "--model",
        "gpt-test",
        "thread-123",
        "continue"
    ])
}

@Test
func localTaskStorePersistsTasksSessionsAndEvents() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LocalTaskStore(root: root)
    let task = TaskRecord(title: "Test Task", slug: "test-task")
    let session = SessionRecord(
        taskID: task.id,
        backend: .codex,
        backendSessionID: "thread-123",
        cwd: "/tmp/repo"
    )

    try store.saveTask(task)
    try store.saveSession(session)
    let first = try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage))
    let second = try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .assistantDone))

    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(try store.findTask("test-task").id == task.id)
    #expect(try store.findTask(String(task.id.uuidString.prefix(8))).id == task.id)
    #expect(try store.listSessions(taskID: task.id).first?.backendSessionID == "thread-123")
    #expect(try store.events(for: task.id).map(\.kind) == [.userMessage, .assistantDone])
}

private struct FakeProcessRunner: ProcessRunning {
    let responses: [String: ProcessResult]

    func run(_ executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult {
        responses[Self.key(arguments)] ?? ProcessResult(
            exitCode: 127,
            stdout: "",
            stderr: "unexpected command: \(executable) \(arguments.joined(separator: " "))"
        )
    }

    static func key(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1F}")
    }
}

private func gitKey(_ arguments: String...) -> String {
    FakeProcessRunner.key(["git"] + arguments)
}

private func ok(_ stdout: String) -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
}
