import AgentCore
import ArgumentParser
import Darwin
import Foundation

extension AgentBackend: ExpressibleByArgument {}

enum StoreKind: String, ExpressibleByArgument {
    case auto
    case local
    case postgres
}

struct StoreOptions: ParsableArguments, @unchecked Sendable {
    @Option(help: "Task store to use: auto, postgres, or local.")
    var store: StoreKind = .auto

    @Option(help: "PostgreSQL URL. Defaults to AGENTCTL_DATABASE_URL.")
    var databaseURL: String?
}

struct BackendRunOptions: ParsableArguments, @unchecked Sendable {
    @Option(help: "Backend model. Passed to Codex or Pi.")
    var model: String?

    @Option(help: "Pi provider name.")
    var provider: String?

    @Option(help: "Pi thinking level: off, minimal, low, medium, high, or xhigh.")
    var thinking: String?

    @Option(help: "Pi tool allowlist, comma-separated.")
    var tools: String?

    @Flag(help: "Disable Pi tools.")
    var noTools: Bool = false
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct Agentctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentctl",
        abstract: "Task/session manager for coding-agent workflows.",
        discussion: "Run without a subcommand to start an interactive agent session.",
        subcommands: [
            Repo.self,
            Task.self,
            DB.self,
            Backend.self,
            MCP.self
        ]
    )

    @Option(name: .shortAndLong, help: "Directory to use as the current workspace.")
    var cwd: String = "."

    @OptionGroup
    var storeOptions: StoreOptions

    @Option(name: .customLong("task"), help: "Task id, id prefix, or slug to resume interactively.")
    var taskIdentifier: String?

    @Option(help: "Title for a newly created interactive task.")
    var title: String?

    @Option(help: "Preferred backend for a newly created interactive task.")
    var backend: AgentBackend = .codex

    @Flag(help: "Pass --full-auto to Codex.")
    var fullAuto: Bool = false

    @Option(help: "Codex sandbox mode.")
    var sandbox: String?

    @OptionGroup
    var backendRunOptions: BackendRunOptions

    mutating func run() async throws {
        try await runInteractiveAgent(
            cwd: cwd,
            storeOptions: storeOptions,
            taskIdentifier: taskIdentifier,
            title: title,
            backend: backend,
            fullAuto: fullAuto,
            sandbox: sandbox,
            backendRunOptions: backendRunOptions
        )
    }
}

struct Repo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Inspect and manage repository state.",
        subcommands: [Inspect.self]
    )

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Inspect the current git repository."
        )

        @Option(name: .shortAndLong, help: "Directory to inspect.")
        var path: String = "."

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            try printRepositoryInspection(path: path, json: json)
        }
    }
}

struct Task: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "Create, list, and resume agentctl tasks.",
        subcommands: [New.self, List.self, Show.self, Send.self, Resume.self, Release.self, Checkpoint.self, Checkpoints.self, Artifacts.self, Continuation.self]
    )

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "new",
            abstract: "Create a task record, optionally running the first backend turn."
        )

        @Argument(help: "Task title.")
        var title: String

        @Option(help: "Preferred backend.")
        var backend: AgentBackend = .codex

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Option(help: "Initial prompt to send to the preferred backend.")
        var prompt: String?

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @OptionGroup
        var backendRunOptions: BackendRunOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let task = TaskRecord(
                title: title,
                slug: Slug.make(title),
                backendPreference: backend
            )

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                try await store.saveTask(task)
                try await store.appendEvent(AgentEvent(taskID: task.id, kind: .taskCreated, payload: [
                    "title": .string(task.title),
                    "slug": .string(task.slug),
                    "backend": .string(task.backendPreference.rawValue)
                ]))

                if let prompt {
                    let summary = try await runAgentTurn(
                        task: task,
                        prompt: prompt,
                        repoURL: repoURL,
                        snapshot: snapshot,
                        store: store,
                        fullAuto: fullAuto,
                        sandbox: sandbox,
                        backendRunOptions: backendRunOptions
                    )

                    if json {
                        try printJSON(summary)
                        return
                    }

                    printRunSummary(summary)
                    return
                }

                let preview = TaskPreview(task: task, repository: snapshot)
                if json {
                    try printJSON(preview)
                    return
                }

                print("Task created")
                print("  id:      \(task.id.uuidString)")
                print("  title:   \(task.title)")
                print("  slug:    \(task.slug)")
                print("  backend: \(task.backendPreference.rawValue)")
                print("  repo:    \(snapshot.rootPath ?? "not detected")")
                print("  store:   \(storeDescription(options: storeOptions, repoURL: repoURL, snapshot: snapshot))")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List local tasks."
        )

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let tasks = try await store.listTasks()

                if json {
                    try printJSON(tasks)
                    return
                }

                if tasks.isEmpty {
                    print("No tasks found in \(storeDescription(options: storeOptions, repoURL: repoURL, snapshot: snapshot)).")
                    return
                }

                for task in tasks {
                    let sessions = try await store.listSessions(taskID: task.id)
                    let thread = sessions.first?.backendSessionID ?? "-"
                    print("\(task.slug)")
                    print("  id:      \(task.id.uuidString)")
                    print("  title:   \(task.title)")
                    print("  backend: \(task.backendPreference.rawValue)")
                    print("  state:   \(task.state.rawValue)")
                    print("  thread:  \(thread)")
                }
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a local task summary."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let summary = try await store.summary(for: task)

                if json {
                    try printJSON(summary)
                    return
                }

                printTaskSummary(summary)
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Send one prompt to a task's backend session."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Argument(help: "Prompt to send.")
        var prompt: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @OptionGroup
        var backendRunOptions: BackendRunOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)

                let summary = try await runAgentTurn(
                    task: task,
                    prompt: prompt,
                    repoURL: repoURL,
                    snapshot: snapshot,
                    store: store,
                    fullAuto: fullAuto,
                    sandbox: sandbox,
                    backendRunOptions: backendRunOptions
                )

                if json {
                    try printJSON(summary)
                    return
                }

                printRunSummary(summary)
            }
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Show a task summary, or send a prompt if one is provided."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Argument(help: "Optional prompt to send.")
        var prompt: String?

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @OptionGroup
        var backendRunOptions: BackendRunOptions

        @Option(help: "Checkpoint id prefix or latest to restore before resuming.")
        var checkpoint: String?

        @Flag(name: .customLong("force"), help: "Steal an active remote claim before resuming.")
        var forceClaim: Bool = false

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let handoff = try await prepareResumeHandoff(
                    task: task,
                    store: store,
                    repoURL: repoURL,
                    snapshot: snapshot,
                    checkpointSelector: checkpoint,
                    forceClaim: forceClaim
                )
                let activeSnapshot = handoff.restore == nil
                    ? snapshot
                    : try RepositoryInspector().inspect(path: repoURL)

                do {
                    if let prompt {
                        if !json, let restore = handoff.restore {
                            printCheckpointRestoreResult(restore)
                        }

                        let summary = try await runAgentTurn(
                            task: task,
                            prompt: prompt,
                            repoURL: repoURL,
                            snapshot: activeSnapshot,
                            store: store,
                            fullAuto: fullAuto,
                            sandbox: sandbox,
                            backendRunOptions: backendRunOptions
                        )

                        _ = try? await releaseResumeClaim(task: task, store: store)
                        if json {
                            try printJSON(summary)
                            return
                        }

                        printRunSummary(summary)
                        return
                    }

                    let summary = try await store.summary(for: task)
                    _ = try? await releaseResumeClaim(task: task, store: store)

                    if json {
                        try printJSON(summary)
                        return
                    }

                    if let restore = handoff.restore {
                        printCheckpointRestoreResult(restore)
                        print("")
                    }
                    printTaskSummary(summary)
                } catch {
                    _ = try? await releaseResumeClaim(task: task, store: store)
                    throw error
                }
            }
        }
    }

    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "release",
            abstract: "Release this machine's active claim on a task."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let result = try await releaseResumeClaim(task: task, store: store)

                if json {
                    try printJSON(result)
                    return
                }

                print(result.released ? "Claim released." : "No active claim for this machine.")
            }
        }
    }

    struct Checkpoint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "checkpoint",
            abstract: "Create a git checkpoint for a task."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @Option(help: "Checkpoint branch. Defaults to agent/<task-slug>.")
        var branch: String?

        @Option(help: "Git remote name to use when pushing.")
        var remote: String = "origin"

        @Option(name: .shortAndLong, help: "Commit message.")
        var message: String?

        @Flag(help: "Push the checkpoint branch after creating it.")
        var push: Bool = false

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let result = try await createAndPersistCheckpoint(
                    task: task,
                    store: store,
                    snapshot: snapshot,
                    repoURL: repoURL,
                    options: GitCheckpointOptions(
                        branch: branch,
                        remoteName: remote,
                        message: message,
                        push: push
                    )
                )

                if json {
                    try printJSON(result)
                    return
                }

                printCheckpointResult(result)
            }
        }
    }

    struct Checkpoints: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "checkpoints",
            abstract: "List git checkpoints for a task."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let checkpoints = try await store.listCheckpoints(taskID: task.id)

                if json {
                    try printJSON(checkpoints)
                    return
                }

                printCheckpoints(checkpoints)
            }
        }
    }

    struct Artifacts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "artifacts",
            abstract: "List handoff artifacts for a task."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let artifacts = try await store.listArtifacts(taskID: task.id)

                if json {
                    try printJSON(artifacts)
                    return
                }

                printArtifacts(artifacts)
            }
        }
    }

    struct Continuation: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "continue",
            abstract: "Export a portable continuation prompt for another agent."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Argument(help: "Optional output path.")
        var path: String?

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @OptionGroup
        var storeOptions: StoreOptions

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)

            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)
                let result = try await exportContinuationMarkdown(
                    task: task,
                    store: store,
                    repoURL: repoURL,
                    snapshot: snapshot,
                    destination: path
                )

                if json {
                    try printJSON(result)
                    return
                }

                print("Continuation bundle written")
                print("  path:      \(result.url.path)")
                print("  events:    \(result.eventCount)")
                print("  artifacts: \(result.artifactCount)")
            }
        }
    }
}

struct DB: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Database helpers.",
        subcommands: [Schema.self, Migrate.self]
    )

    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "schema",
            abstract: "Print the initial Postgres migration."
        )

        mutating func run() throws {
            print(try SchemaLoader.initialMigration())
        }
    }

    struct Migrate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate",
            abstract: "Apply Postgres migrations."
        )

        @Option(help: "PostgreSQL URL. Defaults to AGENTCTL_DATABASE_URL.")
        var databaseURL: String?

        mutating func run() async throws {
            let configuration = try postgresConfiguration(databaseURL)
            do {
                try await PostgresTaskStore.withStore(configuration: configuration) { store in
                    try await store.migrate()
                }
            } catch {
                throw RuntimeError(String(reflecting: error))
            }
            print("Migrations applied to \(configuration.host):\(configuration.port)/\(configuration.database).")
        }
    }
}

struct Backend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backend",
        abstract: "Inspect backend adapter metadata.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List planned backend adapters."
        )

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let descriptors = [
                CodexBackendAdapter().descriptor,
                PiBackendAdapter().descriptor,
                ClaudeBackendAdapter().descriptor
            ]

            if json {
                try printJSON(descriptors)
                return
            }

            for descriptor in descriptors {
                print("\(descriptor.backend.rawValue): \(descriptor.displayName)")
                print("  capabilities: \(descriptor.capabilities.map(\.rawValue).joined(separator: ", "))")
                print("  notes: \(descriptor.notes)")
            }
        }
    }
}

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "MCP server helpers.",
        subcommands: [Memory.self]
    )

    struct Memory: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "memory",
            abstract: "Describe the planned memory MCP tools."
        )

        mutating func run() throws {
            let tools = [
                "memory.search(query, scope?, repo?, task?, limit?)",
                "memory.get(id)",
                "memory.write(kind, title, body, tags?, scope?)",
                "memory.update(id, patch)",
                "memory.archive(id)",
                "memory.recent(repo?, task?)",
                "context.current()",
                "skill.search(query)",
                "skill.get(id)"
            ]

            print("Planned memory MCP tools")
            for tool in tools {
                print("  \(tool)")
            }
        }
    }
}

struct TaskPreview: Codable {
    var task: TaskRecord
    var repository: RepositorySnapshot
}

struct InteractiveTaskResolution: Sendable {
    var task: TaskRecord
    var isPersisted: Bool
}

func runInteractiveAgent(
    cwd: String,
    storeOptions: StoreOptions,
    taskIdentifier: String?,
    title: String?,
    backend: AgentBackend,
    fullAuto: Bool,
    sandbox: String?,
    backendRunOptions: BackendRunOptions
) async throws {
    let repoURL = URL(fileURLWithPath: cwd)
    let snapshot = try RepositoryInspector().inspect(path: repoURL)

    try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
        let activeSnapshot = snapshot
        let taskResolution = try await resolveInitialInteractiveTask(
            identifier: taskIdentifier,
            title: title,
            backend: backend,
            snapshot: activeSnapshot,
            repoURL: repoURL,
            store: store
        )
        let task = taskResolution.task
        let taskPersisted = taskResolution.isPersisted

        try await runTUIkitInteractiveLoop(
            task: task,
            taskPersisted: taskPersisted,
            storeOptions: storeOptions,
            repoURL: repoURL,
            snapshot: activeSnapshot,
            store: store,
            defaultBackend: backend,
            fullAuto: fullAuto,
            sandbox: sandbox,
            backendRunOptions: backendRunOptions
        )
    }
}

func resolveInitialInteractiveTask(
    identifier: String?,
    title: String?,
    backend: AgentBackend = .codex,
    snapshot: RepositorySnapshot,
    repoURL: URL,
    store: any AgentTaskStore
) async throws -> InteractiveTaskResolution {
    if let identifier {
        return InteractiveTaskResolution(
            task: try await store.findTask(identifier),
            isPersisted: true
        )
    }

    return InteractiveTaskResolution(
        task: makeInteractiveTask(title: title, backend: backend, snapshot: snapshot, repoURL: repoURL),
        isPersisted: false
    )
}

func resolveInteractiveTask(
    identifier: String?,
    title: String?,
    backend: AgentBackend = .codex,
    snapshot: RepositorySnapshot,
    repoURL: URL,
    store: any AgentTaskStore
) async throws -> TaskRecord {
    if let identifier {
        return try await store.findTask(identifier)
    }

    let task = makeInteractiveTask(title: title, backend: backend, snapshot: snapshot, repoURL: repoURL)
    try await persistInteractiveTask(task, store: store)
    return task
}

func makeInteractiveTask(
    title: String?,
    backend: AgentBackend,
    snapshot: RepositorySnapshot,
    repoURL: URL
) -> TaskRecord {
    let resolvedTitle = title ?? defaultInteractiveTaskTitle(snapshot: snapshot, repoURL: repoURL)
    return TaskRecord(
        title: resolvedTitle,
        slug: Slug.make(resolvedTitle),
        backendPreference: backend
    )
}

func persistInteractiveTask(
    _ task: TaskRecord,
    store: any AgentTaskStore
) async throws {
    try await store.saveTask(task)
    try await store.appendEvent(AgentEvent(taskID: task.id, kind: .taskCreated, payload: [
        "title": .string(task.title),
        "slug": .string(task.slug),
        "backend": .string(task.backendPreference.rawValue),
        "source": .string("interactive")
    ]))
}

func checkpointSlashOptions(_ argument: String?) throws -> GitCheckpointOptions {
    let argument = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if argument.isEmpty {
        return GitCheckpointOptions()
    }
    if argument == "--push" {
        return GitCheckpointOptions(push: true)
    }
    throw RuntimeError("usage: /checkpoint [--push]")
}

struct ResumeSlashOptions: Equatable {
    var taskIdentifier: String
    var checkpointSelector: String?
    var forceClaim: Bool
}

struct ResumeHandoffResult {
    var restore: GitCheckpointRestoreResult?
    var claim: TaskClaimRecord
}

let taskClaimTTL: TimeInterval = 2 * 60 * 60

struct ClaimReleaseResult: Codable, Equatable, Sendable {
    var taskID: UUID
    var ownerName: String
    var released: Bool
    var releasedAt: Date
}

func resumeSlashOptions(_ argument: String?) throws -> ResumeSlashOptions {
    let parts = (argument ?? "")
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)

    guard let taskIdentifier = parts.first else {
        return ResumeSlashOptions(taskIdentifier: "", checkpointSelector: nil, forceClaim: false)
    }

    var checkpointSelector: String?
    var forceClaim = false
    var index = 1
    while index < parts.count {
        switch parts[index] {
        case "--checkpoint":
            guard index + 1 < parts.count else {
                throw RuntimeError("usage: /resume <task> [--checkpoint <id|latest>] [--force]")
            }
            checkpointSelector = parts[index + 1]
            index += 2
        case "--force", "--steal":
            forceClaim = true
            index += 1
        default:
            throw RuntimeError("usage: /resume <task> [--checkpoint <id|latest>] [--force]")
        }
    }

    return ResumeSlashOptions(taskIdentifier: taskIdentifier, checkpointSelector: checkpointSelector, forceClaim: forceClaim)
}

func createAndPersistCheckpoint(
    task: TaskRecord,
    store: any AgentTaskStore,
    snapshot: RepositorySnapshot,
    repoURL: URL,
    options: GitCheckpointOptions = GitCheckpointOptions(),
    onStatus: (@Sendable (String) -> Void)? = nil
) async throws -> GitCheckpointResult {
    onStatus?("preparing git checkpoint...")
    let manager = GitCheckpointManager()
    let gitState = try manager.createGitCheckpoint(
        task: task,
        snapshot: snapshot,
        repoURL: repoURL,
        options: options,
        onProgress: onStatus
    )

    onStatus?("recording checkpoint cursor...")
    let transcriptCursor = try await checkpointTranscriptCursor(task: task, store: store)
    var result = GitCheckpointManager.makeCheckpointResult(
        task: task,
        options: options,
        gitState: gitState
    )
    result.checkpoint.metadata["transcriptCursor"] = .object(transcriptCursor)
    try await store.saveCheckpoint(result.checkpoint)
    try await store.appendEvent(AgentEvent(
        taskID: task.id,
        kind: .checkpointCreated,
        payload: checkpointPayload(result)
    ))

    if result.pushed {
        try await store.appendEvent(AgentEvent(
            taskID: task.id,
            kind: .handoffCreated,
            payload: checkpointPayload(result)
        ))
    }
    return result
}

func checkpointTranscriptCursor(task: TaskRecord, store: any AgentTaskStore) async throws -> [String: JSONValue] {
    let latestEvent = try await store.recentEvents(for: task.id, limit: 1).last
    var cursor: [String: JSONValue] = [
        "taskID": .string(task.id.uuidString),
        "capturedAt": .string(ISO8601DateFormatter().string(from: Date()))
    ]

    if let latestEvent {
        cursor["eventID"] = .string(latestEvent.id.uuidString)
        cursor["eventKind"] = .string(latestEvent.kind.rawValue)
        cursor["eventOccurredAt"] = .string(ISO8601DateFormatter().string(from: latestEvent.occurredAt))
        if let sequence = latestEvent.sequence {
            cursor["eventSequence"] = .int(sequence)
        }
        if let sessionID = latestEvent.sessionID {
            cursor["sessionID"] = .string(sessionID.uuidString)
        }
    }

    return cursor
}

func checkpointArtifacts(from result: GitCheckpointResult, task: TaskRecord) -> [ArtifactRecord] {
    let checkpointID = result.checkpoint.id.uuidString
    let baseMetadata: [String: JSONValue] = [
        "checkpointID": .string(checkpointID),
        "branch": .string(result.checkpoint.branch),
        "commitSHA": .string(result.checkpoint.commitSHA ?? ""),
        "pushed": .bool(result.pushed)
    ]

    var artifacts: [ArtifactRecord] = [
        ArtifactRecord(
            taskID: task.id,
            kind: .handoffManifest,
            title: "Handoff manifest for \(result.checkpoint.branch)",
            contentRef: "checkpoint://\(checkpointID)/handoff_manifest",
            contentType: "application/json",
            metadata: baseMetadata.merging([
                "manifest": result.manifest.jsonValue
            ]) { _, new in new }
        )
    ]

    for output in result.manifest.commandOutputs {
        artifacts.append(ArtifactRecord(
            taskID: task.id,
            kind: .commandOutput,
            title: output.command,
            contentRef: "checkpoint://\(checkpointID)/command_output/\(artifacts.count)",
            contentType: "text/plain",
            metadata: baseMetadata.merging([
                "command": .string(output.command),
                "exitCode": .int(Int64(output.exitCode)),
                "output": .string(output.output)
            ]) { _, new in new }
        ))
    }

    for test in result.manifest.testResults {
        var metadata = baseMetadata.merging([
            "command": .string(test.command),
            "status": .string(test.status)
        ]) { _, new in new }
        if let output = test.output {
            metadata["output"] = .string(output)
        }
        artifacts.append(ArtifactRecord(
            taskID: task.id,
            kind: .testResult,
            title: "\(test.status): \(test.command)",
            contentRef: "checkpoint://\(checkpointID)/test_result/\(artifacts.count)",
            contentType: "text/plain",
            metadata: metadata
        ))
    }

    for file in result.manifest.generatedFiles {
        artifacts.append(ArtifactRecord(
            taskID: task.id,
            kind: .generatedFile,
            title: file,
            contentRef: file,
            contentType: nil,
            metadata: baseMetadata.merging([
                "path": .string(file)
            ]) { _, new in new }
        ))
    }

    return artifacts
}

func handoffManifestContext(task: TaskRecord, store: any AgentTaskStore) async throws -> HandoffManifest {
    let events = try await store.recentEvents(for: task.id, limit: 80)
    return handoffManifestContext(events: events)
}

func handoffManifestContext(events: [AgentEvent]) -> HandoffManifest {
    var commandOutputs: [HandoffCommandOutput] = []
    var testResults: [HandoffTestResult] = []
    var inspectNext: [String] = []

    for event in events.suffix(80) where event.kind == .toolFinished {
        guard let command = event.payload["command"]?.stringValue else {
            continue
        }
        let exitCode: Int32
        if case let .int(value) = event.payload["exitCode"] {
            exitCode = Int32(clamping: value)
        } else {
            exitCode = 0
        }
        let output = truncateHandoffText(event.payload["output"]?.stringValue ?? "")
        commandOutputs.append(HandoffCommandOutput(
            command: command,
            exitCode: exitCode,
            output: output
        ))

        if commandLooksLikeTest(command) {
            let status = exitCode == 0 ? "passed" : "failed"
            testResults.append(HandoffTestResult(
                command: command,
                status: status,
                output: output.isEmpty ? nil : output
            ))
            if exitCode != 0 {
                inspectNext.append("Inspect failed test command: \(command)")
            }
        } else if exitCode != 0 {
            inspectNext.append("Inspect failed command: \(command)")
        }
    }

    return HandoffManifest(
        commandOutputs: Array(commandOutputs.suffix(8)),
        testResults: Array(testResults.suffix(8)),
        inspectNext: Array(inspectNext.suffix(8))
    )
}

private func commandLooksLikeTest(_ command: String) -> Bool {
    let lowered = command.lowercased()
    return lowered.contains(" test")
        || lowered.hasSuffix("test")
        || lowered.contains("swift test")
        || lowered.contains("pnpm test")
        || lowered.contains("npm test")
        || lowered.contains("pytest")
        || lowered.contains("cargo test")
        || lowered.contains("go test")
        || lowered.contains("xcodebuild test")
}

private func truncateHandoffText(_ text: String, limit: Int = 4_000) -> String {
    guard text.count > limit else {
        return text
    }
    return String(text.suffix(limit))
}

@discardableResult
func restoreLatestCheckpointIfAvailable(
    task: TaskRecord,
    store: any AgentTaskStore,
    repoURL: URL,
    snapshot: RepositorySnapshot
) async throws -> GitCheckpointRestoreResult? {
    try await prepareResumeHandoff(
        task: task,
        store: store,
        repoURL: repoURL,
        snapshot: snapshot,
        checkpointSelector: nil,
        forceClaim: false
    ).restore
}

func prepareResumeHandoff(
    task: TaskRecord,
    store: any AgentTaskStore,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    checkpointSelector: String?,
    forceClaim: Bool = false,
    onStatus: (@Sendable (String) -> Void)? = nil
) async throws -> ResumeHandoffResult {
    onStatus?("loading checkpoints...")
    let checkpoints = try await store.listCheckpoints(taskID: task.id)
    let checkpoint = try selectCheckpoint(checkpoints, selector: checkpointSelector)
    onStatus?("claiming task...")
    let claim = try await store.claimTask(
        taskID: task.id,
        checkpointID: checkpoint?.id,
        ownerName: currentClaimOwnerName(),
        ttl: taskClaimTTL,
        force: forceClaim
    )

    guard let checkpoint else {
        try await store.appendEvent(AgentEvent(
            taskID: task.id,
            kind: .taskClaimed,
            payload: taskClaimPayload(claim)
        ))
        return ResumeHandoffResult(restore: nil, claim: claim)
    }

    let result: GitCheckpointRestoreResult
    do {
        onStatus?("restoring checkpoint...")
        result = try GitCheckpointManager().restoreCheckpoint(
            checkpoint,
            snapshot: snapshot,
            repoURL: repoURL,
            onProgress: onStatus
        )
    } catch {
        _ = try? await store.releaseTaskClaim(taskID: task.id, ownerName: claim.ownerName)
        throw error
    }
    onStatus?("recording resume metadata...")
    try await store.appendEvent(AgentEvent(
        taskID: task.id,
        kind: .taskClaimed,
        payload: taskClaimPayload(claim)
    ))
    try await store.appendEvent(AgentEvent(
        taskID: task.id,
        kind: .backendEvent,
        payload: checkpointRestorePayload(result, claim: claim)
    ))
    return ResumeHandoffResult(restore: result, claim: claim)
}

@discardableResult
func refreshResumeClaimIfActive(task: TaskRecord, store: any AgentTaskStore) async throws -> TaskClaimRecord? {
    try await store.refreshTaskClaim(
        taskID: task.id,
        ownerName: currentClaimOwnerName(),
        ttl: taskClaimTTL
    )
}

@discardableResult
func releaseResumeClaim(task: TaskRecord, store: any AgentTaskStore) async throws -> ClaimReleaseResult {
    let ownerName = currentClaimOwnerName()
    let releasedAt = Date()
    let released = try await store.releaseTaskClaim(taskID: task.id, ownerName: ownerName)
    let result = ClaimReleaseResult(
        taskID: task.id,
        ownerName: ownerName,
        released: released,
        releasedAt: releasedAt
    )

    if released {
        try await store.appendEvent(AgentEvent(
            taskID: task.id,
            kind: .taskClaimReleased,
            payload: taskClaimReleasePayload(result)
        ))
    }
    return result
}

func selectCheckpoint(_ checkpoints: [CheckpointRecord], selector: String?) throws -> CheckpointRecord? {
    let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
    if checkpoints.isEmpty, selector?.isEmpty == false {
        throw RuntimeError("no checkpoints found for this task")
    }
    guard let selector, !selector.isEmpty, selector != "latest" else {
        return checkpoints.first
    }

    let normalized = selector.lowercased()
    if let match = checkpoints.first(where: { checkpoint in
        checkpoint.id.uuidString.lowercased().hasPrefix(normalized)
    }) {
        return match
    }

    throw RuntimeError("checkpoint \(selector) was not found for this task")
}

func currentClaimOwnerName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let hostname: String
    if gethostname(&buffer, buffer.count) == 0 {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        hostname = String(decoding: bytes, as: UTF8.self)
    } else {
        hostname = "unknown-host"
    }
    return "\(NSUserName())@\(hostname)"
}

func defaultInteractiveTaskTitle(snapshot: RepositorySnapshot, repoURL: URL) -> String {
    let workspaceName: String
    if let rootPath = snapshot.rootPath {
        workspaceName = URL(fileURLWithPath: rootPath, isDirectory: true).lastPathComponent
    } else {
        workspaceName = repoURL.lastPathComponent.isEmpty ? "workspace" : repoURL.lastPathComponent
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return "Interactive \(workspaceName) \(formatter.string(from: Date()))"
}

func shortStoreName(_ store: String) -> String {
    if store.hasPrefix("postgres://") {
        return "remote"
    }
    if store.hasSuffix("/.agentctl") {
        return "local"
    }
    return store
}

func compactPayload(_ payload: [String: JSONValue]) -> String {
    if let command = payload["command"]?.stringValue {
        let exitCode: String
        if case let .int(value) = payload["exitCode"] {
            exitCode = " exit \(value)"
        } else {
            exitCode = ""
        }
        return "\(command)\(exitCode)"
    }
    if let text = payload["text"]?.stringValue {
        return text.replacingOccurrences(of: "\n", with: " ")
    }
    if let stderr = payload["stderr"]?.stringValue {
        return stderr.replacingOccurrences(of: "\n", with: " ")
    }
    if let type = payload["type"]?.stringValue {
        return type
    }
    return ""
}

func runAgentTurn(
    task: TaskRecord,
    prompt: String,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    store: any AgentTaskStore,
    fullAuto: Bool,
    sandbox: String?,
    backendRunOptions: BackendRunOptions,
    showStatus: Bool = true,
    interruptHandle: AgentInterruptHandle? = nil,
    onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void = { _ in }
) async throws -> TaskRunSummary {
    if showStatus {
        printError("Running \(task.backendPreference.rawValue) turn for \(task.slug)...")
    }

    let controller = AgentSessionController(store: store)
    return try await controller.runAgentTurn(
        task: task,
        prompt: prompt,
        repoURL: repoURL,
        snapshot: snapshot,
        codexOptions: CodexExecOptions(
            fullAuto: fullAuto,
            sandbox: sandbox,
            model: backendRunOptions.model
        ),
        piOptions: PiRPCOptions(
            provider: backendRunOptions.provider,
            model: backendRunOptions.model,
            thinking: backendRunOptions.thinking,
            tools: backendRunOptions.tools,
            noTools: backendRunOptions.noTools
        ),
        interruptHandle: interruptHandle,
        onUpdate: onUpdate
    )
}

func withTaskStore<T>(
    options: StoreOptions,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    operation: (any AgentTaskStore) async throws -> T
) async throws -> T {
    switch resolvedStoreKind(options) {
    case .auto:
        throw RuntimeError("auto store resolution failed")
    case .local:
        let local = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
        return try await operation(local)
    case .postgres:
        let configuration = try postgresConfiguration(options.databaseURL)
        return try await PostgresTaskStore.withStore(configuration: configuration, operation: operation)
    }
}

func resolvedStoreKind(_ options: StoreOptions) -> StoreKind {
    switch options.store {
    case .auto:
        return databaseURLValue(options.databaseURL) == nil ? .local : .postgres
    case .local, .postgres:
        return options.store
    }
}

func postgresConfiguration(_ databaseURL: String?) throws -> AgentPostgresConfiguration {
    let value = databaseURLValue(databaseURL)
    guard let value, !value.isEmpty else {
        throw PostgresConfigurationError.missingDatabaseURL
    }
    return try AgentPostgresConfiguration(databaseURL: value)
}

func databaseURLValue(_ databaseURL: String?) -> String? {
    if let databaseURL, !databaseURL.isEmpty {
        return databaseURL
    }

    guard let environmentValue = ProcessInfo.processInfo.environment["AGENTCTL_DATABASE_URL"],
          !environmentValue.isEmpty else {
        return nil
    }

    return environmentValue
}

func storeDescription(options: StoreOptions, repoURL: URL, snapshot: RepositorySnapshot) -> String {
    switch resolvedStoreKind(options) {
    case .auto:
        return "auto"
    case .local:
        return StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot).path
    case .postgres:
        return redactedDatabaseDescription(databaseURLValue(options.databaseURL))
    }
}

func redactedDatabaseDescription(_ databaseURL: String?) -> String {
    guard let databaseURL,
          let components = URLComponents(string: databaseURL),
          let host = components.host else {
        return "postgres"
    }

    let port = components.port.map { ":\($0)" } ?? ""
    let database = components.path.isEmpty ? "" : components.path
    return "postgres://\(host)\(port)\(database)"
}

func printRepositoryInspection(path: String, json: Bool) throws {
    let snapshot = try RepositoryInspector().inspect(path: URL(fileURLWithPath: path))

    if json {
        try printJSON(snapshot)
        return
    }

    if !snapshot.isGitRepository {
        print("No git repository found at \(path).")
        return
    }

    print("Repository")
    print("  root:   \(snapshot.rootPath ?? "-")")
    print("  remote: \(snapshot.originURL ?? "-")")
    print("  branch: \(snapshot.currentBranch ?? "-")")
    print("  head:   \(snapshot.headSHA ?? "-")")
    print("  dirty:  \(snapshot.isDirty ? "yes" : "no")")

    if snapshot.isDirty {
        print("")
        print(snapshot.porcelainStatus.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

func printTaskSummary(_ summary: TaskRunSummary) {
    print("\(summary.task.slug)")
    print("  id:      \(summary.task.id.uuidString)")
    print("  title:   \(summary.task.title)")
    print("  backend: \(summary.task.backendPreference.rawValue)")
    print("  state:   \(summary.task.state.rawValue)")

    if let session = summary.sessions.first {
        print("  thread:  \(session.backendSessionID ?? "-")")
        print("  cwd:     \(session.cwd)")
    }
    if let claim = activeTaskClaim(summary.currentClaim) {
        print("  claim:   \(claim.ownerName) until \(ISO8601DateFormatter().string(from: claim.expiresAt))")
    }

    if !summary.latestEvents.isEmpty {
        print("")
        print("Recent events")
        for event in summary.latestEvents {
            print("  \(event.sequence ?? 0): \(event.kind.rawValue)")
        }
    }
}

func checkpointPayload(_ result: GitCheckpointResult) -> [String: JSONValue] {
    var payload: [String: JSONValue] = [
        "checkpointID": .string(result.checkpoint.id.uuidString),
        "branch": .string(result.checkpoint.branch),
        "remote": .string(result.checkpoint.remoteName),
        "committed": .bool(result.committed),
        "pushed": .bool(result.pushed),
        "dirtyStatus": .string(result.dirtyStatus),
        "changedFiles": .array(result.manifest.changedFiles.map { .string($0) }),
        "generatedFiles": .array(result.manifest.generatedFiles.map { .string($0) })
    ]

    if let commitSHA = result.checkpoint.commitSHA {
        payload["commitSHA"] = .string(commitSHA)
    }
    if let pushedAt = result.checkpoint.pushedAt {
        payload["pushedAt"] = .string(ISO8601DateFormatter().string(from: pushedAt))
    }
    if let transcriptCursor = result.checkpoint.metadata["transcriptCursor"] {
        payload["transcriptCursor"] = transcriptCursor
    }
    return payload
}

func checkpointRestorePayload(_ result: GitCheckpointRestoreResult, claim: TaskClaimRecord? = nil) -> [String: JSONValue] {
    var payload: [String: JSONValue] = [
        "type": .string("checkpoint.restored"),
        "checkpointID": .string(result.checkpoint.id.uuidString),
        "branch": .string(result.checkpoint.branch),
        "remote": .string(result.checkpoint.remoteName),
        "fetched": .bool(result.fetched),
        "switched": .bool(result.switched),
        "fastForwarded": .bool(result.fastForwarded),
        "advancedBeyondCheckpoint": .bool(result.advancedBeyondCheckpoint)
    ]

    if let commitSHA = result.checkpoint.commitSHA {
        payload["commitSHA"] = .string(commitSHA)
    }
    if let headSHA = result.headSHA {
        payload["headSHA"] = .string(headSHA)
    }
    if let claim {
        payload["claim"] = .object(taskClaimPayload(claim))
    }
    return payload
}

func taskClaimPayload(_ claim: TaskClaimRecord) -> [String: JSONValue] {
    var payload: [String: JSONValue] = [
        "taskID": .string(claim.taskID.uuidString),
        "owner": .string(claim.ownerName),
        "claimedAt": .string(ISO8601DateFormatter().string(from: claim.claimedAt)),
        "expiresAt": .string(ISO8601DateFormatter().string(from: claim.expiresAt))
    ]
    if let checkpointID = claim.checkpointID {
        payload["checkpointID"] = .string(checkpointID.uuidString)
    }
    return payload
}

func taskClaimReleasePayload(_ release: ClaimReleaseResult) -> [String: JSONValue] {
    [
        "taskID": .string(release.taskID.uuidString),
        "owner": .string(release.ownerName),
        "released": .bool(release.released),
        "releasedAt": .string(ISO8601DateFormatter().string(from: release.releasedAt))
    ]
}

func printCheckpointResult(_ result: GitCheckpointResult) {
    print("Checkpoint created")
    print("  id:        \(result.checkpoint.id.uuidString)")
    print("  branch:    \(result.checkpoint.branch)")
    print("  commit:    \(result.checkpoint.commitSHA ?? "-")")
    print("  committed: \(result.committed ? "yes" : "no")")
    print("  pushed:    \(result.pushed ? "yes" : "no")")
    if result.pushed {
        print("  remote:    \(result.checkpoint.remoteName)")
    }
}

func printCheckpointRestoreResult(_ result: GitCheckpointRestoreResult) {
    print("Checkpoint restored")
    print("  id:     \(result.checkpoint.id.uuidString)")
    print("  branch: \(result.checkpoint.branch)")
    print("  commit: \(result.headSHA ?? result.checkpoint.commitSHA ?? "-")")
    print("  remote: \(result.fetched ? result.checkpoint.remoteName : "-")")
    print("  files:  \(checkpointChangedFileCount(result.checkpoint))")
    if result.advancedBeyondCheckpoint {
        print("  note:   branch is ahead of the checkpoint commit")
    }
}

func checkpointRestoreStatus(_ result: GitCheckpointRestoreResult) -> String {
    let commit = shortCommit(result.headSHA ?? result.checkpoint.commitSHA)
    let advanced = result.advancedBeyondCheckpoint ? ", branch ahead of checkpoint" : ""
    return "Restored checkpoint \(result.checkpoint.branch) @ \(commit)\(advanced) (\(checkpointChangedFileCount(result.checkpoint)) files)."
}

func taskClaimStatus(_ claim: TaskClaimRecord) -> String {
    "Claimed task for \(claim.ownerName) until \(ISO8601DateFormatter().string(from: claim.expiresAt))."
}

func checkpointCreatedStatus(_ result: GitCheckpointResult) -> String {
    let commit = shortCommit(result.checkpoint.commitSHA)
    let pushed = result.pushed ? ", pushed to \(result.checkpoint.remoteName)" : ""
    return "Created checkpoint \(result.checkpoint.branch) @ \(commit)\(pushed)."
}

func shortCommit(_ commit: String?) -> String {
    guard let commit, !commit.isEmpty else {
        return "-"
    }
    return String(commit.prefix(8))
}

func printCheckpoints(_ checkpoints: [CheckpointRecord]) {
    if checkpoints.isEmpty {
        print("No checkpoints found.")
        return
    }

    for checkpoint in checkpoints {
        print("\(checkpoint.branch)")
        print("  id:      \(checkpoint.id.uuidString)")
        print("  commit:  \(checkpoint.commitSHA ?? "-")")
        print("  remote:  \(checkpoint.remoteName)")
        print("  pushed:  \(checkpoint.pushedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
        print("  files:   \(checkpointChangedFileCount(checkpoint))")
    }
}

func printArtifacts(_ artifacts: [ArtifactRecord]) {
    if artifacts.isEmpty {
        print("No artifacts found.")
        return
    }

    for artifact in artifacts {
        print("\(artifact.kind.rawValue)  \(artifact.title)")
        print("  id:      \(artifact.id.uuidString)")
        print("  ref:     \(artifact.contentRef)")
        print("  type:    \(artifact.contentType ?? "-")")
        print("  created: \(ISO8601DateFormatter().string(from: artifact.createdAt))")
        if let checkpointID = artifact.metadata["checkpointID"]?.stringValue {
            print("  checkpoint: \(String(checkpointID.prefix(8)))")
        }
    }
}

func activeTaskClaim(_ claim: TaskClaimRecord?, now: Date = Date()) -> TaskClaimRecord? {
    guard let claim, claim.expiresAt > now else {
        return nil
    }
    return claim
}

func checkpointChangedFileCount(_ checkpoint: CheckpointRecord) -> Int {
    guard let values = checkpoint.metadata["changedFiles"]?.arrayValue else {
        return 0
    }
    return values.count
}

struct TranscriptExportResult: Equatable, Sendable {
    var url: URL
    var eventCount: Int
}

struct ContinuationExportResult: Codable, Equatable, Sendable {
    var url: URL
    var eventCount: Int
    var checkpointCount: Int
    var artifactCount: Int
}

func exportTranscriptMarkdown(
    task: TaskRecord,
    store: any AgentTaskStore,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    destination: String?
) async throws -> TranscriptExportResult {
    let events = try await store.events(for: task.id)
    let url = transcriptExportURL(
        task: task,
        repoURL: repoURL,
        snapshot: snapshot,
        destination: destination
    )
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let markdown = transcriptMarkdown(task: task, events: events, exportedAt: Date())
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    try await store.saveArtifact(ArtifactRecord(
        taskID: task.id,
        kind: .transcriptExport,
        title: url.lastPathComponent,
        contentRef: url.path,
        contentType: "text/markdown",
        metadata: [
            "path": .string(url.path),
            "eventCount": .int(Int64(events.count))
        ]
    ))
    return TranscriptExportResult(url: url, eventCount: events.count)
}

func exportContinuationMarkdown(
    task: TaskRecord,
    store: any AgentTaskStore,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    destination: String?
) async throws -> ContinuationExportResult {
    let events = try await store.recentEvents(for: task.id, limit: 120)
    let checkpoints = try await store.listCheckpoints(taskID: task.id)
    let artifacts = try await store.listArtifacts(taskID: task.id)
    let claim = try? await store.currentTaskClaim(taskID: task.id)
    let url = continuationExportURL(
        task: task,
        repoURL: repoURL,
        snapshot: snapshot,
        destination: destination
    )
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let markdown = continuationMarkdown(
        task: task,
        events: events,
        checkpoints: checkpoints,
        artifacts: artifacts,
        currentClaim: activeTaskClaim(claim),
        exportedAt: Date()
    )
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    try await store.saveArtifact(ArtifactRecord(
        taskID: task.id,
        kind: .continuationPrompt,
        title: url.lastPathComponent,
        contentRef: url.path,
        contentType: "text/markdown",
        metadata: [
            "path": .string(url.path),
            "eventCount": .int(Int64(events.count)),
            "checkpointCount": .int(Int64(checkpoints.count)),
            "artifactCount": .int(Int64(artifacts.count))
        ]
    ))
    return ContinuationExportResult(
        url: url,
        eventCount: events.count,
        checkpointCount: checkpoints.count,
        artifactCount: artifacts.count
    )
}

func transcriptExportURL(
    task: TaskRecord,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    destination: String?,
    now: Date = Date()
) -> URL {
    let baseURL = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
    let filename = defaultTranscriptExportFilename(task: task, now: now)
    let rawDestination = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawDestination.isEmpty else {
        return baseURL
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(filename)
    }

    let expandedDestination: String
    if rawDestination == "~" {
        expandedDestination = FileManager.default.homeDirectoryForCurrentUser.path
    } else if rawDestination.hasPrefix("~/") {
        expandedDestination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawDestination.dropFirst(2)))
            .path
    } else {
        expandedDestination = rawDestination
    }

    var url = expandedDestination.hasPrefix("/")
        ? URL(fileURLWithPath: expandedDestination)
        : baseURL.appendingPathComponent(expandedDestination)
    if rawDestination.hasSuffix("/") {
        url.appendPathComponent(filename)
    } else if url.pathExtension.isEmpty {
        url.appendPathExtension("md")
    }
    return url
}

func continuationExportURL(
    task: TaskRecord,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    destination: String?,
    now: Date = Date()
) -> URL {
    exportURL(
        task: task,
        repoURL: repoURL,
        snapshot: snapshot,
        destination: destination,
        filename: defaultContinuationExportFilename(task: task, now: now)
    )
}

func defaultTranscriptExportFilename(task: TaskRecord, now: Date) -> String {
    defaultExportFilename(task: task, label: "transcript", now: now)
}

func defaultContinuationExportFilename(task: TaskRecord, now: Date) -> String {
    defaultExportFilename(task: task, label: "continue", now: now)
}

private func defaultExportFilename(task: TaskRecord, label: String, now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(task.slug)-\(label)-\(formatter.string(from: now)).md"
}

private func exportURL(
    task: TaskRecord,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    destination: String?,
    filename: String
) -> URL {
    let baseURL = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
    let rawDestination = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawDestination.isEmpty else {
        return baseURL
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(filename)
    }

    let expandedDestination: String
    if rawDestination == "~" {
        expandedDestination = FileManager.default.homeDirectoryForCurrentUser.path
    } else if rawDestination.hasPrefix("~/") {
        expandedDestination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawDestination.dropFirst(2)))
            .path
    } else {
        expandedDestination = rawDestination
    }

    var url = expandedDestination.hasPrefix("/")
        ? URL(fileURLWithPath: expandedDestination)
        : baseURL.appendingPathComponent(expandedDestination)
    if rawDestination.hasSuffix("/") {
        url.appendPathComponent(filename)
    } else if url.pathExtension.isEmpty {
        url.appendPathExtension("md")
    }
    return url
}

func continuationMarkdown(
    task: TaskRecord,
    events: [AgentEvent],
    checkpoints: [CheckpointRecord],
    artifacts: [ArtifactRecord],
    currentClaim: TaskClaimRecord?,
    exportedAt: Date
) -> String {
    let latestCheckpoint = checkpoints.max { $0.createdAt < $1.createdAt }
    var blocks: [String] = [
        "# Continue \(task.title)",
        """
        You are continuing an `agentctl` task from a portable handoff bundle. This is lossy context, not the model's hidden state. Use the task metadata, latest checkpoint, artifacts, recent commands, tests, and recent transcript below to continue the work.
        """,
        [
            "## Task",
            "- Slug: `\(task.slug)`",
            "- Task ID: `\(task.id.uuidString)`",
            "- Backend: `\(task.backendPreference.rawValue)`",
            "- State: `\(task.state.rawValue)`",
            "- Exported: `\(ISO8601DateFormatter().string(from: exportedAt))`"
        ].joined(separator: "\n")
    ]

    if let currentClaim {
        blocks.append([
            "## Active Claim",
            "- Owner: `\(currentClaim.ownerName)`",
            "- Expires: `\(ISO8601DateFormatter().string(from: currentClaim.expiresAt))`"
        ].joined(separator: "\n"))
    }

    if let checkpoint = latestCheckpoint {
        blocks.append(continuationCheckpointMarkdown(checkpoint))
    } else {
        blocks.append("## Latest Checkpoint\n\nNo checkpoint recorded for this task.")
    }

    let artifactBlock = continuationArtifactsMarkdown(artifacts)
    if !artifactBlock.isEmpty {
        blocks.append(artifactBlock)
    }

    let commandBlock = continuationCommandMarkdown(events: events, artifacts: artifacts, latestCheckpoint: latestCheckpoint)
    if !commandBlock.isEmpty {
        blocks.append(commandBlock)
    }

    blocks.append(continuationRecentTranscriptMarkdown(events))
    return blocks.joined(separator: "\n\n") + "\n"
}

private func continuationCheckpointMarkdown(_ checkpoint: CheckpointRecord) -> String {
    var lines = [
        "## Latest Checkpoint",
        "- Checkpoint: `\(checkpoint.id.uuidString)`",
        "- Branch: `\(checkpoint.branch)`",
        "- Commit: `\(checkpoint.commitSHA ?? "-")`",
        "- Remote: `\(checkpoint.remoteName)`",
        "- Pushed: `\(checkpoint.pushedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")`"
    ]

    let changedFiles = jsonStringArray(checkpoint.metadata["changedFiles"])
    if !changedFiles.isEmpty {
        lines.append("")
        lines.append("Changed files:")
        lines.append(contentsOf: changedFiles.prefix(40).map { "- `\($0)`" })
    }

    let generatedFiles = jsonStringArray(checkpoint.metadata["generatedFiles"])
    if !generatedFiles.isEmpty {
        lines.append("")
        lines.append("Generated files:")
        lines.append(contentsOf: generatedFiles.prefix(40).map { "- `\($0)`" })
    }

    if let cursor = checkpoint.metadata["transcriptCursor"]?.objectValue {
        lines.append("")
        lines.append("Transcript cursor: \(checkpointTranscriptCursorSummary(cursor))")
    } else if let manifest = checkpoint.metadata["handoffManifest"]?.objectValue {
        lines.append("")
        lines.append("Legacy handoff manifest: \(handoffManifestSummary(manifest))")
    }

    return lines.joined(separator: "\n")
}

private func continuationArtifactsMarkdown(_ artifacts: [ArtifactRecord]) -> String {
    guard !artifacts.isEmpty else {
        return ""
    }

    var lines = ["## Artifacts"]
    for artifact in artifacts.prefix(30) {
        let checkpoint = artifact.metadata["checkpointID"]?.stringValue.map { " checkpoint `\(String($0.prefix(8)))`" } ?? ""
        lines.append("- `\(artifact.kind.rawValue)` \(artifact.title) -> `\(artifact.contentRef)`\(checkpoint)")
    }
    return lines.joined(separator: "\n")
}

private func continuationCommandMarkdown(
    events: [AgentEvent],
    artifacts: [ArtifactRecord],
    latestCheckpoint: CheckpointRecord?
) -> String {
    var lines: [String] = []
    let commandArtifacts = artifacts.filter { $0.kind == .commandOutput || $0.kind == .testResult }
    for artifact in commandArtifacts.prefix(12) {
        if let command = artifact.metadata["command"]?.stringValue {
            let status = artifact.metadata["status"]?.stringValue
                ?? artifact.metadata["exitCode"]?.stringValue
                ?? "-"
            lines.append("- `\(command)` -> \(status)")
        }
    }

    if lines.isEmpty,
       let manifest = latestCheckpoint?.metadata["handoffManifest"]?.objectValue,
       let commandOutputs = manifest["commandOutputs"]?.arrayValue {
        for value in commandOutputs.prefix(12) {
            guard let object = value.objectValue,
                  let command = object["command"]?.stringValue else {
                continue
            }
            let exitCode: String
            if case let .int(value) = object["exitCode"] {
                exitCode = "exit \(value)"
            } else {
                exitCode = "-"
            }
            lines.append("- `\(command)` -> \(exitCode)")
        }
    }

    if lines.isEmpty {
        let toolEvents = events.filter { $0.kind == .toolFinished }
        for event in toolEvents.suffix(12) {
            guard let command = event.payload["command"]?.stringValue else {
                continue
            }
            let exitCode: String
            if case let .int(value) = event.payload["exitCode"] {
                exitCode = "exit \(value)"
            } else {
                exitCode = "-"
            }
            lines.append("- `\(command)` -> \(exitCode)")
        }
    }

    guard !lines.isEmpty else {
        return ""
    }
    return (["## Recent Commands And Tests"] + lines).joined(separator: "\n")
}

private func continuationRecentTranscriptMarkdown(_ events: [AgentEvent]) -> String {
    var blocks = ["## Recent Transcript"]
    let transcriptEvents = events.filter { event in
        event.kind == .userMessage || event.kind == .assistantDone || event.kind == .toolFinished
    }

    if transcriptEvents.isEmpty {
        return "## Recent Transcript\n\nNo transcript events found."
    }

    for event in transcriptEvents.suffix(18) {
        switch event.kind {
        case .userMessage:
            if let text = event.payload["text"]?.stringValue {
                blocks.append("### User\n\n\(markdownQuote(truncateHandoffText(text, limit: 2_000)))")
            }
        case .assistantDone:
            if let text = event.payload["text"]?.stringValue {
                blocks.append("### Codex\n\n\(truncateHandoffText(text, limit: 4_000))")
            }
        case .toolFinished:
            if let command = event.payload["command"]?.stringValue {
                var text = "### Tool\n\n\(markdownFence(language: "sh", text: "$ \(command)"))"
                if let output = event.payload["output"]?.stringValue,
                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text += "\n\n" + markdownFence(language: "text", text: truncateHandoffText(output, limit: 2_000))
                }
                blocks.append(text)
            }
        default:
            break
        }
    }

    return blocks.joined(separator: "\n\n")
}

private func jsonStringArray(_ value: JSONValue?) -> [String] {
    value?.arrayValue?.compactMap(\.stringValue) ?? []
}

func transcriptMarkdown(task: TaskRecord, events: [AgentEvent], exportedAt: Date) -> String {
    var blocks: [String] = [
        "# \(task.title)",
        [
            "- Task: `\(task.slug)`",
            "- Task ID: `\(task.id.uuidString)`",
            "- Exported: `\(ISO8601DateFormatter().string(from: exportedAt))`"
        ].joined(separator: "\n")
    ]

    var renderedCount = 0
    for event in events {
        guard let block = transcriptMarkdownBlock(for: event) else {
            continue
        }
        renderedCount += 1
        blocks.append(block)
    }

    if renderedCount == 0 {
        blocks.append("_No transcript events found._")
    }

    return blocks.joined(separator: "\n\n") + "\n"
}

private func transcriptMarkdownBlock(for event: AgentEvent) -> String? {
    switch event.kind {
    case .userMessage:
        guard let text = event.payload["text"]?.stringValue else {
            return nil
        }
        return "## User\n\n\(markdownQuote(text))"
    case .assistantDone:
        guard let text = event.payload["text"]?.stringValue else {
            return nil
        }
        return "## Codex\n\n\(text)"
    case .toolFinished:
        return toolTranscriptMarkdownBlock(event.payload)
    case .checkpointCreated:
        return checkpointTranscriptMarkdownBlock(title: "Checkpoint", payload: event.payload)
    case .handoffCreated:
        return checkpointTranscriptMarkdownBlock(title: "Handoff", payload: event.payload)
    case .taskClaimed:
        return claimTranscriptMarkdownBlock(title: "Claimed", payload: event.payload)
    case .taskClaimRefreshed:
        return claimTranscriptMarkdownBlock(title: "Claim Refreshed", payload: event.payload)
    case .taskClaimReleased:
        return claimTranscriptMarkdownBlock(title: "Claim Released", payload: event.payload)
    default:
        return nil
    }
}

private func toolTranscriptMarkdownBlock(_ payload: [String: JSONValue]) -> String? {
    guard let command = payload["command"]?.stringValue else {
        return nil
    }

    var lines = ["## Tool", markdownFence(language: "sh", text: "$ \(command)")]
    if case let .int(exitCode) = payload["exitCode"] {
        lines.append("Exit code: `\(exitCode)`")
    }
    if let output = payload["output"]?.stringValue,
       !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(markdownFence(language: "text", text: output))
    }
    return lines.joined(separator: "\n\n")
}

private func checkpointTranscriptMarkdownBlock(title: String, payload: [String: JSONValue]) -> String {
    var lines = ["## \(title)"]
    if let checkpointID = payload["checkpointID"]?.stringValue {
        lines.append("- Checkpoint: `\(checkpointID)`")
    }
    if let branch = payload["branch"]?.stringValue {
        lines.append("- Branch: `\(branch)`")
    }
    if let commit = payload["commitSHA"]?.stringValue {
        lines.append("- Commit: `\(commit)`")
    }
    if let pushed = payload["pushed"] {
        lines.append("- Pushed: `\(pushed == .bool(true) ? "yes" : "no")`")
    }
    if let cursor = payload["transcriptCursor"]?.objectValue {
        lines.append("- Transcript cursor: \(checkpointTranscriptCursorSummary(cursor))")
    } else if let manifest = payload["handoffManifest"]?.objectValue {
        lines.append("- Legacy handoff: \(handoffManifestSummary(manifest))")
    }
    return lines.joined(separator: "\n")
}

private func claimTranscriptMarkdownBlock(title: String, payload: [String: JSONValue]) -> String {
    var lines = ["## \(title)"]
    if let owner = payload["owner"]?.stringValue {
        lines.append("- Owner: `\(owner)`")
    }
    if let checkpointID = payload["checkpointID"]?.stringValue {
        lines.append("- Checkpoint: `\(checkpointID)`")
    }
    if let expiresAt = payload["expiresAt"]?.stringValue {
        lines.append("- Expires: `\(expiresAt)`")
    }
    if let releasedAt = payload["releasedAt"]?.stringValue {
        lines.append("- Released: `\(releasedAt)`")
    }
    return lines.joined(separator: "\n")
}

private func handoffManifestSummary(_ manifest: [String: JSONValue]) -> String {
    let files = manifest["changedFiles"]?.arrayValue?.count ?? 0
    let generated = manifest["generatedFiles"]?.arrayValue?.count ?? 0
    let commands = manifest["commandOutputs"]?.arrayValue?.count ?? 0
    let tests = manifest["testResults"]?.arrayValue?.count ?? 0
    return "`\(files)` files, `\(generated)` generated, `\(commands)` commands, `\(tests)` tests"
}

private func checkpointTranscriptCursorSummary(_ cursor: [String: JSONValue]) -> String {
    let sequence: String
    if case let .int(value) = cursor["eventSequence"] {
        sequence = "#\(value)"
    } else {
        sequence = "-"
    }
    let kind = cursor["eventKind"]?.stringValue ?? "none"
    let session = cursor["sessionID"]?.stringValue.map { String($0.prefix(8)) } ?? "-"
    return "`\(sequence)` `\(kind)` session `\(session)`"
}

private func markdownQuote(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            line.isEmpty ? ">" : "> \(line)"
        }
        .joined(separator: "\n")
}

private func markdownFence(language: String, text: String) -> String {
    let longestBacktickRun = text.split(whereSeparator: { $0 != "`" })
        .map(\.count)
        .max() ?? 0
    let fence = String(repeating: "`", count: max(3, longestBacktickRun + 1))
    return "\(fence)\(language)\n\(text)\n\(fence)"
}

func printRunSummary(_ summary: TaskRunSummary) {
    let latestSessionID = summary.sessions.first?.id
    let assistantMessages = summary.latestEvents.compactMap { event -> String? in
        guard event.kind == .assistantDone else {
            return nil
        }
        if let latestSessionID, event.sessionID != latestSessionID {
            return nil
        }
        return event.payload["text"]?.stringValue
    }

    if assistantMessages.isEmpty {
        printTaskSummary(summary)
    } else {
        print(assistantMessages.joined(separator: "\n"))
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw RuntimeError("failed to encode JSON as UTF-8")
    }

    print(text)
}

struct RuntimeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

func agentctlErrorMessage(_ error: Error) -> String {
    let described = String(describing: error)
    let message: String
    if described.contains("Generic description to prevent accidental leakage") {
        message = String(reflecting: error)
    } else {
        message = described
    }

    if message.contains("task_claims") || message.contains("schema is out of date") {
        return "\(message)\nRun `swift run agentctl db migrate` with the same `AGENTCTL_DATABASE_URL`, then try again."
    }
    return message
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func flushStdout() {
    fflush(stdout)
}
