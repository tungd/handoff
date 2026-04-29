import XCTest
import Foundation
@testable import AgentCore

final class SkillSyncTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-sync-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSyncSkillsCreatesSkillFiles() throws {
        let skills = [
            SkillRecord(
                name: "test-skill",
                description: "A test skill",
                content: "# Test Skill\n\nThis is a test skill content.",
                tags: ["test"]
            )
        ]

        let result = try SkillSync.syncSkills(skills: skills, repoRoot: tempDir)

        XCTAssertEqual(result.skillsWritten, 1)
        XCTAssertFalse(result.agentsMdUpdated) // New file created, not updated

        let skillFile = result.skillsDir
            .appendingPathComponent("test-skill", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))

        let content = try String(contentsOf: skillFile, encoding: .utf8)
        XCTAssertEqual(content, "# Test Skill\n\nThis is a test skill content.")
    }

    func testSyncSkillsCreatesAgentsMd() throws {
        let skills = [
            SkillRecord(
                name: "memory",
                description: "Memory skill",
                content: "Use memory CLI for persistence.",
                tags: ["memory"]
            )
        ]

        let agentsMdPath = tempDir.appendingPathComponent("AGENTS.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMdPath.path))

        _ = try SkillSync.syncSkills(skills: skills, repoRoot: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: agentsMdPath.path))
        let content = try String(contentsOf: agentsMdPath, encoding: .utf8)

        XCTAssertTrue(content.contains("<!-- agentctl-skills-start -->"))
        XCTAssertTrue(content.contains("<!-- agentctl-skills-end -->"))
        XCTAssertTrue(content.contains("## memory"))
        XCTAssertTrue(content.contains("Memory skill"))
        XCTAssertTrue(content.contains("Use memory CLI for persistence."))
    }

    func testSyncSkillsAppendsToExistingAgentsMd() throws {
        let existingContent = "# Project Instructions\n\nSome existing content."
        let agentsMdPath = tempDir.appendingPathComponent("AGENTS.md")
        try existingContent.write(to: agentsMdPath, atomically: true, encoding: .utf8)

        let skills = [
            SkillRecord(
                name: "test",
                content: "Test content.",
                tags: []
            )
        ]

        let result = try SkillSync.syncSkills(skills: skills, repoRoot: tempDir)

        XCTAssertTrue(result.agentsMdUpdated)

        let content = try String(contentsOf: agentsMdPath, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Project Instructions\n\nSome existing content."))
        XCTAssertTrue(content.contains("<!-- agentctl-skills-start -->"))
        XCTAssertTrue(content.contains("## test"))
    }

    func testSyncSkillsUpdatesExistingMarkerSection() throws {
        let existingContent = """
# Project

Some content.

<!-- agentctl-skills-start -->
# Skills

## old-skill
Old content.
<!-- agentctl-skills-end -->

More content.
"""
        let agentsMdPath = tempDir.appendingPathComponent("AGENTS.md")
        try existingContent.write(to: agentsMdPath, atomically: true, encoding: .utf8)

        let skills = [
            SkillRecord(
                name: "new-skill",
                content: "New content.",
                tags: []
            )
        ]

        let result = try SkillSync.syncSkills(skills: skills, repoRoot: tempDir)

        XCTAssertTrue(result.agentsMdUpdated)

        let content = try String(contentsOf: agentsMdPath, encoding: .utf8)
        XCTAssertTrue(content.contains("# Project"))
        XCTAssertTrue(content.contains("More content."))
        XCTAssertTrue(content.contains("## new-skill"))
        XCTAssertTrue(content.contains("New content."))
        XCTAssertFalse(content.contains("old-skill"))
    }

    func testSyncEmptySkillsClearsMarkerSection() throws {
        let existingContent = """
# Project

<!-- agentctl-skills-start -->
# Skills

## old-skill
Old content.
<!-- agentctl-skills-end -->
"""
        let agentsMdPath = tempDir.appendingPathComponent("AGENTS.md")
        try existingContent.write(to: agentsMdPath, atomically: true, encoding: .utf8)

        let result = try SkillSync.syncSkills(skills: [], repoRoot: tempDir)

        XCTAssertTrue(result.agentsMdUpdated)

        let content = try String(contentsOf: agentsMdPath, encoding: .utf8)
        XCTAssertTrue(content.contains("<!-- agentctl-skills-start -->"))
        XCTAssertTrue(content.contains("<!-- agentctl-skills-end -->"))
        XCTAssertFalse(content.contains("old-skill"))
        XCTAssertFalse(content.contains("# Skills"))
    }

    func testSkillPathsForBackend() throws {
        // Create skill files manually
        let skillsDir = tempDir
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("test-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let skillFile = skillsDir.appendingPathComponent("SKILL.md")
        try "Test skill content".write(to: skillFile, atomically: true, encoding: .utf8)

        let paths = SkillSync.skillPathsForBackend(skillsDir: tempDir.appendingPathComponent(".agentctl/skills"), skills: [
            SkillRecord(name: "test-skill", content: "Test skill content")
        ])

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first?.lastPathComponent, "SKILL.md")
        XCTAssertTrue(paths.first?.path.contains("test-skill") ?? false)
    }

    func testMultipleSkillsSynced() throws {
        let skills = [
            SkillRecord(name: "skill-a", content: "Content A", tags: ["a"]),
            SkillRecord(name: "skill-b", content: "Content B", tags: ["b"]),
            SkillRecord(name: "skill-c", content: "Content C", tags: ["c"])
        ]

        let result = try SkillSync.syncSkills(skills: skills, repoRoot: tempDir)

        XCTAssertEqual(result.skillsWritten, 3)

        for skill in skills {
            let skillFile = result.skillsDir
                .appendingPathComponent(skill.name, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))
        }

        let agentsMdContent = try String(contentsOf: tempDir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(agentsMdContent.contains("## skill-a"))
        XCTAssertTrue(agentsMdContent.contains("## skill-b"))
        XCTAssertTrue(agentsMdContent.contains("## skill-c"))
    }

    func testReadLocalSkills() throws {
        // Create local skill files
        let skillsDir = tempDir
            .appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        let skill1Dir = skillsDir.appendingPathComponent("local-skill-1", isDirectory: true)
        try FileManager.default.createDirectory(at: skill1Dir, withIntermediateDirectories: true)
        try "Local skill 1 content".write(to: skill1Dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skill2Dir = skillsDir.appendingPathComponent("local-skill-2", isDirectory: true)
        try FileManager.default.createDirectory(at: skill2Dir, withIntermediateDirectories: true)
        try "---\ndescription: A skill with frontmatter\ntags: [test, local]\n---\nLocal skill 2 content with frontmatter".write(to: skill2Dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let readSkills = try SkillSync.readLocalSkills(repoRoot: tempDir)

        XCTAssertEqual(readSkills.count, 2)

        let skill1 = readSkills.first { $0.name == "local-skill-1" }
        XCTAssertNotNil(skill1)
        XCTAssertEqual(skill1?.content, "Local skill 1 content")
        XCTAssertNil(skill1?.description)
        XCTAssertEqual(skill1?.tags, [])

        let skill2 = readSkills.first { $0.name == "local-skill-2" }
        XCTAssertNotNil(skill2)
        XCTAssertEqual(skill2?.content, "Local skill 2 content with frontmatter")
        XCTAssertEqual(skill2?.description, "A skill with frontmatter")
        XCTAssertEqual(skill2?.tags, ["test", "local"])
    }

    func testReadLocalSkillsReturnsEmptyWhenNoSkills() throws {
        let readSkills = try SkillSync.readLocalSkills(repoRoot: tempDir)
        XCTAssertEqual(readSkills.count, 0)
    }
}