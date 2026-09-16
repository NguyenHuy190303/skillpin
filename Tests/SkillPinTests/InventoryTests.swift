import Foundation
import Testing
@testable import SkillPin

private final class InventoryFixture {
    let home = FileManager.default.temporaryDirectory.appending(path: "inventory-\(UUID().uuidString)").resolvingSymlinksInPath()
    init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: home) }
    @discardableResult
    func write(_ path: String, _ contents: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    @discardableResult
    func skill(_ path: String, name: String = "same") throws -> URL {
        try write(path + "/SKILL.md", "---\nname: \(name)\ndescription: Example\n---\nInstructions.").deletingLastPathComponent()
    }
    func scan(projects: [URL] = []) -> CatalogScan {
        SkillCatalog(roots: SkillCatalog.userRoots(home: home) + projects.flatMap { ProjectSkillRoots.roots(for: $0) }).scan()
    }
}

@Suite("Inventory boundaries")
struct InventoryBoundaryTests {
    @Test("System skills are included, hidden scratch folders and project skills are not")
    func systemAndProjects() throws {
        let f = try InventoryFixture()
        try f.skill(".codex/skills/.system/builtin")
        try f.skill(".codex/skills/.scratch/example")
        try f.skill("repo/.claude/skills/local")
        let scan = f.scan()
        #expect(scan.skills.count == 1)
        #expect(scan.skills[0].pins[0].isSystem)
        #expect(f.scan(projects: [f.home.appending(path: "repo")]).skills.count == 2)
    }

    @Test("Unrelated same-name skills stay separate, including projects with equal basenames")
    func identity() throws {
        let f = try InventoryFixture()
        try f.skill(".agents/skills/one")
        try f.skill(".claude/skills/two")
        try f.skill("a/repo/.claude/skills/three")
        try f.skill("b/repo/.claude/skills/four")
        let scan = f.scan(projects: [f.home.appending(path: "a/repo"), f.home.appending(path: "b/repo")])
        #expect(scan.skills.count == 4)
        #expect(Set(scan.skills.map(\.id)).count == 4)
        #expect(Set(scan.skills.flatMap(\.pins).compactMap(\.project)).count == 2)
    }

    @Test("A user skill symlink into a repo is excluded, even when the repo is selected")
    func escapedSymlink() throws {
        let f = try InventoryFixture()
        let target = try f.skill("repo/.claude/skills/private")
        try FileManager.default.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appending(path: ".claude/skills/leak"), withDestinationURL: target)
        let scan = f.scan(projects: [f.home.appending(path: "repo")])
        #expect(scan.skills.count == 1)
        #expect(scan.skills[0].pins.allSatisfy { $0.isProject })
        #expect(scan.issues.contains { $0.message.contains("scope") })
    }

    @Test("Redirecting the entire agent directory into a project does not bypass scope")
    func escapedAncestor() throws {
        let f = try InventoryFixture()
        try f.skill("repo/.claude/skills/private")
        try FileManager.default.createSymbolicLink(at: f.home.appending(path: ".claude"), withDestinationURL: f.home.appending(path: "repo/.claude"))
        #expect(f.scan().skills.isEmpty)
        #expect(!f.scan().issues.isEmpty)
    }

    @Test("Claude accepts missing frontmatter; Codex emits a diagnostic")
    func metadataFallback() throws {
        let f = try InventoryFixture()
        try f.write(".claude/skills/fallback/SKILL.md", "First paragraph.\n\nBody.")
        try f.write(".codex/skills/invalid/SKILL.md", "Body.")
        let scan = f.scan()
        #expect(scan.skills.map(\.name) == ["fallback"])
        #expect(scan.issues.count == 1)
    }

    @Test("Example SKILL.md files inside a skill are not separate installations")
    func nestedExamples() throws {
        let f = try InventoryFixture()
        try f.skill(".agents/skills/parent")
        try f.skill(".agents/skills/parent/examples/demo")
        #expect(f.scan().skills.count == 1)
    }
}

