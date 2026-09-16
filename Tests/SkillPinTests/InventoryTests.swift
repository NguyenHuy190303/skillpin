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

@Suite("Plugin registry and resources")
struct PluginInventoryTests {
    @Test("Claude uses the registry, preserves project scope, and ignores unregistered cache")
    func claudeRegistry() throws {
        let f = try InventoryFixture()
        let user = f.home.appending(path: ".claude/plugins/cache/market/user/1")
        let project = f.home.appending(path: ".claude/plugins/cache/market/project/1")
        for name in ["user", "project", "orphan"] {
            try f.write(".claude/plugins/cache/market/\(name)/1/.claude-plugin/plugin.json", "{\"name\":\"\(name)\"}")
            try f.skill(".claude/plugins/cache/market/\(name)/1/skills/example")
        }
        try f.write(".claude/plugins/installed_plugins.json", """
        {"version":2,"plugins":{
          "user@market":[{"scope":"user","installPath":"\(user.path)","version":"1"}],
          "project@market":[{"scope":"project","projectPath":"\(f.home.path)/repo","installPath":"\(project.path)","version":"1"}]
        }}
        """)
        try f.write(".claude/settings.json", "{\"enabledPlugins\":{\"user@market\":false}}")
        let inventory = AgentInventory.load(home: f.home, projects: [])
        #expect(inventory.plugins.count == 1)
        #expect(inventory.plugins[0].state == .disabled)
        #expect(SkillCatalog(roots: inventory.roots).discover().count == 1)
        let selected = AgentInventory.load(home: f.home, projects: [f.home.appending(path: "repo")])
        #expect(selected.plugins.count == 2)
        #expect(selected.roots.contains { $0.isProject && $0.plugin?.key == "project@market" })
    }

    @Test("Codex never guesses the active cached version")
    func ambiguousCodex() throws {
        let f = try InventoryFixture()
        try f.write(".codex/config.toml", "[plugins.\"demo@market\"]\nenabled = true\n")
        for version in ["1", "2"] {
            try f.write(".codex/plugins/cache/market/demo/\(version)/.codex-plugin/plugin.json", "{\"name\":\"demo\",\"skills\":\"./custom\"}")
            try f.skill(".codex/plugins/cache/market/demo/\(version)/custom/example")
        }
        let inventory = AgentInventory.load(home: f.home, projects: [])
        #expect(inventory.plugins.count == 2)
        #expect(inventory.plugins.allSatisfy { $0.state == .unknown })
        #expect(inventory.issues.count == 1, "\(inventory.issues)")
        #expect(SkillCatalog(roots: inventory.roots).discover().count == 2)
    }

    @Test("Rules and hooks are inventoried without executing hooks or reading project files by default")
    func resources() throws {
        let f = try InventoryFixture()
        try f.write(".claude/rules/style.md", "Use short names.")
        try f.write(".codex/rules/default.rules", "prefix_rule(pattern=[\"git\"], decision=\"allow\")")
        try f.write(".claude/settings.json", "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 99\"}]}]}}")
        try f.write("repo/AGENTS.md", "Project instructions.")
        try f.write("repo/Sources/Feature/AGENTS.override.md", "Nested instructions.")
        try f.write("repo/node_modules/pkg/AGENTS.md", "Ignored dependency instructions.")
        let inventory = AgentInventory.load(home: f.home, projects: [])
        #expect(inventory.resources.filter { $0.kind == .rules }.count == 2)
        #expect(inventory.resources.filter { $0.kind == .hooks }.count == 1)
        #expect(!inventory.resources.contains { $0.detail.contains("exit 99") })
        let selected = AgentInventory.load(home: f.home, projects: [f.home.appending(path: "repo")])
        #expect(selected.resources.count == 5)
        #expect(!selected.resources.contains { $0.url.path.contains("node_modules") })
    }

    @Test("Plugin manifests cannot import skills outside their installation")
    func escapedManifest() throws {
        let f = try InventoryFixture()
        try f.write(".codex/config.toml", "[plugins.\"demo@market\"]\nenabled = true\n")
        try f.write(".codex/plugins/cache/market/demo/1/.codex-plugin/plugin.json", "{\"skills\":\"../../../../../../repo\"}")
        let inventory = AgentInventory.load(home: f.home, projects: [])
        #expect(inventory.roots.isEmpty)
        #expect(inventory.issues.contains { $0.message.contains("escapes") })
    }
}

@Suite("Plugin controls")
struct PluginControlTests {
    @Test("Plugin switches preserve unrelated settings and reject ambiguous TOML")
    func pluginSettings() throws {
        let original = "# heading\n[plugins.\"demo@market\"]\nenabled = true # keep me\n[other]\nvalue = 42\n"
        let updated = try PluginControl.replacingEnabled(in: original, key: "demo@market", enabled: false)
        #expect(updated == original.replacingOccurrences(of: "enabled = true", with: "enabled = false"))
        #expect(CodexPluginSettings.states(updated)["demo@market"] == .disabled)
        #expect(throws: PluginControl.Failure.self) {
            try PluginControl.replacingEnabled(in: original + "[plugins.\"demo@market\"]\nenabled = false\n", key: "demo@market", enabled: false)
        }
        #expect(CodexPluginSettings.states("value = '''\n" + original + "'''\n").isEmpty)

        let f = try InventoryFixture()
        let url = try f.write(".claude/settings.json", "{\"enabledPlugins\":{\"demo@market\":true},\"other\":{\"keep\":17}}")
        let plugin = PluginInstallation(key: "demo@market", provider: .named("claude"), url: f.home, version: "1", project: nil, state: .enabled)
        try PluginControl.setEnabled(false, plugin: plugin, home: f.home)
        let settings = try #require(AgentInventory.json(url))
        #expect((settings["other"] as? [String: Int])?["keep"] == 17)
        #expect((settings["enabledPlugins"] as? [String: Bool])?["demo@market"] == false)
        #expect(throws: PluginControl.Failure.self) { try PluginControl.setEnabled(false, plugin: plugin, home: f.home) }
    }
}
@Suite("Context estimates")
struct SkillContextTests {
    @Test("Full instructions and optional supporting prose are separate; UTF-8 is counted explicitly")
    func counts() throws {
        let f = try InventoryFixture()
        let folder = try f.skill(".agents/skills/example")
        try f.write(".agents/skills/example/references/a.md", "abcdefgh")
        try f.write(".agents/skills/example/scripts/a.py", "print('not automatically prompt text')")
        let file = folder.appending(path: "SKILL.md")
        let context = try #require(SkillContext.read(file: file, name: "same", description: "Example"))
        #expect(context.supporting == 2)
        #expect(context.resources.count == 2)
        #expect(context.full == SkillContext.estimate(try String(contentsOf: file, encoding: .utf8)))
        #expect(SkillContext.estimate("ế") == 1)
        #expect(SkillContext.estimate("") == 0)
    }
}
@Suite("Reversible skill controls")
struct SkillBackupTests {
    @Test("Off preserves all files; restore refuses a collision and later restores the original")
    func roundTrip() throws {
        let f = try InventoryFixture()
        let source = try f.skill(".agents/skills/example")
        try f.write(".agents/skills/example/references/extra.md", "Do not lose this.")
        let pin = try #require(f.scan().skills.first?.pins.first)
        let backup = SkillBackup(root: f.home.appending(path: "skills-backup"))
        let entry = try backup.archive(pin, name: "example", allPins: [pin])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(backup.entries().count == 1)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        #expect(throws: SkillBackup.Failure.self) { try backup.restore(entry) }
        #expect(backup.entries().count == 1)
        try FileManager.default.removeItem(at: source)
        try backup.restore(entry)
        #expect(try String(contentsOf: source.appending(path: "references/extra.md"), encoding: .utf8) == "Do not lose this.")
        #expect(backup.entries().isEmpty)
    }

    @Test("Relative symlinks survive backup and restore; shared targets cannot be moved first")
    func symlinks() throws {
        let f = try InventoryFixture()
        let target = try f.skill(".agents/skills/example")
        try FileManager.default.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        let link = f.home.appending(path: ".claude/skills/example")
        let relative = "../../.agents/skills/example"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: relative)
        let pins = f.scan().skills.flatMap(\.pins)
        let real = try #require(pins.first { !$0.isLink })
        let alias = try #require(pins.first { $0.isLink })
        let backup = SkillBackup(root: f.home.appending(path: "skills-backup"))
        #expect(throws: SkillBackup.Failure.self) { try backup.archive(real, name: "example", allPins: pins) }
        let entry = try backup.archive(alias, name: "example", allPins: pins)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(backup.entries().count == 1)
        try backup.restore(entry)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == relative)
    }

    @Test("Project and built-in skill archives are refused")
    func protectedSkills() throws {
        let f = try InventoryFixture()
        try f.skill(".codex/skills/.system/builtin")
        try f.skill("repo/.claude/skills/local")
        let backup = SkillBackup(root: f.home.appending(path: "skills-backup"))
        for pin in f.scan(projects: [f.home.appending(path: "repo")]).skills.flatMap(\.pins) {
            #expect(throws: SkillBackup.Failure.self) { try backup.archive(pin, name: "x", allPins: [pin]) }
        }
    }

}
