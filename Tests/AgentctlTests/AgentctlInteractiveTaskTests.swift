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
}
