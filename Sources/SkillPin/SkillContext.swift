import Foundation

struct SkillContext: Sendable {
    struct Resource: Identifiable, Sendable {
        let path: String
        let bytes: Int
        let tokens: Int?
        var id: String { path }
    }
    let discovery: Int
    let full: Int
    let resources: [Resource]
    let raw: String
    let metadata: [String: String]
    var supporting: Int { resources.compactMap(\.tokens).reduce(0, +) }

    static let method = "Estimate: UTF-8 bytes ÷ 4, rounded up. Not a model tokenizer or measured session usage. Supporting files are loaded only when needed."

    static func estimate(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    static func read(file: URL, name: String, description: String) -> SkillContext? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        var resources: [Resource] = []
        let textExtensions: Set<String> = ["md", "txt", "rst"]
        if let walker = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard url.lastPathComponent != "SKILL.md", url.resolvingSymlinksInPath().isWithin(folder),
                      let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                      properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                let relative = String(url.path.dropFirst(folder.path.count + 1))
                // Estimate reference prose only. Never read executable code, credentials or binary assets.
                let prose = textExtensions.contains(url.pathExtension.lowercased())
                let bytes = properties.fileSize ?? 0
                let tokens: Int? = prose ? (bytes + 3) / 4 : nil
                resources.append(.init(path: relative, bytes: bytes, tokens: tokens))
            }
        }
        return .init(discovery: estimate(name + "\n" + description + "\n" + file.path), full: estimate(raw),
            resources: resources.sorted { $0.path < $1.path }, raw: raw, metadata: SkillDocument(raw).fields)
    }
}
