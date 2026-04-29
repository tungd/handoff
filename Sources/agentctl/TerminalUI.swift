import Foundation

struct SlashCommand {
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