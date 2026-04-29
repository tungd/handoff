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
    let pi = PiBackendAdapter()
    let claude = ClaudeBackendAdapter()

    #expect(codex.descriptor.backend == .codex)
    #expect(codex.descriptor.capabilities.contains(.execJSON))
    #expect(codex.descriptor.capabilities.contains(.appServer))
    #expect(codex.descriptor.capabilities.contains(.resumeNativeSession))
    #expect(codex.appServerCommand == ["codex", "app-server", "--listen", "stdio://"])
    #expect(codex.execServerCommand == ["codex", "exec-server"])

    #expect(pi.descriptor.backend == .pi)
    #expect(pi.descriptor.capabilities.contains(.structuredOutput))
    #expect(pi.descriptor.capabilities.contains(.resumeNativeSession))
    #expect(pi.printCommand == ["pi", "--mode", "rpc"])

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
func codexJSONLMapperMapsSingleLines() {
    let thread = CodexJSONLMapper.mapLine(#"{"type":"thread.started","thread_id":"thread-123"}"#)
    let message = CodexJSONLMapper.mapLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"#)
    let toolStarted = CodexJSONLMapper.mapLine(#"{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc pwd","status":"in_progress"}}"#)
    let toolFinished = CodexJSONLMapper.mapLine(#"{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc pwd","aggregated_output":"/tmp\n","exit_code":0,"status":"completed"}}"#)

    #expect(thread.threadID == "thread-123")
    #expect(thread.event.kind == .backendSessionUpdated)
    #expect(message.assistantText == "hello")
    #expect(message.event.kind == .assistantDone)
    #expect(toolStarted.event.kind == .toolStarted)
    #expect(toolStarted.event.payload["command"] == .string("/bin/zsh -lc pwd"))
    #expect(toolFinished.event.kind == .toolFinished)
    #expect(toolFinished.event.payload["exitCode"] == .int(0))
}

@Test
func codexStreamingBackendEmitsUpdatesAsLinesArrive() async throws {
    let backend = CodexStreamingBackend(runner: FakeStreamingProcessRunner(events: [
        .stdoutLine(#"{"type":"thread.started","thread_id":"thread-123"}"#),
        .stdoutLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"#),
        .stderrLine("warning"),
        .exited(0)
    ]), executable: "/fake/env")
    let sink = CodexUpdateSink()

    let result = try await backend.run(
        prompt: "hello",
        cwd: URL(fileURLWithPath: "/tmp/repo")
    ) { update in
        await sink.append(update)
    }

    let updates = await sink.values()
    #expect(result.exitCode == 0)
    #expect(result.threadID == "thread-123")
    #expect(result.assistantText == "hello")
    #expect(result.stderr == "warning")
    #expect(updates.count == 3)
}

@Test
func codexStreamingBackendForwardsInterruptEscape() async throws {
    let sentData = SentDataRecorder()
    let backend = CodexStreamingBackend(runner: FakeStreamingProcessRunner(events: [
        .stdoutLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"stopped"}}"#),
        .exited(0)
    ], control: ProcessStreamControl(sendData: { data in
        sentData.append(data)
    })), executable: "/fake/env")
    let interruptHandle = AgentInterruptHandle()
    var requestedInterrupt = false

    _ = try await backend.run(
        prompt: "hello",
        cwd: URL(fileURLWithPath: "/tmp/repo"),
        interruptHandle: interruptHandle
    ) { _ in
        if !requestedInterrupt {
            requestedInterrupt = true
            #expect(interruptHandle.requestInterrupt())
        }
    }

    #expect(sentData.values() == [Data([0x1B])])
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
func piRPCArgumentsUseSessionAndModelOptions() {
    let backend = PiRPCBackend()
    let args = backend.makeArguments(
        sessionPath: URL(fileURLWithPath: "/tmp/repo/.agentctl/pi-sessions/task.jsonl"),
        options: PiRPCOptions(
            provider: "openai",
            model: "gpt-4o-mini",
            thinking: "low",
            tools: "read,grep,edit"
        )
    )

    #expect(args == [
        "pi",
        "--mode",
        "rpc",
        "--session",
        "/tmp/repo/.agentctl/pi-sessions/task.jsonl",
        "--provider",
        "openai",
        "--model",
        "gpt-4o-mini",
        "--thinking",
        "low",
        "--tools",
        "read,grep,edit"
    ])
}

@Test
func piRPCArgumentsPreferNoToolsOverToolAllowlist() {
    let backend = PiRPCBackend()
    let args = backend.makeArguments(
        sessionPath: URL(fileURLWithPath: "/tmp/session.jsonl"),
        options: PiRPCOptions(tools: "read,grep", noTools: true)
    )

    #expect(args == [
        "pi",
        "--mode",
        "rpc",
        "--session",
        "/tmp/session.jsonl",
        "--no-tools"
    ])
}

@Test
func piRPCMapperMapsAgentEndToolEventsAndStats() {
    let agentEnd = PiRPCMapper.mapLine("""
    {"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"done"}]}]}
    """)
    let toolStart = PiRPCMapper.mapLine("""
    {"type":"tool_execution_start","toolCallId":"call-1","toolName":"bash","args":{"command":"swift test"}}
    """)
    let stats = PiRPCMapper.mapLine("""
    {"id":"stats-1","type":"response","command":"get_session_stats","success":true,"data":{"sessionFile":"/tmp/session.jsonl","tokens":{"input":10,"output":3,"total":13},"contextUsage":{"tokens":13,"contextWindow":128000,"percent":0.1}}}
    """)

    #expect(agentEnd.isAgentEnd)
    #expect(agentEnd.assistantText == "done")
    #expect(agentEnd.event.kind == .assistantDone)
    #expect(agentEnd.event.payload["text"] == .string("done"))

    #expect(toolStart.event.kind == .toolStarted)
    #expect(toolStart.event.payload["toolName"] == .string("bash"))
    #expect(toolStart.event.payload["command"] == .string("swift test"))

    #expect(stats.requestID == "stats-1")
    #expect(stats.command == "get_session_stats")
    #expect(stats.sessionPath == "/tmp/session.jsonl")
    #expect(stats.event.kind == .backendEvent)
    #expect(stats.event.payload["context_window"] == .int(128000))
    #expect(stats.event.payload["usage"]?.objectValue?["input_tokens"] == .int(10))
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
    let checkpoint = CheckpointRecord(
        taskID: task.id,
        branch: "agent/test-task",
        commitSHA: "abcdef123"
    )
    let artifact = ArtifactRecord(
        taskID: task.id,
        kind: .handoffManifest,
        title: "Handoff",
        contentRef: "checkpoint://handoff",
        contentType: "application/json"
    )

    try store.saveTask(task)
    try store.saveSession(session)
    try store.saveCheckpoint(checkpoint)
    try store.saveArtifact(artifact)
    let first = try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage))
    let second = try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .assistantDone))

    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(try store.findTask("test-task").id == task.id)
    #expect(try store.findTask(String(task.id.uuidString.prefix(8))).id == task.id)
    #expect(try store.listSessions(taskID: task.id).first?.backendSessionID == "thread-123")
    #expect(try store.listCheckpoints(taskID: task.id).first?.commitSHA == "abcdef123")
    #expect(try store.listArtifacts(taskID: task.id).first?.kind == .handoffManifest)
    #expect(try store.events(for: task.id).map(\.kind) == [.userMessage, .assistantDone])
}

@Test
func localTaskStoreRecentEventsUsesLatestEvents() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store: any AgentTaskStore = LocalTaskStore(root: root)
    let task = TaskRecord(title: "Test Task", slug: "test-task")
    try await store.saveTask(task)
    try await store.appendEvent(AgentEvent(taskID: task.id, kind: .userMessage))
    try await store.appendEvent(AgentEvent(taskID: task.id, kind: .assistantDone))

    #expect(try await store.recentEvents(for: task.id, limit: 1).map(\.kind) == [.assistantDone])
}

@Test
func localTaskStoreConformsToAsyncStoreProtocol() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store: any AgentTaskStore = LocalTaskStore(root: root)
    let task = TaskRecord(title: "Async Store", slug: "async-store")

    try await store.saveTask(task)
    let loaded = try await store.findTask("async-store")

    #expect(loaded.id == task.id)
}

@Test
func agentSessionControllerPersistsStreamingCodexTurn() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store: any AgentTaskStore = LocalTaskStore(root: root)
    let task = TaskRecord(title: "Streaming", slug: "streaming")
    try await store.saveTask(task)

    let backend = CodexStreamingBackend(runner: FakeStreamingProcessRunner(events: [
        .stdoutLine(#"{"type":"thread.started","thread_id":"thread-123"}"#),
        .stdoutLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"#),
        .exited(0)
    ]), executable: "/fake/env")
    let controller = AgentSessionController(store: store, codexBackend: backend)
    let sink = AgentSessionUpdateSink()

    let summary = try await controller.runCodexTurn(
        task: task,
        prompt: "hello",
        repoURL: root,
        snapshot: RepositorySnapshot(isGitRepository: false),
        onUpdate: { update in
            await sink.append(update)
        }
    )

    let events = try await store.events(for: task.id)
    let updates = await sink.values()

    #expect(summary.sessions.first?.backendSessionID == "thread-123")
    #expect(events.map(\.kind) == [
        .sessionStarted,
        .userMessage,
        .backendSessionUpdated,
        .assistantDone,
        .sessionEnded
    ])
    #expect(updates.contains { update in
        if case .event(let event) = update {
            return event.kind == .assistantDone
        }
        return false
    })
}

@Test
func agentSessionControllerPersistsPiRPCTurn() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store: any AgentTaskStore = LocalTaskStore(root: root)
    let task = TaskRecord(title: "Pi Turn", slug: "pi-turn", backendPreference: .pi)
    try await store.saveTask(task)

    let sentLines = SentLineRecorder()
    let backend = PiRPCBackend(runner: FakeInteractiveProcessRunner(events: [
        .stdoutLine(#"{"id":"prompt-1","type":"response","command":"prompt","success":true}"#),
        .stdoutLine(#"{"type":"tool_execution_start","toolCallId":"call-1","toolName":"bash","args":{"command":"swift test"}}"#),
        .stdoutLine(#"{"type":"tool_execution_end","toolCallId":"call-1","toolName":"bash","args":{"command":"swift test"},"result":{"content":[{"type":"text","text":"ok"}],"details":{"exitCode":0}},"isError":false}"#),
        .stdoutLine(#"{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"done"}]}]}"#),
        .stdoutLine(#"{"id":"stats-1","type":"response","command":"get_session_stats","success":true,"data":{"sessionFile":"/tmp/pi-session.jsonl","tokens":{"input":10,"output":3,"total":13},"contextUsage":{"tokens":13,"contextWindow":128000,"percent":0.1}}}"#),
        .exited(15)
    ], sentLines: sentLines), executable: "/fake/env")
    let controller = AgentSessionController(store: store, piBackend: backend)

    let summary = try await controller.runAgentTurn(
        task: task,
        prompt: "polish this",
        repoURL: root,
        snapshot: RepositorySnapshot(isGitRepository: false)
    )

    let events = try await store.events(for: task.id)
    let lines = sentLines.values()

    #expect(summary.sessions.first?.backend == .pi)
    #expect(summary.sessions.first?.backendSessionID == "/tmp/pi-session.jsonl")
    #expect(events.map(\.kind).contains(.toolStarted))
    #expect(events.map(\.kind).contains(.toolFinished))
    #expect(events.map(\.kind).contains(.assistantDone))
    #expect(events.last?.kind == .sessionEnded)
    #expect(lines.contains { $0.contains(#""type":"prompt""#) && $0.contains(#""message":"polish this""#) })
    #expect(lines.contains { $0.contains(#""type":"get_session_stats""#) })
}

@Test
func piRPCBackendSendsAbortCommandWhenInterrupted() async throws {
    let sentLines = SentLineRecorder()
    let backend = PiRPCBackend(runner: FakeInteractiveProcessRunner(events: [
        .stdoutLine(#"{"id":"prompt-1","type":"response","command":"prompt","success":true}"#),
        .stdoutLine(#"{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"stopped"}]}]}"#),
        .stdoutLine(#"{"id":"stats-1","type":"response","command":"get_session_stats","success":true,"data":{"sessionFile":"/tmp/pi-session.jsonl"}}"#),
        .exited(0)
    ], sentLines: sentLines), executable: "/fake/env")
    let interruptHandle = AgentInterruptHandle()
    var requestedInterrupt = false

    _ = try await backend.run(
        prompt: "polish",
        cwd: URL(fileURLWithPath: "/tmp/repo"),
        sessionPath: URL(fileURLWithPath: "/tmp/pi-session.jsonl"),
        interruptHandle: interruptHandle
    ) { _ in
        if !requestedInterrupt {
            requestedInterrupt = true
            #expect(interruptHandle.requestInterrupt())
        }
    }

    let lines = sentLines.values()
    #expect(lines.contains { $0.contains(#""type":"prompt""#) })
    #expect(lines.contains { $0.contains(#""type":"abort""#) })
}

@Test
func gitCheckpointManagerCreatesBranchCommitsChangesAndReturnsCheckpoint() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let task = TaskRecord(title: "Cashout Race", slug: "cashout-race")
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("switch", "agent/cashout-race"): ProcessResult(exitCode: 1, stdout: "", stderr: "missing branch"),
        gitKey("switch", "-c", "agent/cashout-race"): ok(""),
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(" M Sources/file.swift\n"),
        gitKey("add", "-A", "--", ".", ":!.agentctl"): ok(""),
        gitKey("commit", "-m", "agentctl checkpoint: cashout-race"): ok("[agent/cashout-race abcdef1] checkpoint\n"),
        gitKey("rev-parse", "HEAD"): ok("abcdef123\n")
    ])))

    let result = try manager.createCheckpoint(
        task: task,
        snapshot: RepositorySnapshot(
            isGitRepository: true,
            rootPath: root.path,
            currentBranch: "main",
            headSHA: "before",
            isDirty: true
        ),
        repoURL: root
    )

    #expect(result.checkpoint.branch == "agent/cashout-race")
    #expect(result.checkpoint.commitSHA == "abcdef123")
    #expect(result.committed)
    #expect(result.pushed == false)
    #expect(result.dirtyStatus == " M Sources/file.swift\n")
    #expect(result.manifest.changedFiles == ["Sources/file.swift"])
    #expect(result.checkpoint.metadata["handoffManifest"] == nil)
    #expect(result.checkpoint.metadata["changedFiles"] == .array([.string("Sources/file.swift")]))
}

@Test
func gitCheckpointManagerPushesWhenRequested() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let task = TaskRecord(title: "Handoff", slug: "handoff")
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("switch", "agent/handoff"): ok(""),
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(""),
        gitKey("rev-parse", "HEAD"): ok("feedface\n"),
        gitKey("push", "-u", "origin", "agent/handoff"): ok("")
    ])))

    let result = try manager.createCheckpoint(
        task: task,
        snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
        repoURL: root,
        options: GitCheckpointOptions(push: true)
    )

    #expect(result.checkpoint.commitSHA == "feedface")
    #expect(result.committed == false)
    #expect(result.pushed)
    #expect(result.checkpoint.pushedAt != nil)
}

@Test
func gitCheckpointManagerRestoresPushedCheckpointFromRemote() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let checkpoint = CheckpointRecord(
        taskID: UUID(),
        branch: "agent/handoff",
        commitSHA: "feedface",
        remoteName: "origin",
        pushedAt: Date(timeIntervalSince1970: 0)
    )
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(""),
        gitKey("fetch", "origin", "agent/handoff:refs/remotes/origin/agent/handoff"): ok(""),
        gitKey("switch", "agent/handoff"): ProcessResult(exitCode: 1, stdout: "", stderr: "missing branch"),
        gitKey("switch", "--track", "-c", "agent/handoff", "origin/agent/handoff"): ok(""),
        gitKey("merge", "--ff-only", "origin/agent/handoff"): ok(""),
        gitKey("rev-parse", "HEAD"): ok("feedface\n")
    ])))

    let result = try manager.restoreCheckpoint(
        checkpoint,
        snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
        repoURL: root
    )

    #expect(result.checkpoint == checkpoint)
    #expect(result.fetched)
    #expect(result.switched)
    #expect(result.fastForwarded)
    #expect(result.headSHA == "feedface")
}

@Test
func gitCheckpointManagerRestoresLocalCheckpointWithoutFetching() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let checkpoint = CheckpointRecord(
        taskID: UUID(),
        branch: "agent/local",
        commitSHA: "abc1234"
    )
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(""),
        gitKey("switch", "agent/local"): ok(""),
        gitKey("rev-parse", "HEAD"): ok("abc1234\n")
    ])))

    let result = try manager.restoreCheckpoint(
        checkpoint,
        snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
        repoURL: root
    )

    #expect(result.fetched == false)
    #expect(result.fastForwarded == false)
    #expect(result.headSHA == "abc1234")
    #expect(result.advancedBeyondCheckpoint == false)
}

@Test
func gitCheckpointManagerAcceptsRestoredBranchAheadOfCheckpoint() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let checkpoint = CheckpointRecord(
        taskID: UUID(),
        branch: "agent/local",
        commitSHA: "base123"
    )
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(""),
        gitKey("switch", "agent/local"): ok(""),
        gitKey("rev-parse", "HEAD"): ok("child456\n"),
        gitKey("merge-base", "--is-ancestor", "base123", "child456"): ok("")
    ])))

    let result = try manager.restoreCheckpoint(
        checkpoint,
        snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
        repoURL: root
    )

    #expect(result.headSHA == "child456")
    #expect(result.advancedBeyondCheckpoint)
}

@Test
func gitCheckpointManagerRejectsRestoredBranchMissingCheckpointCommit() throws {
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let checkpoint = CheckpointRecord(
        taskID: UUID(),
        branch: "agent/local",
        commitSHA: "base123"
    )
    let manager = GitCheckpointManager(git: GitRunner(runner: FakeProcessRunner(responses: [
        gitKey("status", "--porcelain=v1", "--", ".", ":!.agentctl"): ok(""),
        gitKey("switch", "agent/local"): ok(""),
        gitKey("rev-parse", "HEAD"): ok("other789\n"),
        gitKey("merge-base", "--is-ancestor", "base123", "other789"): ProcessResult(
            exitCode: 1,
            stdout: "",
            stderr: ""
        )
    ])))

    do {
        _ = try manager.restoreCheckpoint(
            checkpoint,
            snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
            repoURL: root
        )
        Issue.record("expected restore to reject a branch missing the checkpoint commit")
    } catch let GitCheckpointError.checkpointCommitMismatch(expected, actual) {
        #expect(expected == "base123")
        #expect(actual == "other789")
    }
}

@Test
func postgresConfigurationParsesDatabaseURL() throws {
    let configuration = try AgentPostgresConfiguration(
        databaseURL: "postgres://agent:secret@localhost:55432/agentctl?sslmode=disable"
    )

    #expect(configuration.host == "localhost")
    #expect(configuration.port == 55432)
    #expect(configuration.username == "agent")
    #expect(configuration.password == "secret")
    #expect(configuration.database == "agentctl")
    #expect(configuration.tlsDisabled)
}

private actor CodexUpdateSink {
    private var updates: [CodexStreamUpdate] = []

    func append(_ update: CodexStreamUpdate) {
        updates.append(update)
    }

    func values() -> [CodexStreamUpdate] {
        updates
    }
}

private actor AgentSessionUpdateSink {
    private var updates: [AgentSessionUpdate] = []

    func append(_ update: AgentSessionUpdate) {
        updates.append(update)
    }

    func values() -> [AgentSessionUpdate] {
        updates
    }
}

private final class SentLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
        }
    }

    func values() -> [String] {
        lock.withLock {
            lines
        }
    }
}

private final class SentDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []

    func append(_ value: Data) {
        lock.withLock {
            data.append(value)
        }
    }

    func values() -> [Data] {
        lock.withLock {
            data
        }
    }
}

private struct FakeInteractiveProcessRunner: ProcessInteracting {
    let events: [ProcessStreamEvent]
    let sentLines: SentLineRecorder

    func start(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) throws -> any InteractiveProcess {
        FakeInteractiveProcess(events: events, sentLines: sentLines)
    }
}

private final class FakeInteractiveProcess: InteractiveProcess, @unchecked Sendable {
    let events: AsyncThrowingStream<ProcessStreamEvent, Error>
    private let sentLines: SentLineRecorder

    init(events: [ProcessStreamEvent], sentLines: SentLineRecorder) {
        self.sentLines = sentLines
        self.events = AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func sendLine(_ line: String) throws {
        sentLines.append(line)
    }

    func closeStdin() throws {}

    func terminate() {}
}

private struct FakeStreamingProcessRunner: ProcessStreaming {
    let events: [ProcessStreamEvent]
    var control: ProcessStreamControl?

    func stream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func controlledStream(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) -> ProcessStreamSession {
        ProcessStreamSession(
            events: stream(executable, arguments: arguments, workingDirectory: workingDirectory),
            control: control
        )
    }
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
