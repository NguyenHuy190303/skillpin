import Foundation

enum InstallationState: String, Sendable {
    case enabled = "Configured on"
    case disabled = "Configured off"
    case unknown = "Unknown"
}

struct PluginInstallation: Identifiable, Sendable {
    let key: String
    let provider: AgentProvider
    let url: URL
    let version: String
    let project: String?
    var state: InstallationState
    var id: String { [provider.key, key, url.path, project ?? "user"].joined(separator: "|") }
    var scope: String { project.map { "Project: \($0)" } ?? "User" }
}

struct AgentResource: Identifiable, Sendable {
    enum Kind: String, CaseIterable { case rules = "Rules", hooks = "Hooks" }
    let kind: Kind
    let url: URL
    let provider: AgentProvider
    let scope: String
    let owner: String?
    let detail: String
    var id: String { [kind.rawValue, url.path, scope, owner ?? ""].joined(separator: "|") }
}

struct AgentInventory: Sendable {
    var plugins: [PluginInstallation] = []
    var roots: [SkillRoot] = []
    var resources: [AgentResource] = []
    var issues: [ScanIssue] = []

    static func load(home: URL, projects: [URL]) -> AgentInventory {
        var inventory = AgentInventory()
        let fm = FileManager.default
        let registry = home.appending(path: ".claude/plugins/installed_plugins.json")
        if fm.fileExists(atPath: registry.path) {
            if let entries = json(registry)?["plugins"] as? [String: [[String: Any]]] {
                for key in entries.keys.sorted() {
                    for entry in entries[key] ?? [] {
                        let scope = entry["scope"] as? String
                        let project = entry["projectPath"] as? String
                        guard scope == "user" || ((scope == "project" || scope == "local") && projects.contains {
                            $0.standardizedFileURL.path == project
                        }) else { continue }
                        guard let path = entry["installPath"] as? String, path.hasPrefix("/") else { continue }
                        let settingsRoot = scope == "user" ? home : URL(fileURLWithPath: project!)
                        let settings = settingsRoot.appending(path: scope == "local" ? ".claude/settings.local.json" : ".claude/settings.json")
                        let enabled = (json(settings)?["enabledPlugins"] as? [String: Bool])?[key]
                        inventory.plugins.append(.init(key: key, provider: .named("claude"), url: URL(fileURLWithPath: path),
                            version: entry["version"] as? String ?? "Unknown", project: scope == "user" ? nil : project,
                            state: enabled.map { $0 ? .enabled : .disabled } ?? .unknown))
                    }
                }
            } else {
                inventory.issues.append(.init(path: registry.path, message: "Cannot read installed plugin registry."))
            }
        }

        // Config is the authority for scope; cached versions alone are not installed plugins.
        let config = home.appending(path: ".codex/config.toml")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            let states = CodexPluginSettings.states(text)
            for (key, state) in states.sorted(by: { $0.key < $1.key }) {
                let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts.allSatisfy(safeComponent) else { continue }
                let cache = home.appending(path: ".codex/plugins/cache/\(parts[1])/\(parts[0])")
                let versions = ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.path < $1.path }
                for version in versions {
                    inventory.plugins.append(.init(key: key, provider: .named("codex"), url: version,
                        version: version.lastPathComponent, project: nil, state: versions.count == 1 ? state : .unknown))
                }
                if versions.count != 1 {
                    inventory.issues.append(.init(path: cache.path, message: versions.isEmpty
                        ? "Configured plugin has no cached installation."
                        : "Multiple cached versions; active version cannot be determined. No version was selected automatically."))
                }
            }
            if text.contains("[plugins") && states.isEmpty {
                inventory.issues.append(.init(path: config.path, message: "Plugin configuration syntax is not supported; state is unknown."))
            }
        }

        for plugin in inventory.plugins {
            inventory.readPlugin(plugin)
        }
        inventory.readResources(at: home, project: false)
        for project in projects { inventory.readResources(at: project, project: true) }
        return inventory
    }

    private mutating func readPlugin(_ plugin: PluginInstallation) {
        let manifestURLs = [".codex-plugin/plugin.json", ".claude-plugin/plugin.json"].map { plugin.url.appending(path: $0) }
        guard let manifest = manifestURLs.compactMap({ Self.json($0) }).first else {
            issues.append(.init(path: plugin.url.path, message: "Plugin manifest is missing or unreadable."))
            return
        }
        var skillPaths = ["skills", ".codex-plugin/migrated-command-skills"]
        let declared = (manifest["skills"] as? [String]) ?? (manifest["skills"] as? String).map { [$0] } ?? []
        skillPaths += declared
        if FileManager.default.fileExists(atPath: plugin.url.appending(path: "SKILL.md").path) { skillPaths.append(".") }
        var seen: Set<String> = []
        for path in skillPaths {
            let url = plugin.url.appending(path: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                if declared.contains(path) {
                    issues.append(.init(path: url.path, message: "Declared plugin skill path is missing or escapes its installation."))
                }
                continue
            }
            guard url.resolvingSymlinksInPath().isWithin(plugin.url.resolvingSymlinksInPath()) else {
                issues.append(.init(path: url.path, message: "Plugin skill path escapes its installation; skipped."))
                continue
            }
            guard seen.insert(url.path).inserted else { continue }
            var root = SkillRoot(label: "\(plugin.provider.name) · \(plugin.key)", url: url,
                provider: plugin.provider, isProject: plugin.project != nil, project: plugin.project)
            root.plugin = plugin
            roots.append(root)
        }
        var hookPaths = ["hooks/hooks.json"]
        if let path = manifest["hooks"] as? String { hookPaths.append(path) }
        if let paths = manifest["hooks"] as? [String] { hookPaths += paths }
        for path in Set(hookPaths).sorted() {
            addHooks(plugin.url.appending(path: path), provider: plugin.provider, scope: plugin.scope,
                owner: plugin.key, boundary: plugin.url)
        }
        if let hooks = manifest["hooks"] as? [String: Any], let url = manifestURLs.first(where: { Self.json($0) != nil }) {
            addHookSummary(hooks, url: url, provider: plugin.provider, scope: plugin.scope, owner: plugin.key)
        }
        addRuleFiles(plugin.url.appending(path: "rules"), provider: plugin.provider, scope: plugin.scope, owner: plugin.key)
    }

    private mutating func readResources(at root: URL, project: Bool) {
        let scope = project ? "Project: \(root.path)" : "User"
        let files = project ? [(".claude/CLAUDE.md", "claude")]
            : [(".claude/CLAUDE.md", "claude"), (".codex/AGENTS.md", "codex"), (".codex/AGENTS.override.md", "codex")]
        for (path, provider) in files {
            let url = root.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                resources.append(.init(kind: .rules, url: url, provider: .named(provider), scope: scope, owner: nil,
                    detail: "Instruction file · applicability depends on the agent"))
            }
        }
        if project { addProjectInstructions(root, scope: scope) }
        addRuleFiles(root.appending(path: ".claude/rules"), provider: .named("claude"), scope: scope, owner: nil)
        addRuleFiles(root.appending(path: ".codex/rules"), provider: .named("codex"), scope: scope, owner: nil)
        for path in [".claude/settings.json", ".claude/settings.local.json"] {
            addHooks(root.appending(path: path), provider: .named("claude"), scope: scope, owner: nil, boundary: root)
        }
        addHooks(root.appending(path: ".codex/hooks.json"), provider: .named("codex"), scope: scope, owner: nil, boundary: root)
    }

    private mutating func addProjectInstructions(_ root: URL, scope: String) {
        let ignored = Set([".git", ".build", "node_modules", "vendor", "dist", "build"])
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in walker {
            if ignored.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walker.skipDescendants()
                continue
            }
            let name = url.lastPathComponent
            guard ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md"].contains(name),
                  url.resolvingSymlinksInPath().isWithin(root.resolvingSymlinksInPath()) else { continue }
            let provider = name.hasPrefix("AGENTS") ? AgentProvider.named("codex") : AgentProvider.named("claude")
            resources.append(.init(kind: .rules, url: url, provider: provider, scope: scope, owner: nil,
                detail: "Project instruction file · applies according to directory ancestry"))
        }
    }

    private mutating func addRuleFiles(_ root: URL, provider: AgentProvider, scope: String, owner: String?) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where ["md", "rules"].contains(url.pathExtension) {
            guard url.resolvingSymlinksInPath().isWithin(root.resolvingSymlinksInPath()) else { continue }
            resources.append(.init(kind: .rules, url: url, provider: provider, scope: scope, owner: owner,
                detail: provider.key == "codex" && url.pathExtension == "rules" ? "Execution policy · not prompt context" : "Rule file · applicability depends on the agent"))
        }
    }

    private mutating func addHooks(_ url: URL, provider: AgentProvider, scope: String, owner: String?, boundary: URL) {
        guard url.resolvingSymlinksInPath().isWithin(boundary.resolvingSymlinksInPath()), let data = Self.json(url),
              let hooks = data["hooks"] as? [String: Any] else { return }
        addHookSummary(hooks, url: url, provider: provider, scope: scope, owner: owner)
    }

    private mutating func addHookSummary(_ hooks: [String: Any], url: URL, provider: AgentProvider, scope: String, owner: String?) {
        let events = hooks.keys.sorted().joined(separator: ", ")
        resources.append(.init(kind: .hooks, url: url, provider: provider, scope: scope, owner: owner,
            detail: "Events: \(events). Configuration only; hooks are never executed by SkillPin."))
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\n")
    }
}

/// Reads the canonical plugin table syntax written by Codex. Other TOML stays opaque.
enum CodexPluginSettings {
    static func states(_ text: String) -> [String: InstallationState] {
        guard !text.contains("\"\"\""), !text.contains("'''"),
              let regex = try? NSRegularExpression(pattern: #"^\[plugins\.\"([^\"\\]+)\"\]\s*(?:#.*)?$"#) else { return [:] }
        var key: String?
        var result: [String: InstallationState] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                key = nil
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 1), in: line) {
                    key = String(line[range]); result[key!] = .unknown
                }
            } else if let key {
                let value = line.components(separatedBy: "#")[0].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                if value == "enabled=true" { result[key] = .enabled }
                if value == "enabled=false" { result[key] = .disabled }
            }
        }
        return result
    }
}
