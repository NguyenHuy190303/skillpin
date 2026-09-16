import Foundation

enum PluginControl {
    enum Failure: LocalizedError {
        case unsupported, changed
        var errorDescription: String? {
            switch self {
            case .unsupported: "This plugin state or scope cannot be safely edited. Use the agent's plugin manager."
            case .changed: "Configuration changed since it was read. Refresh and try again."
            }
        }
    }

    static func setEnabled(_ enabled: Bool, plugin: PluginInstallation, home: URL) throws {
        guard plugin.project == nil, plugin.state != .unknown else { throw Failure.unsupported }
        if plugin.provider.key == "claude" {
            let url = home.appending(path: ".claude/settings.json")
            let original = try Data(contentsOf: url)
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  var states = object["enabledPlugins"] as? [String: Bool],
                  states[plugin.key] == (plugin.state == .enabled) else { throw Failure.changed }
            states[plugin.key] = enabled
            object["enabledPlugins"] = states
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try write(data, to: url, ifUnchanged: original)
        } else if plugin.provider.key == "codex" {
            let url = home.appending(path: ".codex/config.toml")
            let original = try Data(contentsOf: url)
            guard let text = String(data: original, encoding: .utf8), CodexPluginSettings.states(text)[plugin.key] == plugin.state else {
                throw Failure.changed
            }
            let updated = try replacingEnabled(in: text, key: plugin.key, enabled: enabled)
            try write(Data(updated.utf8), to: url, ifUnchanged: original)
        } else { throw Failure.unsupported }
    }

    static func replacingEnabled(in text: String, key: String, enabled: Bool) throws -> String {
        guard !text.contains("\"\"\""), !text.contains("'''"), !key.contains("\""), !key.contains("\\"),
              !key.contains("\n") else { throw Failure.unsupported }
        var lines = text.components(separatedBy: "\n")
        let header = "[plugins.\"\(key)\"]"
        var inTable = false
        var tables = 0
        var matches: [Int] = []
        let regex = try NSRegularExpression(pattern: #"^(\s*enabled\s*=\s*)(true|false)(\s*(?:#.*)?)$"#)
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTable = line == header || line.hasPrefix(header + " #")
                if inTable { tables += 1 }
            } else if inTable, regex.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])) != nil {
                matches.append(index)
            }
        }
        guard tables == 1, matches.count == 1, let index = matches.first else { throw Failure.unsupported }
        let line = lines[index]
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 2), in: line) else { throw Failure.unsupported }
        lines[index].replaceSubrange(range, with: enabled ? "true" : "false")
        return lines.joined(separator: "\n")
    }

    private static func write(_ data: Data, to url: URL, ifUnchanged original: Data) throws {
        guard (try Data(contentsOf: url)) == original else { throw Failure.changed }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
}
