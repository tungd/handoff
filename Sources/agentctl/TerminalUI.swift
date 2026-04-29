import AgentCore
import Foundation

struct SlashCommand: Equatable {
    var name: String
    var argument: String?

    init?(_ input: String) {
        guard input.hasPrefix("/") else {
            return nil
        }

        let trimmed = input.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        name = String(parts[0])
        argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

enum AgentTUISubmission: Equatable {
    case agentctlCommand(SlashCommand)
    case backendPrompt(String)
}

private let agentctlSlashCommandNames: Set<String> = [
    "artifacts",
    "checkpoint",
    "checkpoints",
    "continue",
    "events",
    "exit",
    "export",
    "help",
    "info",
    "new",
    "quit",
    "raw",
    "release",
    "repo",
    "resume",
    "task",
    "tasks"
]

func agentTUISubmission(for text: String, backend: AgentBackend) -> AgentTUISubmission {
    if text.hasPrefix("//") {
        return .backendPrompt(String(text.dropFirst()))
    }

    guard let command = SlashCommand(text) else {
        return .backendPrompt(text)
    }

    if agentctlSlashCommandNames.contains(command.name.lowercased()) {
        return .agentctlCommand(command)
    }

    if backend == .codex {
        return .backendPrompt(text)
    }

    return .agentctlCommand(command)
}
