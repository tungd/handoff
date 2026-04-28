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

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct Agentctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentctl",
        abstract: "Task/session manager for Codex-first coding workflows.",
        discussion: "Run without a subcommand to start an interactive Codex session.",
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

    @Flag(help: "Pass --full-auto to Codex.")
    var fullAuto: Bool = false

    @Option(help: "Codex sandbox mode.")
    var sandbox: String?

    mutating func run() async throws {
        try await runInteractiveAgent(
            cwd: cwd,
            storeOptions: storeOptions,
            taskIdentifier: taskIdentifier,
            title: title,
            fullAuto: fullAuto,
            sandbox: sandbox
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
        subcommands: [New.self, List.self, Show.self, Send.self, Resume.self]
    )

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "new",
            abstract: "Create a task record, optionally running the first Codex turn."
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
                    let summary = try await runCodexTurn(
                        task: task,
                        prompt: prompt,
                        repoURL: repoURL,
                        snapshot: snapshot,
                        store: store,
                        fullAuto: fullAuto,
                        sandbox: sandbox
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

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)

                let summary = try await runCodexTurn(
                    task: task,
                    prompt: prompt,
                    repoURL: repoURL,
                    snapshot: snapshot,
                    store: store,
                    fullAuto: fullAuto,
                    sandbox: sandbox
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

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() async throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
                let task = try await store.findTask(task)

                if let prompt {
                    let summary = try await runCodexTurn(
                        task: task,
                        prompt: prompt,
                        repoURL: repoURL,
                        snapshot: snapshot,
                        store: store,
                        fullAuto: fullAuto,
                        sandbox: sandbox
                    )

                    if json {
                        try printJSON(summary)
                        return
                    }

                    printRunSummary(summary)
                    return
                }

                let summary = try await store.summary(for: task)

                if json {
                    try printJSON(summary)
                    return
                }

                printTaskSummary(summary)
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
    fullAuto: Bool,
    sandbox: String?
) async throws {
    let repoURL = URL(fileURLWithPath: cwd)
    let snapshot = try RepositoryInspector().inspect(path: repoURL)

    try await withTaskStore(options: storeOptions, repoURL: repoURL, snapshot: snapshot) { store in
        let taskResolution = try await resolveInitialInteractiveTask(
            identifier: taskIdentifier,
            title: title,
            snapshot: snapshot,
            repoURL: repoURL,
            store: store
        )
        var task = taskResolution.task
        var taskPersisted = taskResolution.isPersisted

        if TerminalCapability.isInteractive {
            try await runTUIkitInteractiveLoop(
                task: task,
                taskPersisted: taskPersisted,
                storeOptions: storeOptions,
                repoURL: repoURL,
                snapshot: snapshot,
                store: store,
                fullAuto: fullAuto,
                sandbox: sandbox
            )
            return
        }

        let renderer = TerminalRenderer()
        var showRawEvents = false

        renderer.header(task: task, storeOptions: storeOptions, repoURL: repoURL, snapshot: snapshot)

        interactiveLoop: while true {
            renderer.prompt(task: task)
            guard let line = readLine() else {
                writeStdout("\n")
                break interactiveLoop
            }

            let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else {
                continue
            }

            if let command = SlashCommand(input) {
                switch command.name {
                case "exit", "quit":
                    break interactiveLoop
                case "help":
                    renderer.help()
                case "info", "task", "repo":
                    guard taskPersisted else {
                        renderer.status("No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                        continue
                    }
                    let summary = try await store.summary(for: task)
                    renderer.info(task: task, summary: summary, storeOptions: storeOptions, repoURL: repoURL, snapshot: snapshot)
                case "tasks":
                    renderer.tasks(try await store.listTasks())
                case "events":
                    guard taskPersisted else {
                        renderer.status("No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                        continue
                    }
                    renderer.events(try await store.events(for: task.id))
                case "raw":
                    showRawEvents.toggle()
                    renderer.status(showRawEvents ? "Raw event rendering enabled." : "Raw event rendering disabled.")
                case "new":
                    task = try await resolveInteractiveTask(
                        identifier: nil,
                        title: command.argument?.isEmpty == false ? command.argument : nil,
                        snapshot: snapshot,
                        repoURL: repoURL,
                        store: store
                    )
                    taskPersisted = true
                    renderer.header(task: task, storeOptions: storeOptions, repoURL: repoURL, snapshot: snapshot)
                case "resume":
                    guard let identifier = command.argument, !identifier.isEmpty else {
                        renderer.error("usage: /resume <task>")
                        continue
                    }
                    task = try await store.findTask(identifier)
                    taskPersisted = true
                    renderer.header(task: task, storeOptions: storeOptions, repoURL: repoURL, snapshot: snapshot)
                default:
                    renderer.error("unknown command: /\(command.name)")
                    renderer.help()
                }
                continue
            }

            do {
                if !taskPersisted {
                    try await persistInteractiveTask(task, store: store)
                    taskPersisted = true
                    renderer.header(task: task, storeOptions: storeOptions, repoURL: repoURL, snapshot: snapshot)
                }
                renderer.status("running Codex turn...")
                let assistantRendered = SendableFlag()
                let renderRawEvents = showRawEvents
                let summary = try await runCodexTurn(
                    task: task,
                    prompt: input,
                    repoURL: repoURL,
                    snapshot: snapshot,
                    store: store,
                    fullAuto: fullAuto,
                    sandbox: sandbox,
                    showStatus: false
                ) { update in
                    if renderer.render(update: update, showRawEvents: renderRawEvents) {
                        assistantRendered.value = true
                    }
                }
                if !assistantRendered.value {
                    printRunSummary(summary)
                }
            } catch {
                renderer.error("turn failed: \(error)")
            }
        }
    }
}

func resolveInitialInteractiveTask(
    identifier: String?,
    title: String?,
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
        task: makeInteractiveTask(title: title, snapshot: snapshot, repoURL: repoURL),
        isPersisted: false
    )
}

func resolveInteractiveTask(
    identifier: String?,
    title: String?,
    snapshot: RepositorySnapshot,
    repoURL: URL,
    store: any AgentTaskStore
) async throws -> TaskRecord {
    if let identifier {
        return try await store.findTask(identifier)
    }

    let task = makeInteractiveTask(title: title, snapshot: snapshot, repoURL: repoURL)
    try await persistInteractiveTask(task, store: store)
    return task
}

func makeInteractiveTask(
    title: String?,
    snapshot: RepositorySnapshot,
    repoURL: URL
) -> TaskRecord {
    let resolvedTitle = title ?? defaultInteractiveTaskTitle(snapshot: snapshot, repoURL: repoURL)
    return TaskRecord(
        title: resolvedTitle,
        slug: Slug.make(resolvedTitle),
        backendPreference: .codex
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

func runCodexTurn(
    task: TaskRecord,
    prompt: String,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    store: any AgentTaskStore,
    fullAuto: Bool,
    sandbox: String?,
    showStatus: Bool = true,
    onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void = { _ in }
) async throws -> TaskRunSummary {
    if showStatus {
        printError("Running Codex turn for \(task.slug)...")
    }

    let controller = AgentSessionController(store: store)
    return try await controller.runCodexTurn(
        task: task,
        prompt: prompt,
        repoURL: repoURL,
        snapshot: snapshot,
        options: CodexExecOptions(fullAuto: fullAuto, sandbox: sandbox),
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

    if !summary.latestEvents.isEmpty {
        print("")
        print("Recent events")
        for event in summary.latestEvents {
            print("  \(event.sequence ?? 0): \(event.kind.rawValue)")
        }
    }
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

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func flushStdout() {
    fflush(stdout)
}
