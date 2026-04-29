import AgentCore
import Testing
@testable import agentctl

@Suite("AgentTUI slash commands")
struct AgentTUISlashCommandTests {
    @Test
    func knownAgentctlCommandRoutesLocallyForCodexTasks() {
        let submission = agentTUISubmission(
            for: "/resume interactive-agent --checkpoint latest",
            backend: .codex
        )

        guard case let .agentctlCommand(command) = submission else {
            Issue.record("expected /resume to route to agentctl")
            return
        }
        #expect(command.name == "resume")
        #expect(command.argument == "interactive-agent --checkpoint latest")
    }

    @Test
    func unknownSlashCommandPassesThroughForCodexTasks() {
        let submission = agentTUISubmission(for: "/model gpt-5.5", backend: .codex)

        #expect(submission == .backendPrompt("/model gpt-5.5"))
    }

    @Test
    func doubleSlashEscapesAgentctlCommandNames() {
        let submission = agentTUISubmission(for: "//help", backend: .codex)

        #expect(submission == .backendPrompt("/help"))
    }

    @Test
    func unknownSlashCommandStaysLocalForNonCodexTasks() {
        let submission = agentTUISubmission(for: "/model cheap", backend: .pi)

        guard case let .agentctlCommand(command) = submission else {
            Issue.record("expected non-Codex slash command to route to agentctl")
            return
        }
        #expect(command.name == "model")
        #expect(command.argument == "cheap")
    }

    @Test
    func regularPromptRoutesToBackend() {
        let submission = agentTUISubmission(for: "hello", backend: .codex)

        #expect(submission == .backendPrompt("hello"))
    }
}
