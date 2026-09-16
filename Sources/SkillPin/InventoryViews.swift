import AppKit
import SwiftUI

struct SkillDetailsView: View {
    let name: String
    let summary: String
    let fileURL: URL
    let pins: [DiscoveredSkillPin]
    let onArchive: (DiscoveredSkillPin) -> Void
    @State private var context: SkillContext?
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(summary).font(.system(size: 12)).textSelection(.enabled)
            ForEach(pins) { pin in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(pin.scope) · \(pin.provider.name)").fontWeight(.medium)
                        Spacer()
                        if pin.canArchive {
                            Button("Turn off & back up") { onArchive(pin) }
                        }
                    }
                    Text(pin.url.abbreviatedPath).textSelection(.enabled)
                    if pin.isLink {
                        Text("Link → \(pin.url.resolvingSymlinksInPath().abbreviatedPath)").textSelection(.enabled)
                    }
                    if let plugin = pin.plugin {
                        Text("Plugin: \(plugin.key) · \(plugin.version) · \(plugin.state.rawValue)")
                        Text("Managed by its plugin; use the Plugins tab.").foregroundStyle(.secondary)
                    } else {
                        Text(pin.isSystem ? "Built-in · read only" : "Present on disk · runtime activation is not verified")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
            }
            if let context {
                HStack(spacing: 14) {
                    metric("Discovery", context.discovery)
                    metric("Full SKILL.md", context.full)
                    metric("Supporting prose", context.supporting)
                }
                Text(SkillContext.method).font(.system(size: 10)).foregroundStyle(.secondary)
                DisclosureGroup("Metadata (\(context.metadata.count) fields)") {
                    ForEach(context.metadata.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(context.metadata[key] ?? "")")
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    Text("Nested YAML is preserved in Raw SKILL.md below.").foregroundStyle(.secondary)
                }.font(.system(size: 11))
                DisclosureGroup("Supporting files (\(context.resources.count))") {
                    ForEach(context.resources) { resource in
                        HStack {
                            Text(resource.path).textSelection(.enabled)
                            Spacer()
                            Text(resource.tokens.map { "~\($0) tokens" } ?? "\(resource.bytes) bytes")
                        }
                    }
                }.font(.system(size: 11))
                DisclosureGroup("Raw SKILL.md", isExpanded: $showRaw) {
                    ScrollView { Text(context.raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 220)
                }.font(.system(size: 11))
            }
        }
        .padding(.vertical, 12)
        .task(id: fileURL) {
            let file = fileURL, title = name, description = summary
            context = await Task.detached(priority: .utility) {
                SkillContext.read(file: file, name: title, description: description)
            }.value
        }
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading) {
            Text("~\(count)").font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct InventoryPanel: View {
    let section: String
    let inventory: AgentInventory
    let issues: [ScanIssue]
    let backups: [SkillBackup.Entry]
    let onRestore: (SkillBackup.Entry) -> Void
    let onPluginToggle: (PluginInstallation) -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search \(section.lowercased())", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case "Plugins":
                        Text("Configured state, not session activity. Multiple cached versions remain unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(inventory.plugins.filter { matches($0.key + $0.scope) }) { plugin in
                            pluginRow(plugin)
                        }
                        if inventory.plugins.isEmpty { Text("No registered plugins found.") }
                    case "Disabled":
                        Text("Standalone skills archived in ~/skills-backup. Plugin switches are in Plugins.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(backups.filter { matches($0.name + $0.originalPath) }) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.name).fontWeight(.semibold)
                                    Spacer()
                                    Button("Restore") { onRestore(entry) }
                                }
                                Text(entry.originalPath).font(.caption).textSelection(.enabled)
                                Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                        if backups.isEmpty { Text("No archived skills.") }
                    case "Diagnostics":
                        Text("Projects are scanned only after you add them. A skipped path is never imported as a user skill.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(issues.enumerated()).filter { matches($0.element.path + $0.element.message) }, id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.message)
                                Text(issue.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Divider()
                        }
                        if issues.isEmpty { Text("No scan issues reported.") }
                    default:
                        Text("Read only. Scope and conditions decide whether the agent applies a file.")
                            .font(.caption).foregroundStyle(.secondary)
                        let resources = inventory.resources.filter { $0.kind.rawValue == section && matches($0.url.path + $0.detail + ($0.owner ?? "")) }
                        ForEach(resources) { resource in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(resource.url.lastPathComponent).fontWeight(.semibold)
                                    Spacer()
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([resource.url]) }
                                }
                                Text("\(resource.provider.name) · \(resource.scope)").font(.caption)
                                if let owner = resource.owner { Text("Plugin: \(owner)").font(.caption) }
                                Text(resource.detail).font(.caption).foregroundStyle(.secondary)
                                Text(resource.url.abbreviatedPath).font(.caption).textSelection(.enabled)
                            }
                            Divider()
                        }
                        if resources.isEmpty { Text("No matching \(section.lowercased()) found.") }
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    private func pluginRow(_ plugin: PluginInstallation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(plugin.key).fontWeight(.semibold)
                Spacer()
                if plugin.project == nil && plugin.state != .unknown {
                    Button(plugin.state == .enabled ? "Disable" : "Enable") { onPluginToggle(plugin) }
                }
            }
            Text("\(plugin.provider.name) · \(plugin.scope) · \(plugin.version)").font(.caption)
            Text(plugin.state.rawValue).foregroundStyle(plugin.state == .disabled ? .secondary : .primary)
            DisclosureGroup("Installation and components") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(plugin.url.abbreviatedPath).textSelection(.enabled)
                    ForEach(inventory.roots.filter { $0.plugin?.id == plugin.id }, id: \.url) { root in
                        Text("Skills: \(root.url.abbreviatedPath)").textSelection(.enabled)
                    }
                    ForEach(inventory.resources.filter { $0.owner == plugin.key && $0.url.isWithin(plugin.url) }) { resource in
                        Text("\(resource.kind.rawValue): \(resource.url.lastPathComponent)")
                    }
                    Button("Reveal plugin") { NSWorkspace.shared.activateFileViewerSelecting([plugin.url]) }
                }.font(.caption)
            }
            Divider()
        }
    }
}
