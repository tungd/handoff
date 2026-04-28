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
        subcommands: [New.self, List.self, Resume.self]
    )

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "new",
            abstract: "Create a task record preview."
        )

        @Argument(help: "Task title.")
        var title: String

        @Option(help: "Preferred backend.")
        var backend: AgentBackend = .codex

        @Option(name: .shortAndLong, help: "Repository path.")
        var repo: String = "."

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        mutating func run() throws {
            let snapshot = try RepositoryInspector().inspect(path: URL(fileURLWithPath: repo))
            let task = TaskRecord(
                title: title,
                slug: Slug.make(title),
                backendPreference: backend
            )

            let preview = TaskPreview(task: task, repository: snapshot)

            if json {
                try printJSON(preview)
                return
            }

            print("Task preview")
            print("  id:      \(task.id.uuidString)")
            print("  title:   \(task.title)")
            print("  slug:    \(task.slug)")
            print("  backend: \(task.backendPreference.rawValue)")
            print("  repo:    \(snapshot.rootPath ?? "not detected")")
            print("")
            print("Persistence is not wired yet; this command currently verifies the model and repo binding.")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List tasks from the sync store."
        )

        mutating func run() throws {
            print("Task store is not wired yet. Next step: PostgresNIO-backed TaskStore.")
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume a task by agentctl task id."
        )

        @Argument(help: "Task id or slug.")
        var task: String

        mutating func run() throws {
            print("Resume is not wired yet for \(task). Next step: CodexBackend + event store.")
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
