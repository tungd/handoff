import AgentCore
import ArgumentParser
import Foundation
import Testing
@testable import agentctl

@Suite("Agentctl memory commands")
struct AgentctlMemoryCommandTests {
    @Test
    func interactiveDefaultCommandKeepsRootInvocationOptions() throws {
        let interactive = try #require(try Agentctl.parseAsRoot([
            "--title",
            "Draft task",
            "--backend",
            "pi"
        ]) as? Agentctl.Interactive)

        #expect(interactive.title == "Draft task")
        #expect(interactive.backend == .pi)
    }

    @Test
    func topLevelMemoryCommandsParse() throws {
        let search = try #require(try Agentctl.parseAsRoot([
            "memory",
            "search",
            "release checklist",
            "--limit",
            "5"
        ]) as? Memory.Search)
        #expect(search.query == "release checklist")
        #expect(search.limit == 5)

        let recent = try #require(try Agentctl.parseAsRoot([
            "memory",
            "recent",
            "--limit",
            "3"
        ]) as? Memory.Recent)
        #expect(recent.limit == 3)

        let write = try #require(try Agentctl.parseAsRoot([
            "memory",
            "write",
            "--title",
            "Use local store in tests",
            "--body",
            "Tests should use the local store unless they explicitly cover Postgres.",
            "--scope",
            "repo",
            "--tag",
            "tests"
        ]) as? Memory.Write)
        #expect(write.title == "Use local store in tests")
        #expect(write.scope == .repo)
        #expect(write.tags == ["tests"])

        let archive = try #require(try Agentctl.parseAsRoot([
            "memory",
            "archive",
            "00000000-0000-0000-0000-000000000000"
        ]) as? Memory.Archive)
        #expect(archive.id == "00000000-0000-0000-0000-000000000000")
    }

    @Test
    func oldMCPMemoryPlaceholderIsNotARootCommand() throws {
        do {
            _ = try Agentctl.parseAsRoot(["mcp", "memory"])
            Issue.record("agentctl mcp memory should not parse")
        } catch {
            #expect(String(describing: error).contains("mcp"))
        }
    }

    @Test
    func memoryRecordOutputUsesConciseStableFields() throws {
        let memory = MemoryItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            scopeKind: .globalPersonal,
            title: "Preference",
            body: "Prefer JSON output.",
            summary: "JSON output",
            tags: ["cli"],
            createdBy: "test",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            metadata: ["reviewStatus": .string("unreviewed")]
        )
        let output = MemoryRecordOutput(memory: memory, score: 0.75)
        let data = try JSONEncoder().encode(output)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(object["title"] as? String == "Preference")
        #expect(object["summary"] as? String == "JSON output")
        #expect(object["body"] as? String == "Prefer JSON output.")
        #expect(object["scope"] as? String == "global-personal")
        #expect(object["tags"] as? [String] == ["cli"])
        #expect(object["score"] as? Double == 0.75)
        #expect(object["createdAt"] != nil)
        #expect(object["updatedAt"] != nil)
        #expect(object["scopeKind"] == nil)
        #expect(object["metadata"] == nil)
    }

    @Test
    func syncedMemorySkillExamplesMatchCLI() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skillURL = packageRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("agentctl-memory", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: skillURL, encoding: .utf8)

        #expect(text.contains("agentctl memory recent --limit 10"))
        #expect(text.contains("agentctl memory search"))
        #expect(text.contains("agentctl memory write"))
        #expect(text.contains("agentctl memory archive"))
        #expect(!text.contains("--json"))
        #expect(!text.contains("mcp memory"))

        _ = try Agentctl.parseAsRoot(["memory", "recent", "--limit", "10"])
        _ = try Agentctl.parseAsRoot(["memory", "search", "release checklist", "--limit", "5"])
        _ = try Agentctl.parseAsRoot([
            "memory",
            "write",
            "--title",
            "Use local store in tests",
            "--body",
            "Tests should use --store local unless they are explicitly covering Postgres.",
            "--scope",
            "repo",
            "--tag",
            "tests"
        ])
        _ = try Agentctl.parseAsRoot(["memory", "archive", "00000000-0000-0000-0000-000000000000"])
    }
}
