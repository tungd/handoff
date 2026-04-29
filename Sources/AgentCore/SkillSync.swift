import Foundation

public enum SkillSyncError: Error, CustomStringConvertible, Sendable {
    case skillsRequirePostgres
    case skillWriteFailed(String)
    case agentsMdWriteFailed(String)

    public var description: String {
        switch self {
        case .skillsRequirePostgres:
            return "skills sync requires Postgres store; use --store postgres or set AGENTCTL_DATABASE_URL"
        case let .skillWriteFailed(detail):
            return "failed to write skill: \(detail)"
        case let .agentsMdWriteFailed(detail):
            return "failed to update AGENTS.md: \(detail)"
        }
    }
}

public struct SkillSyncResult: Equatable, Sendable {
    public var skillsDir: URL
    public var skillsWritten: Int
    public var agentsMdUpdated: Bool

    public init(skillsDir: URL, skillsWritten: Int, agentsMdUpdated: Bool) {
        self.skillsDir = skillsDir
        self.skillsWritten = skillsWritten
        self.agentsMdUpdated = agentsMdUpdated
    }
}

public enum SkillSync: Sendable {
    /// Sync skills FROM Postgres TO local .agentctl/skills/ directory
    public static func syncSkills(
        skills: [SkillRecord],
        repoRoot: URL
    ) throws -> SkillSyncResult {
        // Create .agentctl/skills directory
        let skillsDir = repoRoot
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        try FileManager.default.createDirectory(
            at: skillsDir,
            withIntermediateDirectories: true
        )

        // Write each skill to its own directory
        for skill in skills {
            let skillDir = skillsDir.appendingPathComponent(skill.name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: skillDir,
                withIntermediateDirectories: true
            )

            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            do {
                try skill.content.write(to: skillFile, atomically: true, encoding: .utf8)
            } catch {
                throw SkillSyncError.skillWriteFailed("\(skill.name): \(error)")
            }
        }

        // Update AGENTS.md
        let agentsMdPath = repoRoot.appendingPathComponent("AGENTS.md")
        let agentsMdUpdated = try updateAgentsMd(agentsMdPath: agentsMdPath, skills: skills)

        return SkillSyncResult(
            skillsDir: skillsDir,
            skillsWritten: skills.count,
            agentsMdUpdated: agentsMdUpdated
        )
    }

    public static func updateAgentsMd(
        agentsMdPath: URL,
        skills: [SkillRecord]
    ) throws -> Bool {
        let markerStart = "<!-- agentctl-skills-start -->"
        let markerEnd = "<!-- agentctl-skills-end -->"

        // Read existing content or create empty
        var existingContent: String
        if FileManager.default.fileExists(atPath: agentsMdPath.path) {
            existingContent = try String(contentsOf: agentsMdPath, encoding: .utf8)
        } else {
            existingContent = ""
        }

        // Build skills section
        let skillsSection = buildSkillsSection(skills: skills, markerStart: markerStart, markerEnd: markerEnd)

        // Check if markers exist
        if let startRange = existingContent.range(of: markerStart),
           let endRange = existingContent.range(of: markerEnd) {
            // Replace existing section
            let replaceRange = startRange.lowerBound..<endRange.upperBound
            let newContent = existingContent.replacingCharacters(in: replaceRange, with: skillsSection)
            do {
                try newContent.write(to: agentsMdPath, atomically: true, encoding: .utf8)
                return true
            } catch {
                throw SkillSyncError.agentsMdWriteFailed(error.localizedDescription)
            }
        } else {
            // Append new section
            let separator = existingContent.isEmpty ? "" : "\n\n"
            let newContent = existingContent + separator + skillsSection
            do {
                try newContent.write(to: agentsMdPath, atomically: true, encoding: .utf8)
                return !existingContent.isEmpty
            } catch {
                throw SkillSyncError.agentsMdWriteFailed(error.localizedDescription)
            }
        }
    }

    private static func buildSkillsSection(
        skills: [SkillRecord],
        markerStart: String,
        markerEnd: String
    ) -> String {
        if skills.isEmpty {
            return "\(markerStart)\n\(markerEnd)"
        }

        var lines = [markerStart, "# Skills"]
        for skill in skills {
            lines.append("")
            lines.append("## \(skill.name)")
            if let description = skill.description, !description.isEmpty {
                lines.append("")
                lines.append(description)
            }
            lines.append("")
            lines.append(skill.content)
        }
        lines.append(markerEnd)
        return lines.joined(separator: "\n")
    }

    public static func skillPathsForBackend(
        skillsDir: URL,
        skills: [SkillRecord]
    ) -> [URL] {
        skills.map { skill in
            skillsDir
                .appendingPathComponent(skill.name, isDirectory: true)
                .appendingPathComponent("SKILL.md")
        }
    }

    /// Read local skills FROM .agentctl/skills/ directory for checkpoint persistence
    public static func readLocalSkills(repoRoot: URL) throws -> [SkillRecord] {
        let skillsDir = repoRoot
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        guard FileManager.default.fileExists(atPath: skillsDir.path) else {
            return []
        }

        var skills: [SkillRecord] = []
        let skillDirs = try FileManager.default.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey])

        for skillDir in skillDirs where skillDir.hasDirectoryPath {
            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else {
                continue
            }

            let content = try String(contentsOf: skillFile, encoding: .utf8)
            let name = skillDir.lastPathComponent

            // Parse YAML frontmatter if present
            var description: String? = nil
            var tags: [String] = []
            var skillContent = content

            if content.hasPrefix("---") {
                let parts = content.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    let frontmatter = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    skillContent = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : content

                    // Parse simple frontmatter fields
                    for line in frontmatter.split(separator: "\n") {
                        let lineStr = String(line)
                        if lineStr.hasPrefix("description:") {
                            description = lineStr.dropFirst("description:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if lineStr.hasPrefix("tags:") {
                            let tagsStr = lineStr.dropFirst("tags:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                            if tagsStr.hasPrefix("[") {
                                // Parse array format [a, b, c]
                                let inner = tagsStr.dropFirst().dropLast()
                                tags = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                        }
                    }
                }
            }

            skills.append(SkillRecord(
                name: name,
                description: description,
                content: skillContent,
                tags: tags
            ))
        }

        return skills
    }
}