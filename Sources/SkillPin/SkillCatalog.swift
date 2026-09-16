import Foundation

struct SkillRoot: Sendable {
    let label: String
    let url: URL
    let provider: AgentProvider
    let isProject: Bool
    /// The repository this root belongs to. One project has one root per format.
    let project: String?
    var plugin: PluginInstallation? = nil
    var isSystem = false

    init(label: String? = nil, url: URL, provider: AgentProvider, isProject: Bool = false, project: String? = nil) {
        self.label = label ?? provider.name
        self.url = url
        self.provider = provider
        self.isProject = isProject
        self.project = project
    }
}

struct DiscoveredSkill: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sourceURL: URL
    let fileURL: URL
    let pins: [DiscoveredSkillPin]
}

struct DiscoveredSkillPin: Identifiable, Sendable {
    let id: String
    let label: String
    let url: URL
    let provider: AgentProvider
    let isProject: Bool
    /// The skill folder here is a symlink to a copy somewhere else.
    let isLink: Bool
    var project: String? = nil
    var plugin: PluginInstallation? = nil
    var isSystem = false

    var scope: String { project.map { "Project: \($0)" } ?? (isSystem ? "System" : "User") }
    var canArchive: Bool { !isProject && !isSystem && plugin == nil && provider.hasFlatLayout }
}

struct ScanIssue: Identifiable, Sendable {
    let path: String
    let message: String
    var id: String { path + message }
}

struct CatalogScan: Sendable {
    var skills: [DiscoveredSkill] = []
    var issues: [ScanIssue] = []
}

struct SkillCatalog: Sendable {
    let roots: [SkillRoot]

    /// Every agent directory in the home folder that holds a `skills` folder,
    /// plus one root per Hermes profile.
    static var defaultRoots: [SkillRoot] {
        userRoots(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func userRoots(home: URL) -> [SkillRoot] {
        var roots = AgentProvider.discovered(in: home).map { provider in
            SkillRoot(
                url: home.appending(path: "\(provider.directoryName)/skills"),
                provider: provider
            )
        }

        let hermes = AgentProvider.named("hermes")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: home.appending(path: "\(hermes.directoryName)/profiles"),
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        roots += profiles.map {
            SkillRoot(
                label: "\(hermes.name) \($0.lastPathComponent)",
                url: $0.appending(path: "skills"),
                provider: hermes
            )
        }

        let system = home.appending(path: ".codex/skills/.system")
        if FileManager.default.fileExists(atPath: system.path) {
            var root = SkillRoot(label: "Codex system", url: system, provider: .named("codex"))
            root.isSystem = true
            roots.append(root)
        }
        return roots
    }

    static var `default`: SkillCatalog { SkillCatalog(roots: defaultRoots) }

    func discover() -> [DiscoveredSkill] {
        scan().skills
    }

    func scan() -> CatalogScan {
        var skills: [String: DiscoveredSkill] = [:]
        var result = CatalogScan()

        for root in roots {
            for fileURL in skillFiles(in: root, issues: &result.issues) {
                guard let document = SkillDocument.read(at: fileURL) else {
                    result.issues.append(.init(path: fileURL.path, message: "Cannot read SKILL.md as UTF-8."))
                    continue
                }
                let fallback = root.provider.key == "claude"
                guard let name = document.name ?? (fallback ? fileURL.deletingLastPathComponent().lastPathComponent : nil),
                      let summary = document.summary ?? (fallback ? document.body.components(separatedBy: "\n\n").first : nil) else {
                    result.issues.append(.init(path: fileURL.path, message: "Missing name or description."))
                    continue
                }
                let metadata = (name: name, description: summary)
                let folder = fileURL.deletingLastPathComponent()
                let pin = DiscoveredSkillPin(
                    id: root.label + fileURL.path,
                    label: root.label,
                    url: folder,
                    provider: root.provider,
                    isProject: root.isProject,
                    isLink: (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                    project: root.project,
                    plugin: root.plugin,
                    isSystem: root.isSystem
                )
                // Only aliases of the same physical skill share a row. A name is not identity.
                let key = [root.project ?? "user", root.isSystem ? "system" : "", root.plugin?.id ?? "",
                           fileURL.resolvingSymlinksInPath().path].joined(separator: "|")
                if var existing = skills[key] {
                    if !existing.pins.contains(where: { $0.url == pin.url }) {
                        existing = DiscoveredSkill(
                            id: existing.id,
                            name: existing.name,
                            description: existing.description,
                            sourceURL: existing.sourceURL,
                            fileURL: existing.fileURL,
                            pins: existing.pins + [pin]
                        )
                        skills[key] = existing
                    }
                } else {
                    skills[key] = DiscoveredSkill(
                        id: key,
                        name: metadata.name,
                        description: metadata.description,
                        sourceURL: fileURL.deletingLastPathComponent(),
                        fileURL: fileURL,
                        pins: [pin]
                    )
                }
            }
        }

        result.skills = skills.values.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return result
    }

    /// Every SKILL.md under `root`, following symlinked folders. Agents that install
    /// from a shared directory symlink into their own, and FileManager's enumerator
    /// does not descend into those, so this walks by hand.
    private func skillFiles(in root: SkillRoot, issues: inout [ScanIssue]) -> [URL] {
        var found: [URL] = []
        var visited: Set<String> = []

        func walk(_ directory: URL) {
            let real = directory.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { return }   // symlink cycles
            let allowed = roots.filter { $0.isProject == root.isProject && $0.project == root.project && $0.plugin?.id == root.plugin?.id }
            guard allowed.contains(where: {
                directory.resolvingSymlinksInPath().isWithin($0.url.agentBoundary(provider: $0.provider))
            }) else {
                issues.append(.init(path: directory.path, message: "Symlink leaves the selected scope; skipped."))
                return
            }

            // The path-based listing follows a symlinked folder; the URL-based one
            // refuses with ENOTDIR. Children keep the unresolved path so a pin
            // reports where the link is, not where it points.
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
            catch {
                issues.append(.init(path: directory.path, message: "Cannot list skill directory."))
                return
            }
            if names.contains("SKILL.md") {
                let file = directory.appending(path: "SKILL.md")
                if file.resolvingSymlinksInPath().isWithin(directory.resolvingSymlinksInPath()) {
                    found.append(file)
                } else {
                    issues.append(.init(path: file.path, message: "SKILL.md points outside its skill folder; skipped."))
                }
                return
            }

            for name in names where !name.hasPrefix(".") {
                let entry = directory.appending(path: name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(entry)
                } else if entry.lastPathComponent == "SKILL.md" {
                    if entry.resolvingSymlinksInPath().isWithin(directory.resolvingSymlinksInPath()) {
                        found.append(entry)
                    } else {
                        issues.append(.init(path: entry.path, message: "SKILL.md points outside its skill folder; skipped."))
                    }
                }
            }
        }

        walk(root.url)
        return found
    }

}

enum ProjectSkillRoots {
    /// The same discovery rule as the home folder, applied to a repository.
    static func roots(for projectURL: URL) -> [SkillRoot] {
        let project = projectURL.standardizedFileURL.path
        return AgentProvider.discovered(in: projectURL).map { provider in
            // Inside a project, .agents is the unqualified location; naming it
            // "Globals" would contradict the pin being project-scoped.
            SkillRoot(
                label: provider == .globals ? projectURL.lastPathComponent : "\(projectURL.lastPathComponent): \(provider.name)",
                url: projectURL.appending(path: "\(provider.directoryName)/skills"),
                provider: provider,
                isProject: true,
                project: project
            )
        }
    }
}

extension URL {
    /// Resolve OS aliases above the agent directory, but never bless an agent directory
    /// redirected into an unrelated repository as a new user-scoped boundary.
    func agentBoundary(provider: AgentProvider) -> URL {
        let parts = pathComponents
        guard let index = parts.firstIndex(of: provider.directoryName) else { return resolvingSymlinksInPath() }
        var base = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<index]))).resolvingSymlinksInPath()
        for part in parts[index...] { base.append(path: part) }
        return base.standardizedFileURL
    }

    func isWithin(_ root: URL) -> Bool {
        let path = standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
}
