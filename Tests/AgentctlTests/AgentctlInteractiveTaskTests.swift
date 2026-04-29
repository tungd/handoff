import AgentCore
import Foundation
import Testing
@testable import agentctl

@Suite("Agentctl interactive task lifecycle")
struct AgentctlInteractiveTaskTests {
    @Test
    func initialInteractiveTaskStartsAsUnpersistedDraft() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: any AgentTaskStore = LocalTaskStore(root: root)
        let snapshot = RepositorySnapshot(isGitRepository: false)

        let resolution = try await resolveInitialInteractiveTask(
            identifier: nil,
            title: "Draft task",
            snapshot: snapshot,
            repoURL: root,
            store: store
        )

        #expect(resolution.isPersisted == false)
        #expect(resolution.task.slug == "draft-task")
        #expect(try await store.listTasks().isEmpty)

        try await persistInteractiveTask(resolution.task, store: store)

        #expect(try await store.listTasks().map(\.id) == [resolution.task.id])
        #expect(try await store.events(for: resolution.task.id).map(\.kind) == [.taskCreated])
    }

    @Test
    func initialInteractiveTaskCanResolveExistingTaskWithoutCreatingAnother() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentctl-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: any AgentTaskStore = LocalTaskStore(root: root)
        let existing = TaskRecord(title: "Existing", slug: "existing")
        try await store.saveTask(existing)

        let resolution = try await resolveInitialInteractiveTask(
            identifier: "existing",
            title: nil,
            snapshot: RepositorySnapshot(isGitRepository: false),
            repoURL: root,
            store: store
        )

        #expect(resolution.isPersisted == true)
        #expect(resolution.task.id == existing.id)
        #expect(try await store.listTasks().map(\.id) == [existing.id])
    }

    @Test
    func checkpointSlashOptionsSupportLocalAndPushModes() throws {
        #expect(try checkpointSlashOptions(nil).push == false)
        #expect(try checkpointSlashOptions("").push == false)
        #expect(try checkpointSlashOptions("--push").push)
    }

    @Test
    func resumeSlashOptionsParseCheckpointSelector() throws {
        let options = try resumeSlashOptions("cashout --checkpoint latest")

        #expect(options.taskIdentifier == "cashout")
        #expect(options.checkpointSelector == "latest")
        #expect(options.forceClaim == false)

        let forced = try resumeSlashOptions("cashout --force")
        #expect(forced.taskIdentifier == "cashout")
        #expect(forced.forceClaim)
    }

    @Test
    func selectCheckpointSupportsLatestAndIDPrefix() throws {
        let first = CheckpointRecord(taskID: UUID(), branch: "agent/first")
        let second = CheckpointRecord(taskID: UUID(), branch: "agent/second")

        #expect(try selectCheckpoint([first, second], selector: nil)?.id == first.id)
        #expect(try selectCheckpoint([first, second], selector: String(second.id.uuidString.prefix(8)))?.id == second.id)
    }

    @Test
    func transcriptMarkdownExportsUserAssistantAndToolEvents() throws {
        let task = TaskRecord(title: "Export Demo", slug: "export-demo")
        let events = [
            AgentEvent(taskID: task.id, kind: .userMessage, payload: [
                "text": .string("hello\nworld")
            ]),
            AgentEvent(taskID: task.id, kind: .assistantDone, payload: [
                "text": .string("**done**")
            ]),
            AgentEvent(taskID: task.id, kind: .toolFinished, payload: [
                "command": .string("swift test"),
                "exitCode": .int(0),
                "output": .string("passed\n")
            ])
        ]

        let markdown = transcriptMarkdown(
            task: task,
            events: events,
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(markdown.contains("# Export Demo"))
        #expect(markdown.contains("> hello\n> world"))
        #expect(markdown.contains("## Codex\n\n**done**"))
        #expect(markdown.contains("```sh\n$ swift test\n```"))
        #expect(markdown.contains("```text\npassed\n\n```"))
    }

    @Test
    func transcriptExportURLDefaultsInsideAgentctlExports() throws {
        let task = TaskRecord(title: "Export Demo", slug: "export-demo")
        let root = URL(fileURLWithPath: "/tmp/agentctl-export", isDirectory: true)
        let url = transcriptExportURL(
            task: task,
            repoURL: root,
            snapshot: RepositorySnapshot(isGitRepository: true, rootPath: root.path),
            destination: nil,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(url.path == "/tmp/agentctl-export/.agentctl/exports/export-demo-transcript-19700101-000000.md")
    }

    @Test
    func handoffManifestContextCapturesRecentToolAndTestOutput() throws {
        let events = [
            AgentEvent(kind: .toolFinished, payload: [
                "command": .string("swift test"),
                "exitCode": .int(0),
                "output": .string("all passed")
            ]),
            AgentEvent(kind: .toolFinished, payload: [
                "command": .string("git status --short"),
                "exitCode": .int(0),
                "output": .string("M README.md")
            ])
        ]

        let manifest = handoffManifestContext(events: events)

        #expect(manifest.commandOutputs.map(\.command) == ["swift test", "git status --short"])
        #expect(manifest.testResults.map(\.command) == ["swift test"])
        #expect(manifest.testResults.first?.status == "passed")
    }
}
