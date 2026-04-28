import AgentCore
import ArgumentParser
import Foundation

extension AgentBackend: ExpressibleByArgument {}

@main
struct Agentctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentctl",
        abstract: "Task/session manager for Codex-first coding workflows.",
        discussion: "Run without a subcommand to inspect the current repository.",
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

    mutating func run() throws {
        var inspect = Repo.Inspect(path: cwd, json: false)
        try inspect.run()
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
    }
}

struct Task: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "Create, list, and resume agentctl tasks.",
        subcommands: [New.self, List.self, Show.self, Send.self, Resume.self]
    )

    struct New: ParsableCommand {
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

        @Option(help: "Initial prompt to send to the preferred backend.")
        var prompt: String?

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let store = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
            let task = TaskRecord(
                title: title,
                slug: Slug.make(title),
                backendPreference: backend
            )

            try store.saveTask(task)
            try store.appendEvent(AgentEvent(taskID: task.id, kind: .taskCreated, payload: [
                "title": .string(task.title),
                "slug": .string(task.slug),
                "backend": .string(task.backendPreference.rawValue)
            ]))

            if let prompt {
                let summary = try runCodexTurn(
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
            print("  store:   \(store.root.path)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List local tasks."
        )

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let store = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
            let tasks = try store.listTasks()

            if json {
                try printJSON(tasks)
                return
            }

            if tasks.isEmpty {
                print("No local tasks found at \(store.root.path).")
                return
            }

            for task in tasks {
                let sessions = try store.listSessions(taskID: task.id)
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

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a local task summary."
        )

        @Argument(help: "Task id, id prefix, or slug.")
        var task: String

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let store = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
            let task = try store.findTask(task)
            let summary = try store.summary(for: task)

            if json {
                try printJSON(summary)
                return
            }

            printTaskSummary(summary)
        }
    }

    struct Send: ParsableCommand {
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

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let store = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
            let task = try store.findTask(task)

            let summary = try runCodexTurn(
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

    struct Resume: ParsableCommand {
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

        @Flag(help: "Pass --full-auto to Codex.")
        var fullAuto: Bool = false

        @Option(help: "Codex sandbox mode.")
        var sandbox: String?

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let repoURL = URL(fileURLWithPath: repo)
            let snapshot = try RepositoryInspector().inspect(path: repoURL)
            let store = LocalTaskStore(root: StorePathResolver.defaultRoot(cwd: repoURL, snapshot: snapshot))
            let task = try store.findTask(task)

            if let prompt {
                let summary = try runCodexTurn(
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
            } else {
                let summary = try store.summary(for: task)

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
        subcommands: [Schema.self]
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

func runCodexTurn(
    task: TaskRecord,
    prompt: String,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    store: LocalTaskStore,
    fullAuto: Bool,
    sandbox: String?
) throws -> TaskRunSummary {
    guard task.backendPreference == .codex else {
        throw RuntimeError("only the Codex backend is wired in v1")
    }

    let cwd = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
    let previousSession = try store.latestSession(for: task.id)
    var session = SessionRecord(
        taskID: task.id,
        backend: .codex,
        backendSessionID: previousSession?.backendSessionID,
        cwd: cwd.path,
        state: .running
    )

    try store.saveSession(session)
    try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionStarted, payload: [
        "backend": .string(session.backend.rawValue),
        "cwd": .string(session.cwd),
        "resumeThreadID": session.backendSessionID.map { .string($0) } ?? .null
    ]))
    try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage, payload: [
        "text": .string(prompt)
    ]))

    printError("Running Codex turn for \(task.slug)...")

    let result = try CodexExecBackend().run(
        prompt: prompt,
        cwd: cwd,
        resumeThreadID: session.backendSessionID,
        options: CodexExecOptions(fullAuto: fullAuto, sandbox: sandbox)
    )

    if let threadID = result.threadID {
        session.backendSessionID = threadID
    }

    session.state = result.exitCode == 0 ? .ended : .failed
    session.endedAt = Date()

    for event in result.events {
        var stored = event
        stored.taskID = task.id
        stored.sessionID = session.id
        try store.appendEvent(stored)
    }

    if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .backendEvent, payload: [
            "stderr": .string(result.stderr)
        ]))
    }

    try store.appendEvent(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionEnded, payload: [
        "exitCode": .int(Int64(result.exitCode)),
        "threadID": session.backendSessionID.map { .string($0) } ?? .null
    ]))
    try store.saveSession(session)

    if result.exitCode != 0 {
        throw RuntimeError("Codex exited with \(result.exitCode): \(result.stderr)")
    }

    return try store.summary(for: task)
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
